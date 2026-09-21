# Durable idempotency layer for the US cloud tracker.
# Dot-sourced by Get-Signals.ps1 and Get-DailySummary.ps1 - not run directly.
#
# WHY THIS EXISTS
# ---------------
# Two defects were found on 2026-09-21:
#
#   1. Nothing recorded WHICH bar a decision was made on. The workflow was being
#      dispatched every 5 minutes, so all ~288 runs a day re-evaluated the same
#      settled daily bar. Signals are level-based, not cross-based, so an exit
#      immediately re-armed an entry on that same bar. On 2026-09-04/05 this
#      produced four fills at prices identical to the session's real ones.
#
#   2. The ntfy push was sent from inside the run, BEFORE the commit that made
#      the trade durable. A failed push step meant "alert sent, trade lost"; a
#      workflow re-run meant "alert sent twice".
#
# THE FIX IS NOT "send the notification later". Reordering alone still loses or
# duplicates whenever the process dies between the send and the record of it.
# Instead:
#
#   * The git commit is the transaction boundary. State, ledger and outbox are
#     written together and committed together, so a trade and the intent to
#     announce it become durable as one atomic unit.
#
#   * Delivery is a separate two-phase drain with a persisted claim:
#         pending --(commit)--> sending --(send)--> sent --(commit)
#     The claim is pushed BEFORE the HTTP call. If anything dies mid-flight the
#     entry is left in `sending`, which is never auto-retried - it is surfaced
#     as `needs_review` instead.
#
#   * That yields AT-MOST-ONCE automatic delivery. Exactly-once is impossible
#     against an endpoint with no dedup token (ntfy accepts no client-supplied
#     message id), so the residual ambiguity is made visible to a human rather
#     than resolved by guessing. For trade alerts, a missed alert you can see
#     beats a phantom alert you cannot.
#
#   * The TRADE is exactly-once regardless of delivery outcome, because the bar
#     guard and the ledger are persisted independently of the notification.

$OutboxPath      = Join-Path $DataDir "outbox.json"
$OutboxStaleMins = 45

# Seams for tests: overridden to simulate push failure / capture sends.
if (-not (Test-Path variable:script:OutboxPublisher)) { $script:OutboxPublisher = $null }
if (-not (Test-Path variable:script:OutboxSender))    { $script:OutboxSender    = $null }

function Read-Outbox {
    if (Test-Path $OutboxPath) {
        $raw = Get-Content $OutboxPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $parsed = $raw | ConvertFrom-Json
            if ($null -eq $parsed) { return @() }
            return @($parsed)
        }
    }
    return @()
}

function Save-Outbox($Entries) {
    $arr = @($Entries)
    if ($arr.Count -eq 0) { "[]" | Set-Content $OutboxPath -Encoding utf8; return }
    # ConvertTo-Json collapses a 1-element array into a bare object; wrap it.
    $json = $arr | ConvertTo-Json -Depth 10
    if ($arr.Count -eq 1) { $json = "[" + $json + "]" }
    $json | Set-Content $OutboxPath -Encoding utf8
}

function Get-BarId {
    # The identity of the decision. Everything downstream is keyed on this.
    param($Bars)
    if (-not $Bars -or @($Bars).Count -eq 0) { return $null }
    $b = @($Bars)
    return ([datetime]$b[-1].time).ToString("yyyy-MM-dd")
}

function New-BarGuard {
    # `decided` is the real interlock: ONE decision cycle per completed bar.
    #
    # It is not enough to allow "one exit and one entry" per bar. The exit and
    # the entry used to happen in two different dispatches five minutes apart,
    # which meant an unused entry slot stayed open on a settled bar and could be
    # filled days later - on a Saturday, or on a market holiday, at a stale
    # price. Under a twice-daily schedule it would have been worse still: an
    # exit would leave the account flat until the following session.
    #
    # So a run now completes the whole cycle (exit, then entry if that leaves it
    # flat) and stamps the bar as decided. Both legs use the same closed bar's
    # close price, which is the price the split version used anyway, so this
    # changes no fill price and no strategy behaviour.
    param([string]$BarId)
    [pscustomobject]@{
        bar_id     = $BarId
        decided    = $false
        exit_done  = $false
        entry_done = $false
        closed     = @()
        opened     = @()
    }
}

function Get-BarGuard {
    # Returns the guard for $BarId, resetting it if the session has rolled over.
    # A stale bar_id is self-blocking, which is why weekends and US market
    # holidays need no calendar: on a non-session day Yahoo returns no new bar,
    # so the last closed bar is one already acted on and every action is denied.
    param($State, [string]$BarId)
    $g = $State.bar_guard
    if (-not $g -or $g.bar_id -ne $BarId) { return (New-BarGuard -BarId $BarId) }
    foreach ($f in 'decided', 'exit_done', 'entry_done', 'closed', 'opened') {
        if ($null -eq $g.$f) {
            $v = if ($f -eq 'closed' -or $f -eq 'opened') { @() } else { $false }
            $g | Add-Member -NotePropertyName $f -NotePropertyValue $v -Force
        }
    }
    $g.closed = @($g.closed)
    $g.opened = @($g.opened)
    return $g
}

function Test-BarDecided {
    param($Guard)
    return [bool]$Guard.decided
}

function Test-CanExit {
    param($Guard, [string]$Ticker)
    if ($Guard.decided)                  { return $false }
    if ($Guard.exit_done)                { return $false }
    if ($Guard.closed -contains $Ticker) { return $false }
    return $true
}

function Test-CanEnter {
    param($Guard, [string]$Ticker)
    if ($Guard.decided)                  { return $false }
    if ($Guard.entry_done)               { return $false }
    if ($Guard.opened -contains $Ticker) { return $false }
    # Never re-enter a name that was exited on this same bar.
    if ($Guard.closed -contains $Ticker) { return $false }
    return $true
}

function Complete-BarDecision {
    # Stamps the bar as fully processed. Every later dispatch against it is a
    # no-op, which is what makes weekends, holidays, retries and manual re-runs
    # safe without any market-calendar logic.
    param($Guard)
    $Guard.decided = $true
}

function Register-Exit {
    param($Guard, [string]$Ticker)
    $Guard.exit_done = $true
    $Guard.closed    = @($Guard.closed) + $Ticker
}

function Register-Entry {
    param($Guard, [string]$Ticker)
    $Guard.entry_done = $true
    $Guard.opened     = @($Guard.opened) + $Ticker
}

function New-OutboxEvent {
    # $Id is deterministic (action:ticker:bar_id), so a re-derived decision
    # produces the same key and is recognised as already queued or delivered.
    param([string]$Id, [string]$Title, [string]$Message)
    [pscustomobject]@{
        id          = $Id
        title       = $Title
        message     = $Message
        status      = "pending"
        attempts    = 0
        created_utc = (Get-Date).ToUniversalTime().ToString("s") + "Z"
        claimed_utc = $null
        sent_utc    = $null
        last_error  = $null
    }
}

function Add-OutboxEvent {
    param([string]$Id, [string]$Title, [string]$Message)
    $entries = @(Read-Outbox)
    if ($entries | Where-Object { $_.id -eq $Id }) {
        Write-Host "outbox: '$Id' already queued or delivered; not re-queued."
        return $false
    }
    $entries += (New-OutboxEvent -Id $Id -Title $Title -Message $Message)
    Save-Outbox $entries
    Write-Host "outbox: queued '$Id'."
    return $true
}

function Publish-DataCommit {
    # Commits and pushes data/ - the transaction boundary. Returns $true only if
    # the change is durable on origin/main (or there was nothing to commit).
    param([string]$Message)

    if ($script:OutboxPublisher) { return (& $script:OutboxPublisher $Message) }
    if ($env:GITHUB_ACTIONS -ne "true") {
        Write-Host "publish: not in Actions; skipping git commit ('$Message')."
        return $true
    }

    git config user.name  "intraday-tracker-bot"             | Out-Null
    git config user.email "actions@users.noreply.github.com" | Out-Null
    git add data/ | Out-Null
    git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) { Write-Host "publish: nothing to commit."; return $true }

    git commit -m $Message | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "publish: commit failed."; return $false }

    # The Tadawul workflow writes to the same branch; rebase onto what landed.
    for ($i = 1; $i -le 5; $i++) {
        git push 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "publish: pushed ('$Message')."; return $true }
        Write-Warning "publish: push rejected (attempt $i); rebasing."
        git pull --rebase origin main 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "publish: rebase failed."; return $false }
    }
    Write-Warning "publish: push failed after 5 attempts."
    return $false
}

function Send-OutboxMessage {
    # The only place that talks to ntfy. The topic comes from the environment
    # (a GitHub Actions secret), never from a tracked file, and is never logged.
    param([string]$Title, [string]$Message)

    if ($script:OutboxSender) { return (& $script:OutboxSender $Title $Message) }

    $topic = $env:NTFY_TOPIC_US
    if ([string]::IsNullOrWhiteSpace($topic)) {
        throw "NTFY_TOPIC_US is not set; refusing to send."
    }
    Invoke-RestMethod -Method Post -Uri "https://ntfy.sh/$topic" -Body $Message `
        -Headers @{ "Title" = $Title } -TimeoutSec 15 | Out-Null
    return $true
}

function Invoke-OutboxDrain {
    # pending --(commit claim)--> sending --(send)--> sent --(commit)
    # Aborts rather than sending if the claim cannot be made durable.
    $entries = @(Read-Outbox)
    if ($entries.Count -eq 0) { return }

    $now = (Get-Date).ToUniversalTime()

    # Entries stranded in `sending` are ambiguous: the HTTP call may or may not
    # have been delivered. Never guess - surface them.
    foreach ($e in $entries) {
        if ($e.status -eq "sending" -and $e.claimed_utc) {
            $age = ($now - [datetime]::Parse($e.claimed_utc).ToUniversalTime()).TotalMinutes
            if ($age -gt $OutboxStaleMins) {
                $e.status     = "needs_review"
                $e.last_error = "Stranded mid-delivery for $([math]::Round($age)) min; delivery unconfirmed. Not auto-retried."
                Write-Warning "outbox: '$($e.id)' needs review (delivery unconfirmed)."
            }
        }
    }

    $pending = @($entries | Where-Object { $_.status -eq "pending" })
    if ($pending.Count -eq 0) { Save-Outbox $entries; return }

    foreach ($e in $pending) {
        $e.status      = "sending"
        $e.claimed_utc = $now.ToString("s") + "Z"
        $e.attempts    = [int]$e.attempts + 1
    }
    Save-Outbox $entries

    if (-not (Publish-DataCommit "outbox: claim $($pending.Count) event(s)")) {
        # Claim is not durable. Roll back in memory and send nothing: the entries
        # stay `pending` on origin and a later run retries them cleanly.
        Write-Warning "outbox: claim not durable; aborting drain without sending."
        foreach ($e in $pending) {
            $e.status      = "pending"
            $e.claimed_utc = $null
            $e.attempts    = [int]$e.attempts - 1
        }
        Save-Outbox $entries
        return
    }

    foreach ($e in $pending) {
        try {
            Send-OutboxMessage -Title $e.title -Message $e.message | Out-Null
            $e.status   = "sent"
            $e.sent_utc = (Get-Date).ToUniversalTime().ToString("s") + "Z"
            Write-Host "outbox: delivered '$($e.id)'."
        } catch {
            $e.status     = "failed"
            $e.last_error = $_.Exception.Message
            Write-Warning "outbox: delivery failed for '$($e.id)': $($_.Exception.Message)"
        }
    }
    Save-Outbox $entries
    Publish-DataCommit "outbox: record delivery of $($pending.Count) event(s)" | Out-Null
}
