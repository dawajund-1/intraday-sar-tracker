# Ledger reconciliation — US cloud tracker, 2026-09-21

**Status: findings only. No ledger row has been deleted, edited or rewritten, and no
balance has been adjusted.** The corrections below are a proposal awaiting approval.

Until it is applied or rejected, `config.json` carries `pl_provisional: true` and the
dashboard shows a "provisional figures" banner.

---

## 1. What went wrong

Two defects combined:

1. **No bar identity.** Nothing recorded which completed daily bar a decision came
   from. `Remove-PartialBar` only discarded a *still-forming* bar; once a bar settled,
   every later run re-evaluated it.
2. **288 runs a day against that settled bar.** The workflow was being dispatched every
   5 minutes, 24/7, rather than on the documented twice-daily schedule.

RSI(2) signals are *level*-based, not *cross*-based. So once an exit set a ticker flat,
a re-entry became immediately eligible on the very same bar, and vice versa. With one
run a day this is invisible. With 288 it eventually churns.

## 2. Method

Every RSI-era fill (2026-08-20 onward) was attributed to the US session bar it must
have been derived from: a fill at or after 20:00 UTC acts on that day's bar; a fill
before 20:00 UTC can only be acting on an earlier session's bar (US close is 20:00 UTC
under EDT). A correct bar shows **at most one exit and one entry**.

| Session bar | Fills | Verdict |
|---|---|---|
| 2026-08-24 | SELL MSFT, BUY NVDA | OK |
| 2026-08-27 | SELL NVDA, BUY AMZN | OK |
| 2026-08-28 | SELL AMZN, BUY AMD | OK |
| **2026-09-04** | **6 fills — three exits, three entries** | **CORRUPTED** |
| 2026-09-10 | SELL AAPL, BUY MSFT | OK |
| 2026-09-14 | SELL MSFT, BUY NVDA | OK |
| 2026-09-17 | SELL NVDA, BUY MSFT | OK (see note) |
| 2026-09-21 | SELL MSFT | OK |

Note on 2026-09-17: the entry leg executed at 00:00 UTC on 09-18, about four hours after
the exit. That is late but **not** duplicated — it is the second leg of one cycle under
the old split-across-two-dispatches design. The repaired code completes both legs in a
single cycle, so this lateness cannot recur.

## 3. The invalid fills

All four are on session bar **2026-09-04**:

| # | Timestamp (UTC) | Action | Ticker | Price | Recorded P/L | Why invalid |
|---|---|---|---|---|---|---|
| 1 | 2026-09-05T00:00:38 | SELL | AAPL | 328.21 | +0.7978 | Closes a position opened 4 h earlier **on the same bar**. The strategy holds until a later bar closes; a same-bar round trip does not exist in the backtest. |
| 2 | 2026-09-05T00:05:26 | BUY | AMD | 456.16 | — | Second entry on one bar. |
| 3 | 2026-09-05T02:00:38 | SELL | AMD | 477.57 | +1.4877 | Third exit on one bar, and at **exactly the price AMD was already sold at earlier in that same session** — conclusive evidence the same settled bar was re-read. |
| 4 | 2026-09-05T02:05:36 | BUY | AAPL | 319.97 | — | Third entry, re-entering a name exited on this same bar, at **exactly its earlier entry price**. |

**Confidence: high, not absolute.** The prices repeating to the cent, the timestamps
falling hours after the session close, and three cycles landing on one bar are
consistent only with re-reading a settled bar. What cannot be reconstructed from the
ledger alone is whether Yahoo revised the 09-04 bar between reads — that would explain
why RSI crossed the threshold again, but it does not make the resulting fills valid.

**The chain is self-closing.** It ends holding AAPL at 319.97 — the same name and the
same price it legitimately held before the churn began. So the position was never
wrong; only the *money* is. That is what makes a clean correction possible.

## 4. Proposed correction (NOT APPLIED)

Removing the four fills is not a subtraction, because position sizing compounds: every
later trade bought a slightly different number of shares off an inflated balance. The
correction is therefore a **replay** from the last known-good state.

Seed: 2026-09-04T20:05:19, long AAPL 0.096815 @ 319.97, balance $30.978.

| Trade | Recorded P/L | Corrected P/L | Recorded balance | Corrected balance |
|---|---|---|---|---|
| 2026-09-10 SELL AAPL @ 326.57 | 0.6814 | 0.6390 | 33.6482 | 31.5531 |
| 2026-09-14 SELL MSFT @ 505.41 | 0.8862 | 0.8311 | 34.4458 | 32.3011 |
| 2026-09-17 SELL NVDA @ 219.34 | 1.3683 | 1.2831 | 35.6773 | 33.4559 |
| 2026-09-21 SELL MSFT @ 501.61 | 0.8230 | 0.7717 | 36.4180 | 34.1504 |

| Headline figure | Recorded | Corrected | Delta |
|---|---|---|---|
| Balance | $36.4180 | **$34.1504** | −$2.2676 |
| Realized P/L (all time) | $11.0352 | **$8.5157** | −$2.5195 |
| Purified total | $1.2839 | **$1.0320** | −$0.2519 |

So roughly **21% of the RSI-era realized P/L was fabricated** by the duplicate-execution
bug.

Note the purification implication: $0.2519 was set aside against profit that was never
earned. Whether that is left as given is a question for the user, not a code change.

## 5. Proposed mechanics, if approved

Append-only, never destructive:

1. Leave all 60 historical rows exactly as they are.
2. Append a `VOID` row for each of the four fills, referencing this document, so the
   ledger reads as a correcting entry rather than an erasure.
3. Append one `ADJUSTMENT` row to `portfolio_history.csv` moving the balance from
   36.4180 to 34.1504, with this document as its reason.
4. Update `data/state.json` to the corrected balance, realized P/L and purified totals.
5. Set `pl_provisional: false` in `config.json` and drop the dashboard banner.

Nothing in step 1–5 happens without explicit approval.

## 6. Why it cannot recur

- `scripts/OutboxLib.ps1` gives every decision the identity of its completed bar and
  allows exactly **one decision cycle per bar**.
- Exit and entry now complete in the same cycle, so there is no unused "entry slot"
  left open on a settled bar.
- A stale bar id is self-blocking, so weekends and US market holidays need no calendar.
- `scripts/Test-Idempotency.ps1` replays this exact 2026-09-04 sequence and asserts the
  four phantom fills collapse to the two real ones.
