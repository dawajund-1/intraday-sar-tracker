# Runs one check cycle for the Tadawul (Saudi Exchange) watchlist: fetches bars,
# computes an EMA9/EMA21 crossover plus a faster early-warning read, logs every check,
# updates the paper-trading position, and writes a dashboard snapshot. Runs on GitHub
# Actions — places no real trades anywhere. SAR-native throughout.

. (Join-Path $PSScriptRoot "TrackerLib.ps1")

$cfg   = Read-Config
$state = Read-State
$now   = Get-Date

if (-not $state.ticker_state) { $state | Add-Member -NotePropertyName ticker_state -NotePropertyValue ([pscustomobject]@{}) -Force }
if (-not $state.warning_state) { $state | Add-Member -NotePropertyName warning_state -NotePropertyValue ([pscustomobject]@{}) -Force }

$heldTicker = if ($state.open_position) { $state.open_position.ticker } else { $null }

$signalsThisRun = @()
$tickerSnapshots = @()

foreach ($ticker in $cfg.watchlist) {
    try {
        $bars = Get-HourlyBars -Ticker $ticker -Interval $cfg.interval -Range $cfg.range
        if ($bars.Count -lt $cfg.ema_slow + 1) {
            Write-Warning "$ticker : not enough bars ($($bars.Count)), skipping"
            continue
        }
        $closes = $bars.close
        $lastPrice = $closes[-1]
        $emaFast = Get-EmaLast -Closes $closes -Period $cfg.ema_fast
        $emaSlow = Get-EmaLast -Closes $closes -Period $cfg.ema_slow
        $trend = if ($emaFast -gt $emaSlow) { "BULL" } else { "BEAR" }
        $prevTrend = $state.ticker_state.$ticker

        $signal = "NONE"
        if ($prevTrend -and $prevTrend -ne $trend) {
            $signal = if ($trend -eq "BULL") { "BUY" } else { "SELL" }
        }

        $earlyWarning = "NONE"
        if ($trend -eq "BULL" -and $lastPrice -lt $emaFast) { $earlyWarning = "WEAKENING" }
        elseif ($trend -eq "BEAR" -and $lastPrice -gt $emaFast) { $earlyWarning = "STRENGTHENING" }
        $prevWarning = $state.warning_state.$ticker

        $name = $cfg.watchlist_names.$ticker
        if (-not $name) { $name = $ticker }

        Append-Csv -Path (Join-Path $DataDir "signals_log.csv") -Row ([pscustomobject]@{
            timestamp_utc = $now.ToUniversalTime().ToString("s")
            ticker        = $ticker
            name          = $name
            price_sar     = [math]::Round($lastPrice, 4)
            ema9          = [math]::Round($emaFast, 4)
            ema21         = [math]::Round($emaSlow, 4)
            trend         = $trend
            signal        = $signal
            early_warning = $earlyWarning
        })

        if ($signal -ne "NONE") {
            $signalsThisRun += [pscustomobject]@{ ticker = $ticker; signal = $signal; price = $lastPrice }
        }

        if ($ticker -eq $heldTicker -and $earlyWarning -eq "WEAKENING" -and $prevWarning -ne "WEAKENING") {
            Notify-User -Topic $cfg.ntfy_topic -Title "⚠️ Early Warning: $name" -Message "Price (SAR $([math]::Round($lastPrice,2))) dipped below its short-term average (EMA$($cfg.ema_fast)) while the trend is still Bull. Sometimes comes before a confirmed SELL, often doesn't — just a heads-up."
        }

        $tickerSnapshots += [pscustomobject]@{
            ticker        = $ticker
            name          = $name
            price         = [math]::Round($lastPrice, 4)
            ema9          = [math]::Round($emaFast, 4)
            ema21         = [math]::Round($emaSlow, 4)
            trend         = $trend
            signal        = $signal
            early_warning = $earlyWarning
        }

        $state.ticker_state | Add-Member -NotePropertyName $ticker -NotePropertyValue $trend -Force
        $state.warning_state | Add-Member -NotePropertyName $ticker -NotePropertyValue $earlyWarning -Force
    } catch {
        Write-Warning "$ticker : failed to fetch/process - $($_.Exception.Message)"
    }
}

# --- Paper-trading logic: at most one open position at a time ---
$tradesPath = Join-Path $DataDir "paper_trades.csv"
$portfolioPath = Join-Path $DataDir "portfolio_history.csv"

if ($state.open_position) {
    $held = $state.open_position
    $sellSignal = $signalsThisRun | Where-Object { $_.ticker -eq $held.ticker -and $_.signal -eq "SELL" } | Select-Object -First 1
    if ($sellSignal) {
        $exitPrice = $sellSignal.price
        $pl = [math]::Round(($exitPrice - $held.entry_price) * $held.shares, 4)
        $purification = if ($pl -gt 0) { [math]::Round($pl * $cfg.purification_pct, 4) } else { 0 }
        $newBalance = [math]::Round($state.portfolio.balance_sar + $pl - $purification, 4)

        Append-Csv -Path $tradesPath -Row ([pscustomobject]@{
            timestamp_utc = $now.ToUniversalTime().ToString("s")
            action        = "SELL"
            ticker        = $held.ticker
            price_sar     = [math]::Round($exitPrice, 4)
            shares        = $held.shares
            entry_price   = $held.entry_price
            pl_sar        = $pl
            purification_sar = $purification
            balance_after_sar = $newBalance
        })
        Append-Csv -Path $portfolioPath -Row ([pscustomobject]@{
            timestamp_utc = $now.ToUniversalTime().ToString("s")
            event         = "CLOSE $($held.ticker)"
            pl_sar        = $pl
            purification_sar = $purification
            balance_sar   = $newBalance
        })

        $state.portfolio.balance_sar = $newBalance
        $state.portfolio.realized_pl_sar = [math]::Round($state.portfolio.realized_pl_sar + $pl, 4)
        $state.portfolio.purified_total_sar = [math]::Round($state.portfolio.purified_total_sar + $purification, 4)
        $state.open_position = $null

        Notify-User -Topic $cfg.ntfy_topic -Title "SELL signal: $($held.ticker)" -Message "Exit @ SAR $([math]::Round($exitPrice,2)) | P/L SAR $pl | Purified SAR $purification | Balance SAR $newBalance"
    }
} else {
    $buySignal = $signalsThisRun | Where-Object { $_.signal -eq "BUY" } | Select-Object -First 1
    if ($buySignal) {
        $balance = $state.portfolio.balance_sar
        $shares = [math]::Round($balance / $buySignal.price, 6)
        $state.open_position = [pscustomobject]@{
            ticker      = $buySignal.ticker
            entry_price = [math]::Round($buySignal.price, 4)
            entry_time  = $now.ToUniversalTime().ToString("s")
            shares      = $shares
        }
        Append-Csv -Path $tradesPath -Row ([pscustomobject]@{
            timestamp_utc = $now.ToUniversalTime().ToString("s")
            action        = "BUY"
            ticker        = $buySignal.ticker
            price_sar     = [math]::Round($buySignal.price, 4)
            shares        = $shares
            entry_price   = [math]::Round($buySignal.price, 4)
            pl_sar        = ""
            purification_sar = ""
            balance_after_sar = $balance
        })
        Notify-User -Topic $cfg.ntfy_topic -Title "BUY signal: $($buySignal.ticker)" -Message "Entry @ SAR $([math]::Round($buySignal.price,2)) | Balance SAR $balance"
    }
}

Save-State $state
Write-Snapshot -Tickers $tickerSnapshots -State $state -Cfg $cfg
