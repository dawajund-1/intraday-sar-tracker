# Runs one check cycle: fetches hourly bars for each watchlist ticker, computes an
# EMA9/EMA21 crossover, logs every check, updates the paper-trading position, and
# writes a dashboard snapshot. Runs on GitHub Actions — places no real trades anywhere.

. (Join-Path $PSScriptRoot "TrackerLib.ps1")

$cfg   = Read-Config
$state = Read-State
$now   = Get-Date

if (-not $state.ticker_state) { $state | Add-Member -NotePropertyName ticker_state -NotePropertyValue ([pscustomobject]@{}) -Force }
if (-not $state.warning_state) { $state | Add-Member -NotePropertyName warning_state -NotePropertyValue ([pscustomobject]@{}) -Force }

$heldTicker = if ($state.open_position) { $state.open_position.ticker } else { $null }

# --- Which rule are we trading? -------------------------------------------
# 'rsi_revert' is RSI(2) mean reversion on DAILY bars. It is the only rule in
# this project that beat a matched random control after correcting for
# multiple testing (p = 0.03 over 2000-2013 US large caps).
#
# It is deliberately NOT used on the Tadawul tracker: measured there it came
# 14th of 15 with NEGATIVE per-trade expectancy. It was also measured on 5m
# bars for this same watchlist and came out worse than random. The daily US
# timeframe is not incidental, it IS the result. See FINDINGS.md in the
# research repo.
#
# Set live.strategy to 'ema_cross' to restore the previous behaviour.
$live     = $cfg.live
$strategy = if ($live -and $live.strategy) { $live.strategy } else { "ema_cross" }
$barIntvl = if ($live -and $live.interval) { $live.interval } else { $cfg.interval }
$barRange = if ($live -and $live.range)    { $live.range }    else { $cfg.range }
$closeUtc = if ($live -and $live.market_close_utc) { $live.market_close_utc } else { "20:00" }

$signalsThisRun = @()
$tickerSnapshots = @()

foreach ($ticker in $cfg.watchlist) {
    try {
        $bars = Get-HourlyBars -Ticker $ticker -Interval $barIntvl -Range $barRange
        $bars = Remove-PartialBar -Bars $bars -Interval $barIntvl -MarketCloseUtc $closeUtc

        $minBars = if ($strategy -eq "rsi_revert") { [int]$live.rsi_period + 2 } else { $cfg.ema_slow + 1 }
        if ($bars.Count -lt $minBars) {
            Write-Warning "$ticker : not enough bars ($($bars.Count)), skipping"
            continue
        }
        $closes = $bars.close
        $lastPrice = $closes[-1]

        $rsi = $null; $emaFast = $null; $emaSlow = $null
        $trend = ""; $signal = "NONE"; $earlyWarning = "NONE"

        if ($strategy -eq "rsi_revert") {
            # Position state machine, identical to St-RsiRevert in the research
            # harness: flat -> long when RSI closes below the buy level, long ->
            # flat when it closes above the exit level. Level-based, not
            # cross-based, so a signal missed one day still fires the next.
            $rsi = Get-RsiLast -Closes $closes -Period ([int]$live.rsi_period)
            if ($null -eq $rsi) { Write-Warning "$ticker : RSI unavailable, skipping"; continue }

            $prevPos = $state.ticker_state.$ticker
            if ($prevPos -ne "LONG" -and $prevPos -ne "FLAT") { $prevPos = "FLAT" }

            if ($prevPos -eq "FLAT" -and $rsi -lt [double]$live.rsi_buy_below) { $signal = "BUY" }
            elseif ($prevPos -eq "LONG" -and $rsi -gt [double]$live.rsi_exit_above) { $signal = "SELL" }

            # Log the position held GOING INTO this bar, not the one the rule
            # would like. Most BUY signals are never acted on (one position at a
            # time), so logging the desired state would fill the audit trail
            # with LONG rows for tickers that were never bought.
            $trend = $prevPos
        }
        else {
            $emaFast = Get-EmaLast -Closes $closes -Period $cfg.ema_fast
            $emaSlow = Get-EmaLast -Closes $closes -Period $cfg.ema_slow
            $trend = if ($emaFast -gt $emaSlow) { "BULL" } else { "BEAR" }
            $prevTrend = $state.ticker_state.$ticker
            if ($prevTrend -and $prevTrend -ne $trend) {
                $signal = if ($trend -eq "BULL") { "BUY" } else { "SELL" }
            }

            # Early-warning tier: a faster, noisier read on price vs. the short EMA alone.
            # Not a prediction — still reactive, just to a twitchier line, so it can flag
            # possible weakening/strengthening before the slower EMA9/EMA21 cross confirms.
            if ($trend -eq "BULL" -and $lastPrice -lt $emaFast) { $earlyWarning = "WEAKENING" }
            elseif ($trend -eq "BEAR" -and $lastPrice -gt $emaFast) { $earlyWarning = "STRENGTHENING" }
        }
        $prevWarning = $state.warning_state.$ticker

        Append-Csv -Path (Join-Path $DataDir "signals_log.csv") -Row ([pscustomobject]@{
            timestamp_utc = $now.ToUniversalTime().ToString("s")
            ticker        = $ticker
            strategy      = $strategy
            interval      = $barIntvl
            price         = [math]::Round($lastPrice, 4)
            rsi           = if ($null -ne $rsi)     { [math]::Round($rsi, 2) }     else { "" }
            ema9          = if ($null -ne $emaFast) { [math]::Round($emaFast, 4) } else { "" }
            ema21         = if ($null -ne $emaSlow) { [math]::Round($emaSlow, 4) } else { "" }
            trend         = $trend
            signal        = $signal
            early_warning = $earlyWarning
        })

        if ($signal -ne "NONE") {
            $signalsThisRun += [pscustomobject]@{ ticker = $ticker; signal = $signal; price = $lastPrice }
        }

        # Only push for the ticker you're actually holding, and only on the transition
        # into WEAKENING (not every check while it stays weak) to avoid spamming.
        if ($ticker -eq $heldTicker -and $earlyWarning -eq "WEAKENING" -and $prevWarning -ne "WEAKENING") {
            Notify-User -Topic $cfg.ntfy_topic -Title "⚠️ Early Warning: $ticker" -Message "Price ($([math]::Round($lastPrice,2))) dipped below its short-term average (EMA$($cfg.ema_fast)) while the trend is still Bull. This sometimes comes before a confirmed SELL, but often doesn't — not a confirmed signal, just a heads-up."
        }

        $tickerSnapshots += [pscustomobject]@{
            ticker        = $ticker
            strategy      = $strategy
            price         = [math]::Round($lastPrice, 4)
            rsi           = if ($null -ne $rsi)     { [math]::Round($rsi, 2) }     else { $null }
            ema9          = if ($null -ne $emaFast) { [math]::Round($emaFast, 4) } else { $null }
            ema21         = if ($null -ne $emaSlow) { [math]::Round($emaSlow, 4) } else { $null }
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

# --- Paper-trading logic: at most one open position at a time (capital is ~$27) ---
$tradesPath = Join-Path $DataDir "paper_trades.csv"
$portfolioPath = Join-Path $DataDir "portfolio_history.csv"

if ($state.open_position) {
    $held = $state.open_position
    $sellSignal = $signalsThisRun | Where-Object { $_.ticker -eq $held.ticker -and $_.signal -eq "SELL" } | Select-Object -First 1
    if ($sellSignal) {
        $exitPrice = $sellSignal.price
        $pl = [math]::Round(($exitPrice - $held.entry_price) * $held.shares, 4)
        $purification = if ($pl -gt 0) { [math]::Round($pl * $cfg.purification_pct, 4) } else { 0 }
        $newBalance = [math]::Round($state.portfolio.balance_usd + $pl - $purification, 4)

        Append-Csv -Path $tradesPath -Row ([pscustomobject]@{
            timestamp_utc = $now.ToUniversalTime().ToString("s")
            action        = "SELL"
            ticker        = $held.ticker
            price         = [math]::Round($exitPrice, 4)
            shares        = $held.shares
            entry_price   = $held.entry_price
            pl_usd        = $pl
            purification_usd = $purification
            balance_after_usd = $newBalance
        })
        Append-Csv -Path $portfolioPath -Row ([pscustomobject]@{
            timestamp_utc = $now.ToUniversalTime().ToString("s")
            event         = "CLOSE $($held.ticker)"
            pl_usd        = $pl
            purification_usd = $purification
            balance_usd   = $newBalance
            balance_sar   = [math]::Round($newBalance * $cfg.sar_per_usd, 2)
        })

        $state.portfolio.balance_usd = $newBalance
        $state.portfolio.realized_pl_usd = [math]::Round($state.portfolio.realized_pl_usd + $pl, 4)
        $state.portfolio.purified_total_usd = [math]::Round($state.portfolio.purified_total_usd + $purification, 4)
        $state.open_position = $null

        Notify-User -Topic $cfg.ntfy_topic -Title "SELL signal: $($held.ticker)" -Message "Exit @ `$$([math]::Round($exitPrice,2)) | P/L `$$pl | Purified `$$purification | Balance `$$newBalance"
    }
} else {
    $buySignal = $signalsThisRun | Where-Object { $_.signal -eq "BUY" } | Select-Object -First 1
    if ($buySignal) {
        $balance = $state.portfolio.balance_usd
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
            price         = [math]::Round($buySignal.price, 4)
            shares        = $shares
            entry_price   = [math]::Round($buySignal.price, 4)
            pl_usd        = ""
            purification_usd = ""
            balance_after_usd = $balance
        })
        Notify-User -Topic $cfg.ntfy_topic -Title "BUY signal: $($buySignal.ticker)" -Message "Entry @ `$$([math]::Round($buySignal.price,2)) | Balance `$$balance"
    }
}

# --- Reconcile strategy state with the portfolio --------------------------
# The backtest traded every ticker independently. This account holds AT MOST
# ONE position (capital is ~$27), so most BUY signals are logged and not acted
# on. Without this step those tickers would stay marked LONG forever: never
# bought so never sellable, and because they already "hold" they would never
# signal BUY again -- entries would silently dry up after the first busy day.
#
# The rule that actually trades is therefore: go long the first watchlist
# ticker whose RSI closes below the buy level while flat, and exit it when its
# RSI closes above the exit level.
if ($strategy -eq "rsi_revert") {
    $openTicker = if ($state.open_position) { $state.open_position.ticker } else { $null }
    foreach ($ticker in $cfg.watchlist) {
        $shouldBe = if ($ticker -eq $openTicker) { "LONG" } else { "FLAT" }
        $state.ticker_state | Add-Member -NotePropertyName $ticker -NotePropertyValue $shouldBe -Force
    }
}

Save-State $state
Write-Snapshot -Tickers $tickerSnapshots -State $state -Cfg $cfg
