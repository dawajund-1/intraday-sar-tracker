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

Same ntfy.sh topic as the PC version (`intraday-sar-7a1d968b28` in `config.json`), so
your existing phone subscription keeps receiving alerts without resubscribing.

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
