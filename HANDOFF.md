# Handoff — intraday trackers

Read this first in a new session. It is deliberately public: it contains no
secrets, no tokens and no notification topics.

*Current as of 2026-10-12.*

---

## The two projects

| | A — live US tracker | B — breadth research |
|---|---|---|
| Repo | `dawajund-1/intraday-sar-tracker` (this one) | `dawajund-1/intraday-breadth-research` |
| Dashboard | https://dawajund-1.github.io/intraday-sar-tracker/ | https://dawajund-1.github.io/intraday-breadth-research/ |
| Rule | Wilder RSI(2) daily — buy <30, sell >70 | identical, frozen |
| Scope | 8 mega-caps, one position at a time | 150 liquid US names, 25 slots |
| Money | paper, ~$27 notional | paper, 25 × 100 SAR = 2,500 SAR notional |
| Language | PowerShell | Python |
| Schedule (UTC) | `30 21 * * 1-5` signals, `45 21 * * 1-5` summary | `0 22 * * 1-5` |
| Alerts | ntfy, topic in the `NTFY_TOPIC_US` secret | **none — no alert path exists** |

## The single most important fact

**Project B's strategy failed its pre-registered holdout test.** Out of sample on
2022–2026 it reached only the 90.2nd percentile against matched random entry —
p = 0.098 raw, **0.588 after Holm correction** across 9 pre-declared tests.
Verdict: **NOT GENERALIZED**.

It is not distinguishable from entering the same names on random dates for the same
holding periods. The paper account exists to accumulate out-of-sample evidence, not
because an edge was found.

**Do not** tune parameters, change the universe to improve results, filter trades by
profitability, or describe paper results as validation. `PREREGISTRATION.md` in repo B
is the contract.

## Current state

**A** — balance $38.6091, realized $13.4717, purified $1.5293, **META open**, last
decided bar 2026-10-09.

**B** — 25 slots, **0 open, 23 buy orders queued** from the 2026-10-09 session, 0 closed
trades, 2,500 SAR notional. Schema 2 started flat on 2026-10-10.

Queued orders fill at the **next** completed bar, never the one that signalled them. If
you see 23 pending and 0 positions, that is correct.

## Hard constraints

- **Do not touch Tadawul.** Both its workflows are disabled and its scripts still carry
  the duplicate-execution bug that was fixed in A. `scripts-sa/`, `config-sa.json`,
  `docs/saudi.html`, `*-sa.yml`.
- **Do not modify Project A's ledger rows.** A correction is proposed but unapproved.
- **Do not add any notification path to B.** Its CI isolation guard fails the build on
  any reference to A, any ntfy topic, any broker or order surface, any USD account
  state, or any live FX lookup.
- Workflow files under `.github/workflows/` need a token with `workflow` scope; without
  it, use the GitHub web editor.

## Safety machinery — do not remove

- **Bar guard** — one decision cycle per completed daily bar, persisted in state.
  Reruns and retries are no-ops. Weekends and market holidays need no calendar: no new
  session means no new bar, so the bar is already decided.
- **Partial bars are never used.** A bar dated today is dropped until the session closes
  at 20:00 UTC. This is why nothing can run mid-session — RSI(2) needs a *closing*
  price, and an unsettled one wanders across the threshold all day.
- **Transactional outbox (A only)** — the alert is queued in the same git commit as the
  trade; delivery is a two-phase drain that commits its claim *before* the HTTP call.
  At-most-once; a stranded event becomes `needs_review` rather than being re-sent.
- **Next-session execution (B)** — signal on bar D, fill at bar D+1's close.
- **Independent slots (B)** — each of the 25 is its own 100 SAR account. They never share
  capital or profit. Stake is fixed at 100 SAR, not compounded, so the per-trade estimate
  does not depend on the order trades arrived in.
- Tests: A has 54 (`scripts/Test-Idempotency.ps1`), B has 83 (`paper/tests_paper.py`).
  B's workflow runs the isolation guard and the tests *before* each cycle.

## Open decisions — ask before assuming

1. **Ledger correction (A).** Four phantom fills on session bar 2026-09-04 are still in
   the ledger. Proposed append-only fix (VOID + ADJUSTMENT rows, nothing deleted), as of
   2026-09-21: balance $36.4180 → $34.1504, realized $11.0352 → $8.5157, purified
   $1.2839 → $1.0320. Later trades have moved the totals since. Until approved,
   `pl_provisional: true` stays set and every weekly/monthly figure shows a warning.
   See `RECONCILIATION-2026-09-21.md`.
2. **Unused fine-grained token** `dawajund-1/intraday-sar-tracker` — Actions read+write,
   repo-scoped, **no expiry**, and nothing uses it. Recommended: delete it.
3. **Tadawul** — leave off, port the repair across, or retire it.

## Things that look like bugs but are not

- **Scheduled runs land 3–4 hours late.** GitHub's delay. Harmless: every guard keys on
  the bar id, not the clock. The cron is 21:30/22:00 UTC; runs typically land ~01:00–01:50.
- **Alerts arrive at 07:00 AST, not when the job ran.** Deliberate. Riyadh quiet hours
  are enforced with ntfy's `At` header, because the run lands around 04:00 local.
  Config: `notifications` in `config.json`.
- **Timestamps differ from session dates.** The timestamp is when the job *ran*; the
  session is which close it traded. Weekly and monthly totals bucket by **session**, not
  run time. Dashboards show Riyadh time (AST) only.
- **B showing a loss.** v1 ran −1.37 SAR over 36 trades, of which one day (2026-10-09,
  −1.43 SAR across 9 trades) was more than the entire loss. 95% CI −2.34% to +0.46% per
  trade — it neither confirms nor refutes the research estimate of +0.32%. That is what
  "not distinguishable from random" looks like in practice. v1 is archived at
  `paper/*-v1-shared-pool.*` in repo B; its per-trade **percentage** returns remain valid
  evidence, its SAR accounting does not carry across.
- **A occasionally skipping a session.** On 2026-10-10 the run fired at 01:05 UTC before
  Yahoo had published Friday's daily bar, so it decided Thursday's. The rule is
  level-based, so a missed day re-signals the next session.

## Useful commands

```bash
gh workflow list --repo dawajund-1/intraday-sar-tracker --all
gh run list --repo dawajund-1/intraday-breadth-research --limit 5
pwsh ./scripts/Get-PeriodPerformance.ps1          # repo A: independent rollup audit
python paper/run_paper.py --audit                 # repo B: same, in SAR
python paper/tests_paper.py                       # repo B: 83 tests
python research/isolation_check.py                # repo B: isolation guard
```
