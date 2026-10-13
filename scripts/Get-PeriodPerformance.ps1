# Recompute the dashboard's weekly and monthly performance from the ledger.
#
# This exists so the numbers on the dashboard can be checked by something other
# than the dashboard. It is READ ONLY: it opens data/paper_trades.csv, prints
# totals, and writes nothing. No ledger row is modified, normalised or corrected.
#
#   pwsh ./scripts/Get-PeriodPerformance.ps1
#
# Rules (identical to docs/index.html):
#   * Only SELL rows are realized. BUY rows carry no P/L.
#   * A trade belongs to the market SESSION it closed on, NOT to the moment the
#     job happened to run. GitHub delays the cron 3-4 hours, so every row in this
#     ledger was written the day after its session; bucketing by run time would
#     push a month-end session into the following month.
#   * Weeks are ISO-8601: Monday-Sunday, the ISO year taken from the Thursday.
#   * Months are calendar months, UTC.
#   * Realized P/L  = sum of pl_usd
#   * Purification  = sum of purification_usd
#   * win = pl_usd > 0, loss = pl_usd < 0 (exactly zero counts as neither)
#
# Unrealized P/L on an open position is deliberately NOT included: this script
# reports realized results only, as the dashboard does.

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Ledger   = Join-Path $RepoRoot "data/paper_trades.csv"

function Get-SessionDate {
    # Mirrors Remove-PartialBar and the dashboard's sessionOf(): at or after
    # 20:00 UTC the session is that same day, otherwise the previous weekday.
    # Market holidays are not known here, so a session following one can be
    # attributed a day early - immaterial for week and month totals.
    param([datetime]$RunUtc)
    $d = $RunUtc.Date
    if ($RunUtc.Hour -lt 20) { $d = $d.AddDays(-1) }
    while ($d.DayOfWeek -eq 'Saturday' -or $d.DayOfWeek -eq 'Sunday') { $d = $d.AddDays(-1) }
    return $d
}

function Get-IsoWeek {
    # Portable ISO-8601 week. Avoids System.Globalization.ISOWeek so the script
    # behaves identically on Windows PowerShell 5.1 and pwsh 7.
    param([datetime]$Date)
    $d = $Date.Date
    $dow = ([int]$d.DayOfWeek + 6) % 7          # Mon = 0
    $thursday = $d.AddDays(3 - $dow)
    $isoYear = $thursday.Year
    $jan4 = Get-Date -Year $isoYear -Month 1 -Day 4 -Hour 0 -Minute 0 -Second 0
    $jan4dow = ([int]$jan4.DayOfWeek + 6) % 7
    $week1Mon = $jan4.Date.AddDays(-$jan4dow)
    # Cast to int: the "D2" format specifier is integer-only, and Math::Round
    # hands back a double.
    $week = [int][math]::Round(($thursday - $week1Mon).TotalDays / 7) + 1
    [pscustomobject]@{ Year = [int]$isoYear; Week = [int]$week; Monday = $d.AddDays(-$dow) }
}

if (-not (Test-Path $Ledger)) { Write-Error "Ledger not found: $Ledger" }

# SELL rows plus the append-only VOID/ADJUST corrections (2026-10-13
# reconciliation) that carry a P/L difference. A VOID of a sale removes it from
# the closed count and from wins/losses; an ADJUST changes P/L only.
$sells = Import-Csv $Ledger | Where-Object {
    $_.action -eq "SELL" -or (($_.action -eq "VOID" -or $_.action -eq "ADJUST") -and -not [string]::IsNullOrWhiteSpace($_.pl_usd)) }
if (-not $sells) { Write-Host "No closed trades in the ledger."; return }

$rows = foreach ($r in $sells) {
    $ts = [datetime]::Parse($r.timestamp_utc, [cultureinfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
                            [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    $session = Get-SessionDate -RunUtc $ts
    $iso = Get-IsoWeek -Date $session
    $pl  = if ([string]::IsNullOrWhiteSpace($r.pl_usd)) { 0.0 } else { [double]$r.pl_usd }
    $pur = if ([string]::IsNullOrWhiteSpace($r.purification_usd)) { 0.0 } else { [double]$r.purification_usd }
    [pscustomobject]@{
        WeekKey  = "{0}-W{1:D2}" -f $iso.Year, $iso.Week
        WeekSpan = "{0:yyyy-MM-dd} .. {1:yyyy-MM-dd}" -f $iso.Monday, $iso.Monday.AddDays(6)
        MonthKey = $session.ToString("yyyy-MM")
        Pl = $pl; Pur = $pur
        Closed = if ($r.action -eq "SELL") { 1 } elseif ($r.action -eq "VOID") { -1 } else { 0 }
        Win    = if ($r.action -eq "SELL") { [int]($pl -gt 0) } elseif ($r.action -eq "VOID") { -[int]($pl -lt 0) } else { 0 }
        Loss   = if ($r.action -eq "SELL") { [int]($pl -lt 0) } elseif ($r.action -eq "VOID") { -[int]($pl -gt 0) } else { 0 }
    }
}

function Write-Rollup {
    param([string]$Title, [string]$KeyProp, $Rows, [string]$SpanProp)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
    "{0,-30} {1,7} {2,9} {3,16} {4,12} {5,16}" -f `
        "Period", "Closed", "W / L", "Realized net P/L", "Purified", "Cumulative" | Write-Host
    $cum = 0.0
    foreach ($g in ($Rows | Group-Object $KeyProp | Sort-Object Name)) {
        $pl  = ($g.Group | Measure-Object Pl  -Sum).Sum
        $pur = ($g.Group | Measure-Object Pur -Sum).Sum
        $w = ($g.Group | Measure-Object Win  -Sum).Sum
        $l = ($g.Group | Measure-Object Loss -Sum).Sum
        $n = ($g.Group | Measure-Object Closed -Sum).Sum
        $cum += $pl
        $label = if ($SpanProp) { "{0}  ({1})" -f $g.Name, $g.Group[0].$SpanProp } else { $g.Name }
        "{0,-30} {1,7} {2,9} {3,16} {4,12} {5,16}" -f `
            $label, $n, "$w / $l",
            ("{0:+0.0000;-0.0000;0.0000}" -f $pl),
            ("{0:0.0000}" -f $pur),
            ("{0:+0.0000;-0.0000;0.0000}" -f $cum) | Write-Host
    }
}

Write-Host "Ledger : $Ledger"
Write-Host "Source : SELL rows + VOID/ADJUST corrections, attributed by market SESSION (derived from the run"
Write-Host "         timestamp, which lands the day after). Currency: USD."

Write-Rollup -Title "Weekly (ISO-8601, Monday-Sunday, by session)" -KeyProp WeekKey -Rows $rows -SpanProp WeekSpan
Write-Rollup -Title "Monthly (calendar, by session)" -KeyProp MonthKey -Rows $rows

$tp  = ($rows | Measure-Object Pl  -Sum).Sum
$tpu = ($rows | Measure-Object Pur -Sum).Sum
Write-Host ""
Write-Host ("TOTAL  closed={0}  realized net P/L={1:+0.0000;-0.0000;0.0000} USD  purified={2:0.0000} USD" -f `
    ($rows | Measure-Object Closed -Sum).Sum, $tp, $tpu) -ForegroundColor Green
Write-Host ""
Write-Host "NOTE: reconciled 2026-10-13. The four duplicate fills of session bar 2026-09-04"
Write-Host "      are voided and later trades re-sized via append-only VOID/ADJUST rows,"
Write-Host "      which are included above. See RECONCILIATION-2026-09-21.md."
