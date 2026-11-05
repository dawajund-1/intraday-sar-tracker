// Prints today's signals for the Jund Halal Trader page. Usage: node halal/report.js [portfolio.json]
// Same maths as the page (halal/signals.js). Read-only: prints text, trades nothing.
const fs=require("fs"); const S=require("./signals.js");
const d=JSON.parse(fs.readFileSync(__dirname+"/prices.json","utf8"));
let hold={}, cash=100;
if(process.argv[2]){ try{ const p=JSON.parse(fs.readFileSync(process.argv[2],"utf8")); const st=JSON.parse(p.json||"{}"); hold=st.hold||{}; cash=st.cash??100; }catch(e){} }
const lines=[];
for(const [t,v] of Object.entries(d.tickers)){
  const c=v.close; if(c.length<5) continue;
  const {rsi,ag,al}=S.rsiSeries(c,2); const r=rsi[rsi.length-1]; const tp=S.triggerPrices(c,ag,al,2);
  const h=hold[t]; const sar=(v.price||c[c.length-1])*3.75;
  if(h){ const stop=h.avg*(1-S.RULE.stopPct/100);
    if((v.price||c[c.length-1])<=stop) lines.push(`STOP ${t}: price $${v.price} is below your stop $${stop.toFixed(2)}`);
    else if(r>S.RULE.sellAbove) lines.push(`SELL ${t}: RSI(2) ${r.toFixed(0)} is above ${S.RULE.sellAbove}`);
  } else if(r<S.RULE.buyBelow){
    lines.push(`BUY ${t}: RSI(2) ${r.toFixed(0)} is below ${S.RULE.buyBelow}`+(sar<=cash?` (1 share ${sar.toFixed(2)} SAR)`:` (needs ${sar.toFixed(0)} SAR a share, more than your ${cash.toFixed(0)} SAR)`));
  }
}
console.log(`Prices updated ${d.updated_utc}`);
console.log(lines.length? lines.join("\n") : "No buy, sell or stop signals today.");
