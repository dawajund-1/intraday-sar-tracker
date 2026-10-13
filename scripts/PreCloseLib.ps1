# Pre-close trade alerts: BUY/SELL pushed WHILE the market is still open.
#
# WHY
# The rule decides on the daily CLOSE, which only exists after 16:00 New York
# (23:00 / 00:00 Riyadh). The user wants the buy/sell alert during market
# hours so he can act on it, and the summary after the close.
#
# HOW
# A dispatch about 30 minutes before the close runs Get-Signals.ps1 inside the
# "pre-close window". In that window it does NOT trade: it reads today's
# still-forming bar, treats the current price as if it were the close, runs the
# exact same decision (exit the held name if RSI > exit level, then enter the
# first watchlist name with RSI < buy level), and pushes what it would do.
#
# WHAT IT NEVER DOES
# It never touches state.json, the ledger or the bar guard. The paper account
# still trades only on the real closing price, in the post-close run. Because
# the price can still move in the last half hour, a pre-close alert can be
# wrong; the post-close run sends an immediate alert for any trade that was NOT
# warned, and the summary lists warnings that did not happen.
#
# Dot-sourced by Get-Signals.ps1 and the tests, after TrackerLib and OutboxLib.

function Test-InPreCloseWindow {
    # True when $NowUtc is within $MinutesBefore of today's New York close,
    # on a weekday. Holidays are caught later: Yahoo has no bar for today.
    param([datetime]$NowUtc, [string]$TimeZoneId = "America/New_York",
          [string]$CloseLocal = "16:00", [int]$MinutesBefore = 60)
    $u = $NowUtc.ToUniversalTime()
    $tz = $null
    foreach ($id in @($TimeZoneId, "Eastern Standard Time")) {
        try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch { }
    }
    $nyDate = [TimeZoneInfo]::ConvertTimeFromUtc($u, $tz).Date
    if ($nyDate.DayOfWeek -eq 'Saturday' -or $nyDate.DayOfWeek -eq 'Sunday') { return $false }
    $close = Get-SessionCloseUtc -SessionDate $nyDate -TimeZoneId $TimeZoneId -CloseLocal $CloseLocal
    return ($u -ge $close.AddMinutes(-$MinutesBefore) -and $u -lt $close)
}

function Get-PreCloseDecision {
    # Pure: mirrors the two legs of the post-close cycle in Get-Signals.ps1.
    #   $HeldTicker  - ticker currently held, or $null
    #   $Rsi         - hashtable ticker -> provisional RSI (missing = no data)
    #   $Watchlist   - order decides which BUY wins, exactly as post-close
    # Returns @{ Sell = <ticker or $null>; Buy = <ticker or $null> }.
    param([string]$HeldTicker, [hashtable]$Rsi, [string[]]$Watchlist,
          [double]$BuyBelow, [double]$ExitAbove)
    $sell = $null; $buy = $null
    $flat = -not $HeldTicker
    if ($HeldTicker -and $Rsi.ContainsKey($HeldTicker) -and $Rsi[$HeldTicker] -gt $ExitAbove) {
        $sell = $HeldTicker; $flat = $true
    }
    if ($flat) {
        foreach ($t in $Watchlist) {
            if ($t -eq $HeldTicker) { continue }   # never re-enter a name exited on this bar
            if ($Rsi.ContainsKey($t) -and $Rsi[$t] -lt $BuyBelow) { $buy = $t; break }
        }
    }
    return @{ Sell = $sell; Buy = $buy }
}

function Get-RiyadhClock {
    # "23:00" style label for a UTC instant. Riyadh is UTC+3 all year.
    param([datetime]$Utc)
    return $Utc.ToUniversalTime().AddHours(3).ToString("HH:mm")
}

function Invoke-PreClosePreview {
    # Runs the preview end to end. Returns nothing; queues, commits and drains.
    param($Cfg, $State, [datetime]$NowUtc)
    $live     = $Cfg.live
    $tzId     = if ($live.market_timezone) { $live.market_timezone } else { "America/New_York" }
    $closeLoc = if ($live.market_close_local) { $live.market_close_local } else { "16:00" }
    $nyDate   = [TimeZoneInfo]::ConvertTimeFromUtc($NowUtc.ToUniversalTime(),
                    [TimeZoneInfo]::FindSystemTimeZoneById($tzId)).Date
    $todayId  = $nyDate.ToString("yyyy-MM-dd")
    $closeUtc = Get-SessionCloseUtc -SessionDate $nyDate -TimeZoneId $tzId -CloseLocal $closeLoc
    $closeRiyadh = Get-RiyadhClock -Utc $closeUtc

    $rsi = @{}; $px = @{}
    foreach ($t in $Cfg.watchlist) {
        try {
            $bars = Get-HourlyBars -Ticker $t -Interval $live.interval -Range $live.range
            if (-not $bars -or $bars.Count -lt ([int]$live.rsi_period + 2)) { continue }
            # Today's bar must exist and still be forming. No bar for today means
            # a market holiday: say nothing.
            if ((Get-BarId -Bars $bars) -ne $todayId) { continue }
            $r = Get-RsiLast -Closes $bars.close -Period ([int]$live.rsi_period)
            if ($null -ne $r) { $rsi[$t] = $r; $px[$t] = $bars[-1].close }
        } catch {
            Write-Warning "preclose: $t failed - $($_.Exception.Message)"
        }
    }
    if ($rsi.Count -eq 0) { Write-Host "preclose: no bar for today ($todayId); market closed or data missing."; return }

    $held = if ($State.open_position) { [string]$State.open_position.ticker } else { $null }
    $d = Get-PreCloseDecision -HeldTicker $held -Rsi $rsi -Watchlist @($Cfg.watchlist) `
            -BuyBelow ([double]$live.rsi_buy_below) -ExitAbove ([double]$live.rsi_exit_above)

    $queued = $false
    if ($d.Sell) {
        $t = $d.Sell
        $queued = (Add-OutboxEvent -Id "PRECLOSE:SELL:${t}:${todayId}" -Title "SELL signal: $t" `
            -Message ("Sell before the close at $closeRiyadh Riyadh time. Price now `$$([math]::Round($px[$t],2)), " +
                      "RSI $([math]::Round($rsi[$t],1)) (sell level $($live.rsi_exit_above)). " +
                      "Expected at today's close - confirmed in the summary after the close.")) -or $queued
    }
    if ($d.Buy) {
        $t = $d.Buy
        $queued = (Add-OutboxEvent -Id "PRECLOSE:BUY:${t}:${todayId}" -Title "BUY signal: $t" `
            -Message ("Buy before the close at $closeRiyadh Riyadh time. Price now `$$([math]::Round($px[$t],2)), " +
                      "RSI $([math]::Round($rsi[$t],1)) (buy level $($live.rsi_buy_below)). " +
                      "Expected at today's close - confirmed in the summary after the close.")) -or $queued
    }
    if (-not $d.Sell -and -not $d.Buy) {
        Write-Host "preclose: no trade expected at today's close; nothing sent."
        return
    }
    if (-not $queued) { Write-Host "preclose: already sent for $todayId." }

    if (Publish-DataCommit "Pre-close alert $todayId") { Invoke-OutboxDrain -Cfg $Cfg }
    else { Write-Warning "preclose: data commit did not land; alert left undelivered on purpose." }
}
