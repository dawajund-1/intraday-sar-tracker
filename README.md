# Intraday Signal Tracker (cloud version)

Same tool as the PC version, but runs on GitHub Actions instead of your PC, so it keeps
checking signals and pushing alerts even when your computer is off.

**Never logs into Awaed and never places a real order.** It fetches public US market
data, computes an EMA9/EMA21 crossover signal per ticker, tracks a hypothetical
("paper") position and balance, pushes an alert to your phone (via ntfy.sh) when a
crossover fires, and publishes a live dashboard.

## Dashboard

https://dawajund-1.github.io/intraday-sar-tracker/

Bookmark it or, on iPhone, open it in Safari and use **Share → Add to Home Screen** for
an app-like icon. It re-fetches the latest data every time you open it, so you'll see
current signals whenever you check — no need for the PC to be involved.

Note: this repo (and therefore the signals/journal/balance data) is **public** — anyone
with the link can view it. No real account or financial credentials are stored anywhere
in it.

## How it runs

- `.github/workflows/signals.yml` — runs hourly, Mon–Fri, 13:00–20:00 UTC (16:00–23:00
  Riyadh time, covering US market hours across EST/EDT).
- `.github/workflows/daily-summary.yml` — runs once daily at 20:05 UTC (23:05 Riyadh).
- Both can also be triggered manually from the **Actions** tab (Run workflow button).
- Each run reads/writes `data/*.json` and `data/*.csv`, then commits the changes back
  to the repo — that's the persistent state and journal.

## Editing settings

Edit `config.json` (watchlist, EMA periods, purification %, starting capital) directly
on GitHub (pencil icon on the file) or by cloning and pushing. Takes effect on the next
scheduled run — no redeploy needed.

`purification_pct` is currently `1.0` (100%) — every profit is set aside and the
balance doesn't compound. Lower it (e.g. `0.1`) if you want profits to roll back into
the tradeable balance.

## Files

| Path | Purpose |
|---|---|
| `config.json` | Settings, read fresh every run. |
| `scripts/` | The PowerShell logic (runs via `pwsh`, preinstalled on GitHub's runners). |
| `data/state.json` | Current EMA trend per ticker + open position + balance. |
| `data/signals_log.csv` | Every check, every ticker, every hour. |
| `data/paper_trades.csv` | Only the actual paper BUY/SELL trades. |
| `data/portfolio_history.csv` | Balance after each closed trade. |
| `data/daily_summary.csv` | One row per trading day. |
| `data/latest_snapshot.json` | What the dashboard reads. |
| `docs/index.html` | The dashboard (served via GitHub Pages). |

## Phone alerts

US alerts go to an ntfy.sh topic held **only** in the GitHub Actions secret
`NTFY_TOPIC_US`. It is never committed and never printed in workflow logs.

The previous US topic was published in this repo, which made it world-readable and
world-writable on ntfy.sh — anyone reading the repo could receive your alerts or post
fake ones. It was rotated on 2026-09-21. The old topic still appears in git history, so
it must never be reused; unsubscribe from it on your phone.

Alerts are informational only: they carry no credentials, links or controls, and
nothing in an alert can cause a trade.

### When alerts arrive

Right after the US close, on Riyadh time: **about 23:15 in summer, 00:15 in winter**
(the US session ends at 16:00 New York time, and New York changes its clocks while
Riyadh does not).

GitHub's own `schedule` trigger lands 3-4 hours late, so it is no longer relied on for
timing. A scheduled task starts `signals.yml` and then `daily-summary.yml` with
`workflow_dispatch` at 16:15 New York time every weekday; a dispatched run starts within
seconds. The two crons stay in place as a **backup** only - if the on-time run already
decided the bar and sent the summary, the backup is a no-op.

The close itself is computed on New York's clock (`live.market_timezone`,
`live.market_close_local`, plus `close_settle_minutes` for the official closing price),
so the November and March clock changes need no edits.

ntfy delivers immediately between `07:00` and `01:30` Riyadh. Anything produced between
01:30 and 07:00 - i.e. a late backup run - is held with ntfy's `At` header and delivered
at 07:00, so it never wakes you. Edit the `notifications` block in `config.json` to
change the window.

To subscribe a new device, install ntfy, add the topic held in `NTFY_TOPIC_US`, and
leave the server as the default `ntfy.sh`. If that secret is ever lost it cannot be read
back — generate a new topic, update the secret, and resubscribe.

## Caveats

- EMA crossover on hourly bars is a simple signal, not a guarantee of profit — treat
  results as a way to test the idea, not as advice.
- $100 SAR (~$26.67) is far below what most strategies need to overcome real trading
  costs. Check Awaed's actual fees/minimums before ever trading real money.
- Yahoo Finance's chart endpoint is unofficial and can change without notice.
- GitHub Actions' `schedule` trigger can lag a few minutes under load — not guaranteed
  to the minute.
- Decision-support and bookkeeping only, not investment advice, not a broker
  connection. All real decisions and execution stay with you in Awaed.
