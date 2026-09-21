# Run once near US market close. Summarizes today's activity and sends a push.
# Reads-only from the CSV logs written by Get-Signals.ps1 — places no trades.

. (Join-Path $PSScriptRoot "TrackerLib.ps1")
. (Join-Path $PSScriptRoot "OutboxLib.ps1")

$cfg   = Read-Config
$state = Read-State
$today = (Get-Date).ToString("yyyy-MM-dd")

$tradesPath = Join-Path $DataDir "paper_trades.csv"
$todayTrades = @()
if (Test-Path $tradesPath) {
    $todayTrades = Import-Csv $tradesPath | Where-Object { $_.timestamp_utc -like "$today*" }
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
    date              = $today
    trades_closed     = $sells.Count
    net_pl_usd        = [math]::Round($netPl, 4)
    purified_usd      = [math]::Round($netPurified, 4)
    balance_usd       = $balanceUsd
    balance_sar       = $balanceSar
    open_position     = $openPos
    total_realized_pl_usd = $state.portfolio.realized_pl_usd
    total_purified_usd    = $state.portfolio.purified_total_usd
})

# One summary per calendar day, keyed by date, queued rather than sent. The
# deterministic id makes a re-run of this workflow a no-op instead of a
# second identical push.
Add-OutboxEvent -Id "SUMMARY:${today}" -Title "Daily summary" `
    -Message "Closed trades: $($sells.Count) | Net P/L `$$([math]::Round($netPl,2)) | Purified `$$([math]::Round($netPurified,2)) | Balance `$$balanceUsd (SAR $balanceSar) | Open: $openPos" | Out-Null

if (Publish-DataCommit "Daily summary $today") { Invoke-OutboxDrain }
else { Write-Warning "Data commit did not land; leaving the summary undelivered on purpose." }
