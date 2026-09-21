# Regression tests for the once-per-bar guard and the notification outbox.
#
# No network calls, no git calls, no real ntfy topic. The publisher and sender
# are replaced with in-memory fakes so commit failure and delivery failure can
# be driven deterministically.
#
# Run:  pwsh ./scripts/Test-Idempotency.ps1

$ErrorActionPreference = "Stop"

$script:Pass = 0
$script:Fail = 0
$script:Failures = @()

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:Pass++; Write-Host "  PASS  $Name" }
    else { $script:Fail++; $script:Failures += $Name; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    Assert-True ($Expected -eq $Actual) "$Name (expected '$Expected', got '$Actual')"
}

# --- harness -------------------------------------------------------------
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("idem_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TestRoot | Out-Null
$DataDir = $TestRoot
. (Join-Path $PSScriptRoot "OutboxLib.ps1")

$script:SentMessages = @()
$script:PublishOk    = $true
$script:PublishCalls = @()

function Reset-Harness {
    param([bool]$PublishOk = $true)
    Remove-Item (Join-Path $TestRoot "*") -Force -ErrorAction SilentlyContinue
    $script:SentMessages = @()
    $script:PublishCalls = @()
    $script:PublishOk    = $PublishOk
    $script:OutboxPublisher = { param($m) $script:PublishCalls += $m; return $script:PublishOk }
    $script:OutboxSender    = { param($t, $b) $script:SentMessages += "$t|$b"; return $true }
}

# A faithful stand-in for the decision block in Get-Signals.ps1: same guard
# calls, same order, no network. Returns what the run actually did.
function Invoke-SimulatedRun {
    param(
        $State,
        [string]$BarId,
        [string]$SellFor = $null,    # ticker with a SELL signal (if held)
        [string[]]$BuyCandidates = @()
    )
    $guard  = Get-BarGuard -State $State -BarId $BarId
    $acted  = @()

    if ($BarId -and -not (Test-BarDecided -Guard $guard)) {
        # leg 1: exit
        if ($State.open_position) {
            $held = $State.open_position.ticker
            if ($SellFor -eq $held -and (Test-CanExit -Guard $guard -Ticker $held)) {
                $State.open_position = $null
                Register-Exit -Guard $guard -Ticker $held
                Add-OutboxEvent -Id "SELL:${held}:${BarId}" -Title "SELL signal: $held" -Message "exit" | Out-Null
                $acted += "SELL:$held"
            }
        }
        # leg 2: entry, in the same cycle
        if (-not $State.open_position) {
            $cand = $BuyCandidates | Where-Object { Test-CanEnter -Guard $guard -Ticker $_ } | Select-Object -First 1
            if ($cand) {
                $State.open_position = [pscustomobject]@{ ticker = $cand }
                Register-Entry -Guard $guard -Ticker $cand
                Add-OutboxEvent -Id "BUY:${cand}:${BarId}" -Title "BUY signal: $cand" -Message "entry" | Out-Null
                $acted += "BUY:$cand"
            }
        }
        Complete-BarDecision -Guard $guard
    }

    if ($BarId) { $State | Add-Member -NotePropertyName bar_guard -NotePropertyValue $guard -Force }
    if (Publish-DataCommit "sim") { Invoke-OutboxDrain }
    return $acted
}

function New-TestState {
    param($OpenTicker = $null)
    [pscustomobject]@{
        open_position = if ($OpenTicker) { [pscustomobject]@{ ticker = $OpenTicker } } else { $null }
        bar_guard     = $null
    }
}

Write-Host "`n=== Bar guard ==="
Reset-Harness
$g = New-BarGuard -BarId "2026-09-21"
Assert-True (Test-CanExit  -Guard $g -Ticker "MSFT") "fresh bar allows an exit"
Assert-True (Test-CanEnter -Guard $g -Ticker "MSFT") "fresh bar allows an entry"
Register-Exit -Guard $g -Ticker "MSFT"
Assert-True (-not (Test-CanExit  -Guard $g -Ticker "NVDA")) "second exit on the same bar is denied"
Assert-True (-not (Test-CanEnter -Guard $g -Ticker "MSFT")) "re-entry into a ticker exited on this bar is denied"
Assert-True (Test-CanEnter -Guard $g -Ticker "NVDA")        "a different ticker may still be entered on this bar"
Register-Entry -Guard $g -Ticker "NVDA"
Assert-True (-not (Test-CanEnter -Guard $g -Ticker "AMD"))  "second entry on the same bar is denied"

$st = New-TestState
$st | Add-Member -NotePropertyName bar_guard -NotePropertyValue $g -Force
$g2 = Get-BarGuard -State $st -BarId "2026-09-22"
Assert-True ($g2.exit_done -eq $false -and $g2.entry_done -eq $false) "guard resets when the bar rolls over"
$g3 = Get-BarGuard -State $st -BarId "2026-09-21"
Assert-True ($g3.exit_done -eq $true) "guard for the same bar is reloaded, not reset"

Assert-Equal "2026-09-21" (Get-BarId -Bars @(
    [pscustomobject]@{ time = [datetime]"2026-09-18T20:00:00Z" },
    [pscustomobject]@{ time = [datetime]"2026-09-21T20:00:00Z" })) "Get-BarId takes the last closed bar"
Assert-True ($null -eq (Get-BarId -Bars @())) "Get-BarId is null when there are no bars"

Write-Host "`n=== Repeated dispatches against one settled bar ==="
Reset-Harness
$st = New-TestState -OpenTicker "MSFT"
$all = @()
foreach ($i in 1..288) {
    $all += Invoke-SimulatedRun -State $st -BarId "2026-09-21" -SellFor "MSFT" -BuyCandidates @("NVDA", "AMD")
}
Assert-Equal 2 $all.Count                                   "288 dispatches on one bar produce exactly 2 actions"
Assert-Equal "SELL:MSFT" $all[0]                            "first action is the exit"
Assert-Equal "BUY:NVDA"  $all[1]                            "second action is a single entry in a different name"
Assert-Equal 2 $script:SentMessages.Count                   "exactly 2 notifications delivered for 288 dispatches"
Assert-Equal 2 (@(Read-Outbox).Count)                       "outbox holds exactly 2 events"
Assert-True  (@(Read-Outbox | Where-Object { $_.status -ne 'sent' }).Count -eq 0) "all events reached 'sent'"

Write-Host "`n=== Same-bar exit then re-entry into the same ticker ==="
Reset-Harness
$st = New-TestState -OpenTicker "AAPL"
$a1 = Invoke-SimulatedRun -State $st -BarId "2026-09-04" -SellFor "AAPL" -BuyCandidates @("AAPL")
$a2 = Invoke-SimulatedRun -State $st -BarId "2026-09-04" -SellFor "AAPL" -BuyCandidates @("AAPL")
Assert-Equal "SELL:AAPL" ($a1 -join ",")   "the exit happens once"
Assert-Equal ""          ($a2 -join ",")   "AAPL cannot be re-entered on the bar it was exited on"

Write-Host "`n=== The 2026-09-04/05 churn, replayed ==="
# Real sequence: SELL AMD, BUY AAPL, then (hours later, same settled bar)
# SELL AAPL, BUY AMD, SELL AMD, BUY AAPL. Only the first two are legitimate.
Reset-Harness
$st = New-TestState -OpenTicker "AMD"
$acts = @()
$acts += Invoke-SimulatedRun -State $st -BarId "2026-09-04" -SellFor "AMD"  -BuyCandidates @("AAPL")
$acts += Invoke-SimulatedRun -State $st -BarId "2026-09-04" -SellFor "AAPL" -BuyCandidates @("AMD")
$acts += Invoke-SimulatedRun -State $st -BarId "2026-09-04" -SellFor "AAPL" -BuyCandidates @("AMD")
$acts += Invoke-SimulatedRun -State $st -BarId "2026-09-04" -SellFor "AMD"  -BuyCandidates @("AAPL")
Assert-Equal 2 $acts.Count                          "the four phantom fills collapse to the two real ones"
Assert-Equal "SELL:AMD,BUY:AAPL" ($acts -join ",")  "surviving actions are the genuine exit and entry"

Write-Host "`n=== Weekends and US market holidays ==="
# No session means Yahoo serves no new bar, so the bar id stays stale.
Reset-Harness
$st = New-TestState -OpenTicker "MSFT"
$fri = Invoke-SimulatedRun -State $st -BarId "2026-09-18" -SellFor "MSFT" -BuyCandidates @("NVDA")
$sat = Invoke-SimulatedRun -State $st -BarId "2026-09-18" -SellFor "MSFT" -BuyCandidates @("NVDA")
$sun = Invoke-SimulatedRun -State $st -BarId "2026-09-18" -SellFor "MSFT" -BuyCandidates @("NVDA")
Assert-Equal "SELL:MSFT,BUY:NVDA" ($fri -join ",") "Friday's close is decided once, both legs"
Assert-Equal "" ($sat -join ",")                   "Saturday adds no action (bar id unchanged)"
Assert-Equal "" ($sun -join ",")                   "Sunday adds no action (bar id unchanged)"
Assert-Equal 2 $script:SentMessages.Count          "a whole weekend of dispatches sends nothing extra"

Reset-Harness   # Thanksgiving 2026-11-26: market closed, last bar stays 11-25
$st = New-TestState -OpenTicker "AMZN"
$wed = Invoke-SimulatedRun -State $st -BarId "2026-11-25" -SellFor "AMZN" -BuyCandidates @("META")
$thu = Invoke-SimulatedRun -State $st -BarId "2026-11-25" -SellFor "AMZN" -BuyCandidates @("META")
Assert-Equal "SELL:AMZN,BUY:META" ($wed -join ",") "the pre-holiday close is decided once"
Assert-Equal "" ($thu -join ",")                   "the holiday itself adds no action"
# 2026-11-27 is a real (early-close) session, so a new bar id appears.
$fri2 = Invoke-SimulatedRun -State $st -BarId "2026-11-27" -SellFor "META" -BuyCandidates @()
Assert-Equal "SELL:META" ($fri2 -join ",")         "the next real session trades normally (early close included)"
$fri2b = Invoke-SimulatedRun -State $st -BarId "2026-11-27" -SellFor "META" -BuyCandidates @()
Assert-Equal "" ($fri2b -join ",")                 "and that session is itself decided only once"

Write-Host "`n=== Workflow failure after the notification is prepared ==="
Reset-Harness -PublishOk $false
$st = New-TestState -OpenTicker "MSFT"
$r = Invoke-SimulatedRun -State $st -BarId "2026-09-21" -SellFor "MSFT"
Assert-Equal 0 $script:SentMessages.Count  "commit failure sends nothing"
Assert-True (@(Read-Outbox | Where-Object { $_.status -eq 'pending' }).Count -eq 1) "the event stays pending for a later run"
# The next run succeeds: the queued event is delivered exactly once.
$script:PublishOk = $true
Invoke-OutboxDrain
Assert-Equal 1 $script:SentMessages.Count  "the recovered run delivers it exactly once"
Invoke-OutboxDrain
Assert-Equal 1 $script:SentMessages.Count  "a further drain does not re-send"

Write-Host "`n=== Claim cannot be made durable ==="
Reset-Harness
Add-OutboxEvent -Id "SELL:NVDA:2026-09-21" -Title "t" -Message "m" | Out-Null
$script:PublishOk = $false
Invoke-OutboxDrain
Assert-Equal 0 $script:SentMessages.Count "nothing is sent when the claim commit fails"
$e = @(Read-Outbox)[0]
Assert-Equal "pending" $e.status          "the entry is rolled back to pending"
Assert-Equal 0 $e.attempts                "the attempt counter is rolled back too"

Write-Host "`n=== Delivery confirmed but the result commit is lost ==="
Reset-Harness
Add-OutboxEvent -Id "BUY:AMD:2026-09-21" -Title "t" -Message "m" | Out-Null
# Claim commits, send succeeds, then the run dies before recording the result.
$script:OutboxPublisher = { param($m) if ($m -like 'outbox: claim*') { return $true } else { return $false } }
Invoke-OutboxDrain
Assert-Equal 1 $script:SentMessages.Count "the message went out once"
# Simulate the lost result commit: origin still shows 'sending'.
$entries = @(Read-Outbox); $entries[0].status = "sending"; $entries[0].sent_utc = $null
$entries[0].claimed_utc = (Get-Date).ToUniversalTime().AddMinutes(-90).ToString("s") + "Z"
Save-Outbox $entries
$script:OutboxPublisher = { param($m) return $true }
Invoke-OutboxDrain
Assert-Equal 1 $script:SentMessages.Count "a stranded in-flight event is never auto-resent"
Assert-Equal "needs_review" (@(Read-Outbox)[0].status) "it is surfaced for review instead"

Write-Host "`n=== Re-runs and duplicate queueing ==="
Reset-Harness
Assert-True  (Add-OutboxEvent -Id "SELL:MSFT:2026-09-21" -Title "t" -Message "m") "a new event is queued"
Assert-True  (-not (Add-OutboxEvent -Id "SELL:MSFT:2026-09-21" -Title "t" -Message "m")) "the same id is not queued twice"
Invoke-OutboxDrain
Assert-True  (-not (Add-OutboxEvent -Id "SELL:MSFT:2026-09-21" -Title "t" -Message "m")) "an already-delivered id is not re-queued"
Assert-Equal 1 $script:SentMessages.Count "a workflow re-run produces no second alert"

Write-Host "`n=== Outbox persistence ==="
Reset-Harness
Add-OutboxEvent -Id "ONE:X:2026-09-21" -Title "t" -Message "m" | Out-Null
Assert-Equal 1 (@(Read-Outbox).Count) "a single-entry outbox round-trips as an array"
Add-OutboxEvent -Id "TWO:X:2026-09-21" -Title "t" -Message "m" | Out-Null
Assert-Equal 2 (@(Read-Outbox).Count) "a two-entry outbox round-trips"

Write-Host "`n=== Alert content safety ==="
Reset-Harness
$st = New-TestState -OpenTicker "MSFT"
Invoke-SimulatedRun -State $st -BarId "2026-09-21" -SellFor "MSFT" | Out-Null
$body = $script:SentMessages -join " "
Assert-True ($body -notmatch 'ntfy\.sh|token|secret|http') "alerts carry no topic, credential or link"

Remove-Item $TestRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n------------------------------------------"
Write-Host "  passed: $script:Pass   failed: $script:Fail"
if ($script:Fail -gt 0) {
    Write-Host "  failing:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "  all green"
exit 0
