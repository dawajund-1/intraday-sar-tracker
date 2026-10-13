# Run once just after the US close. Summarizes that session's activity and sends a push.
# Reads-only from the CSV logs written by Get-Signals.ps1 — places no trades.

. (Join-Path $PSScriptRoot "TrackerLib.ps1")
. (Join-Path $PSScriptRoot "OutboxLib.ps1")

$cfg   = Read-Config
$state = Read-State

# Keyed by MARKET SESSION, not by the runner's calendar date. The on-time run
# (right after the US close) and GitHub's late backup run the next morning
# both resolve to the same session, so the backup finds the summary already
# sent and does nothing - no second, empty "0 trades" message at 07:00.
$tzId     = if ($cfg.live -and $cfg.live.market_timezone) { $cfg.live.market_timezone } else { "America/New_York" }
$closeLoc = if ($cfg.live -and $cfg.live.market_close_local) { $cfg.live.market_close_local } else { "16:00" }
$session  = (Get-SessionDateOf -Utc (Get-Date).ToUniversalTime() -TimeZoneId $tzId -CloseLocal $closeLoc).ToString("yyyy-MM-dd")
$summaryId = "SUMMARY-SESSION:$session"

if (@(Read-Outbox) | Where-Object { $_.id -eq $summaryId }) {
    # Already queued by an earlier run. Only retry delivery, in case that run
    # committed the summary but could not reach ntfy; the drain is idempotent.
    Write-Host "summary: session $session already summarized; retrying delivery only."
    Invoke-OutboxDrain -Cfg $cfg
    exit 0
}

$tradesPath = Join-Path $DataDir "paper_trades.csv"
$todayTrades = @()
if (Test-Path $tradesPath) {
    # Older rows carry no trailing Z; every timestamp in this ledger is UTC.
    $todayTrades = Import-Csv $tradesPath | Where-Object {
        $t = [DateTimeOffset]::Parse($_.timestamp_utc, [Globalization.CultureInfo]::InvariantCulture,
                                     [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
        (Get-SessionDateOf -Utc $t -TimeZoneId $tzId -CloseLocal $closeLoc).ToString("yyyy-MM-dd") -eq $session
    }
}

$sells = $todayTrades | Where-Object { $_.action -eq "SELL" }
$netPl = ($sells | ForEach-Object { [double]$_.pl_usd } | Measure-Object -Sum).Sum
$netPurified = ($sells | ForEach-Object { [double]$_.purification_usd } | Measure-Object -Sum).Sum
if (-not $netPl) { $netPl = 0 }
if (-not $netPurified) { $netPurified = 0 }

$balanceUsd = $state.portfolio.balance_usd
$balanceSar = [math]::Round($balanceUsd * $cfg.sar_per_usd, 2)
$openPos = if ($state.open_position) { "$($state.open_position.ticker) @ `$$($state.open_position.entry_price)" } else { "none" }

Append-Csv -Path (Join-Path $DataDir "daily_summary.csv") -Row ([pscustomobject]@{
    date              = $session
    trades_closed     = $sells.Count
    net_pl_usd        = [math]::Round($netPl, 4)
    purified_usd      = [math]::Round($netPurified, 4)
    balance_usd       = $balanceUsd
    balance_sar       = $balanceSar
    open_position     = $openPos
    total_realized_pl_usd = $state.portfolio.realized_pl_usd
    total_purified_usd    = $state.portfolio.purified_total_usd
})

# One summary per market session, queued rather than sent. The deterministic
# id makes a re-run (or the late backup run) a no-op instead of a second push.
# Ids before 2026-10-13 were "SUMMARY:<run date>"; the new prefix keeps the two
# schemes from colliding on the changeover day.
$sessionLabel = ([datetime]$session).ToString("ddd d MMM", [Globalization.CultureInfo]::InvariantCulture)
Add-OutboxEvent -Id $summaryId -Title "Daily summary - $sessionLabel session" `
    -Message "Closed trades: $($sells.Count) | Net P/L `$$([math]::Round($netPl,2)) | Purified `$$([math]::Round($netPurified,2)) | Balance `$$balanceUsd (SAR $balanceSar) | Open: $openPos" | Out-Null

if (Publish-DataCommit "Daily summary $session") { Invoke-OutboxDrain -Cfg $cfg }
else { Write-Warning "Data commit did not land; leaving the summary undelivered on purpose." }
