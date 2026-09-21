# Shared helper functions for the cloud-hosted intraday signal tracker.
# Dot-sourced by Get-Signals.ps1 and Get-DailySummary.ps1 — not run directly.

$ErrorActionPreference = "Stop"
$ScriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $ScriptsDir
$DataDir    = Join-Path $RepoRoot "data"
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }

function Read-Config {
    Get-Content (Join-Path $RepoRoot "config.json") -Raw | ConvertFrom-Json
}

function Read-State {
    $path = Join-Path $DataDir "state.json"
    if (Test-Path $path) {
        return Get-Content $path -Raw | ConvertFrom-Json
    }
    $cfg = Read-Config
    return [pscustomobject]@{
        ticker_state   = [pscustomobject]@{}
        open_position  = $null
        # Which completed daily bar has already been acted on, and how.
        # See Get-BarGuard in OutboxLib.ps1.
        bar_guard      = $null
        portfolio      = [pscustomobject]@{
            balance_usd       = [math]::Round($cfg.starting_capital_sar / $cfg.sar_per_usd, 4)
            realized_pl_usd   = 0
            purified_total_usd = 0
        }
    }
}

function Save-State($state) {
    $path = Join-Path $DataDir "state.json"
    $state | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding utf8
}

function Get-HourlyBars {
    param([string]$Ticker, [string]$Interval, [string]$Range)
    $uri = "https://query1.finance.yahoo.com/v8/finance/chart/$Ticker`?interval=$Interval&range=$Range"
    $resp = Invoke-RestMethod -Uri $uri -Headers @{"User-Agent" = "Mozilla/5.0"} -TimeoutSec 20
    $result = $resp.chart.result[0]
    $closes = $result.indicators.quote[0].close
    $timestamps = $result.timestamp
    $rows = @()
    for ($i = 0; $i -lt $closes.Count; $i++) {
        if ($null -ne $closes[$i]) {
            $rows += [pscustomobject]@{
                time  = [DateTimeOffset]::FromUnixTimeSeconds($timestamps[$i]).UtcDateTime
                close = [double]$closes[$i]
            }
        }
    }
    return $rows
}

function Get-EmaLast {
    param([double[]]$Closes, [int]$Period)
    if ($Closes.Count -lt $Period) { return $null }
    $k = 2.0 / ($Period + 1)
    $ema = ($Closes[0..($Period - 1)] | Measure-Object -Average).Average
    for ($i = $Period; $i -lt $Closes.Count; $i++) {
        $ema = ($Closes[$i] - $ema) * $k + $ema
    }
    return $ema
}

function Get-RsiLast {
    # Wilder's RSI over the close series. Identical maths to Ind-Rsi in the
    # research harness, so the live signal matches what was backtested.
    param([double[]]$Closes, [int]$Period)
    $n = $Closes.Count
    if ($n -lt $Period + 1) { return $null }
    $g = 0.0; $l = 0.0
    for ($i = 1; $i -le $Period; $i++) {
        $d = $Closes[$i] - $Closes[$i - 1]
        if ($d -gt 0) { $g += $d } else { $l -= $d }
    }
    $ag = $g / $Period; $al = $l / $Period
    for ($i = $Period + 1; $i -lt $n; $i++) {
        $d = $Closes[$i] - $Closes[$i - 1]
        $cg = if ($d -gt 0) { $d } else { 0.0 }
        $cl = if ($d -lt 0) { -$d } else { 0.0 }
        $ag = ($ag * ($Period - 1) + $cg) / $Period
        $al = ($al * ($Period - 1) + $cl) / $Period
    }
    if ($al -eq 0) { return 100.0 }
    return 100.0 - 100.0 / (1 + $ag / $al)
}

function Remove-PartialBar {
    # A daily strategy must act on CLOSED bars only. Yahoo returns today's bar
    # while the session is still running and it keeps moving -- RSI could dip
    # below the buy level mid-session and close back above it, firing a trade
    # the backtest would never have taken. Today's bar is therefore dropped
    # until the market has actually closed.
    #
    # MarketCloseUtc is "HH:mm" in UTC, because GitHub Actions runners are UTC.
    param($Bars, [string]$Interval, [string]$MarketCloseUtc)
    if ($Interval -ne "1d" -or $Bars.Count -eq 0) { return $Bars }

    $nowUtc   = (Get-Date).ToUniversalTime()
    $lastDate = $Bars[-1].time.Date
    if ($lastDate -ne $nowUtc.Date) { return $Bars }   # already a closed prior day

    $parts    = $MarketCloseUtc -split ":"
    $closeUtc = $nowUtc.Date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
    if ($nowUtc -ge $closeUtc) { return $Bars }        # session over, bar is final

    if ($Bars.Count -eq 1) { return @() }
    return $Bars[0..($Bars.Count - 2)]
}

function Send-Toast {
    param([string]$Title, [string]$Message)
    if (-not $IsWindows) { return }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $textNodes = $template.GetElementsByTagName("text")
        $textNodes.Item(0).AppendChild($template.CreateTextNode($Title)) | Out-Null
        $textNodes.Item(1).AppendChild($template.CreateTextNode($Message)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)
        $notifier.Show($toast)
    } catch {
        Write-Warning "Toast notification failed: $($_.Exception.Message)"
    }
}

# Send-Push and Notify-User were REMOVED on 2026-09-21.
#
# They sent to ntfy directly from inside a run, before the commit that made the
# corresponding trade durable. A failed push step therefore meant "alert sent,
# trade lost", and a workflow re-run meant "alert sent twice".
#
# All notification now goes through the outbox in OutboxLib.ps1:
#   Add-OutboxEvent  -> queued in the same commit as the state change
#   Invoke-OutboxDrain -> two-phase, claim-before-send delivery
#
# They are deliberately left as throwing stubs rather than deleted, so that any
# caller that is added back by mistake fails loudly instead of quietly
# reintroducing the duplicate-alert path.
function Send-Push {
    throw "Send-Push is removed. Queue via Add-OutboxEvent and deliver with Invoke-OutboxDrain (see scripts/OutboxLib.ps1)."
}

function Notify-User {
    throw "Notify-User is removed. Queue via Add-OutboxEvent and deliver with Invoke-OutboxDrain (see scripts/OutboxLib.ps1)."
}

function Append-Csv {
    param([string]$Path, [pscustomobject]$Row)
    $exists = Test-Path $Path
    $Row | Export-Csv -Path $Path -Append:$exists -NoTypeInformation -Encoding utf8
}

function Write-Snapshot {
    param([pscustomobject]$Tickers, [pscustomobject]$State, [pscustomobject]$Cfg)
    $balanceUsd = $State.portfolio.balance_usd
    $snapshot = [pscustomobject]@{
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("s") + "Z"
        tickers          = $Tickers
        open_position    = $State.open_position
        portfolio        = [pscustomobject]@{
            balance_usd        = $balanceUsd
            balance_sar        = [math]::Round($balanceUsd * $Cfg.sar_per_usd, 2)
            realized_pl_usd    = $State.portfolio.realized_pl_usd
            purified_total_usd = $State.portfolio.purified_total_usd
        }
        config = [pscustomobject]@{
            watchlist        = $Cfg.watchlist
            purification_pct = $Cfg.purification_pct
        }
        # Surfaced on the dashboard so headline P/L is never read as settled
        # while it still contains trades flagged by the 2026-09-21 audit.
        integrity = [pscustomobject]@{
            pl_provisional      = [bool]$Cfg.pl_provisional
            provisional_reason  = $Cfg.pl_provisional_reason
            bar_guard           = $State.bar_guard
            outbox_pending      = @(Read-Outbox | Where-Object { $_.status -eq 'pending' -or $_.status -eq 'sending' }).Count
            outbox_needs_review = @(Read-Outbox | Where-Object { $_.status -eq 'needs_review' -or $_.status -eq 'failed' }).Count
        }
    }
    $snapshot | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $DataDir "latest_snapshot.json") -Encoding utf8
}
