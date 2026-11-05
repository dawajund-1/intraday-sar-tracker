"""Fetch daily closing prices for the halal watchlist from Yahoo's public chart API.

Writes halal/prices.json. Read-only market data: no orders, no alerts, no account state.
A bar dated today in New York is kept out of the history until 16:10 New York, so the
history only ever holds settled closes; the live price is reported separately.
"""
import json, time, urllib.request
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

NY = ZoneInfo("America/New_York")
tickers = json.load(open("halal/tickers.json"))["tickers"]
now_ny = datetime.now(NY)
settled = (now_ny.hour, now_ny.minute) >= (16, 10)
out = {"updated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "source": "Yahoo Finance chart API, daily bars", "tickers": {}}
failed = []
for t in tickers:
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{t}?interval=1d&range=2y"
    data = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            data = json.load(urllib.request.urlopen(req, timeout=20))
            break
        except Exception as e:
            time.sleep(3 * (attempt + 1))
    if not data or not data.get("chart", {}).get("result"):
        failed.append(t); continue
    r = data["chart"]["result"][0]
    meta = r["meta"]; ts = r.get("timestamp") or []
    closes = r["indicators"]["quote"][0].get("close") or []
    dates, cl = [], []
    for s, c in zip(ts, closes):
        if c is None: continue
        d = datetime.fromtimestamp(s, NY).date()
        if d == now_ny.date() and not settled: continue
        if dates and dates[-1] == d.isoformat():
            dates.pop(); cl.pop()
        dates.append(d.isoformat()); cl.append(round(float(c), 4))
    pt = meta.get("regularMarketTime")
    out["tickers"][t] = {
        "price": meta.get("regularMarketPrice"),
        "price_time_ny": datetime.fromtimestamp(pt, NY).strftime("%Y-%m-%d %H:%M") if pt else None,
        "dates": dates, "close": cl,
    }
out["failed"] = failed
json.dump(out, open("halal/prices.json", "w"), separators=(",", ":"))
print(f"wrote {len(out['tickers'])} tickers, failed: {failed}")
