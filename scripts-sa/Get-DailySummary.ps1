# Run once near Tadawul market close. Summarizes today's activity and sends a push.
# Reads-only from the CSV logs written by Get-Signals.ps1 — places no trades.

. (Join-Path $PSScriptRoot "TrackerLib.ps1")

$cfg   = Read-Config
$state = Read-State
$today = (Get-Date).ToString("yyyy-MM-dd")

$tradesPath = Join-Path $DataDir "paper_trades.csv"
$todayTrades = @()
if (Test-Path $tradesPath) {
    $todayTrades = Import-Csv $tradesPath | Where-Object { $_.timestamp_utc -like "$today*" }
}

$sells = $todayTrades | Where-Object { $_.action -eq "SELL" }
$netPl = ($sells | ForEach-Object { [double]$_.pl_sar } | Measure-Object -Sum).Sum
$netPurified = ($sells | ForEach-Object { [double]$_.purification_sar } | Measure-Object -Sum).Sum
if (-not $netPl) { $netPl = 0 }
if (-not $netPurified) { $netPurified = 0 }

$balanceSar = $state.portfolio.balance_sar
$openPos = if ($state.open_position) { "$($state.open_position.ticker) @ SAR $($state.open_position.entry_price)" } else { "none" }

Append-Csv -Path (Join-Path $DataDir "daily_summary.csv") -Row ([pscustomobject]@{
    date              = $today
    trades_closed     = $sells.Count
    net_pl_sar        = [math]::Round($netPl, 4)
    purified_sar      = [math]::Round($netPurified, 4)
    balance_sar       = $balanceSar
    open_position     = $openPos
    total_realized_pl_sar = $state.portfolio.realized_pl_sar
    total_purified_sar    = $state.portfolio.purified_total_sar
})

Notify-User -Topic $cfg.ntfy_topic -Title "Tadawul daily summary" -Message "Closed trades: $($sells.Count) | Net P/L SAR $([math]::Round($netPl,2)) | Purified SAR $([math]::Round($netPurified,2)) | Balance SAR $balanceSar | Open: $openPos"
