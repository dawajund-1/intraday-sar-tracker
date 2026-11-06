/* ---------- signal maths (RSI(2) exactly as in the tracker) ---------- */
const RULE = {period:2, buyBelow:30, sellAbove:70, stopPct:8};
function rsiSeries(c, n){
  const out = new Array(c.length).fill(null);
  if(c.length < n+1) return {rsi:out, ag:null, al:null};
  let g=0,l=0;
  for(let i=1;i<=n;i++){ const d=c[i]-c[i-1]; if(d>0) g+=d; else l-=d; }
  let ag=g/n, al=l/n;
  out[n] = al===0 ? 100 : 100-100/(1+ag/al);
  for(let i=n+1;i<c.length;i++){
    const d=c[i]-c[i-1];
    ag=(ag*(n-1)+(d>0?d:0))/n; al=(al*(n-1)+(d<0?-d:0))/n;
    out[i] = al===0 ? 100 : 100-100/(1+ag/al);
  }
  return {rsi:out, ag, al};
}
/* Closing price that would push RSI(2) across a line on the next close */
function triggerPrices(c, ag, al, n){
  const last=c[c.length-1];
  const kB = RULE.buyBelow/(100-RULE.buyBelow);   // ag'/al' below this = buy
  const kS = RULE.sellAbove/(100-RULE.sellAbove); // ag'/al' above this = sell
  // fall of d: ag'=ag(n-1)/n, al'=(al(n-1)+d)/n  -> ag(n-1)/(al(n-1)+d) < kB
  const dB = ag*(n-1)/kB - al*(n-1);
  // rise of u: ag'=(ag(n-1)+u)/n, al'=al(n-1)/n -> (ag(n-1)+u)/(al(n-1)) > kS
  const uS = kS*al*(n-1) - ag*(n-1);
  return {buyBelow: last - Math.max(dB,0), sellAbove: last + Math.max(uS,0)};
}
function backtest(dates, c, rate, startSar){
  const {rsi} = rsiSeries(c, RULE.period);
  const trades=[]; let pos=null; let cash=startSar, sh=0;
  const eq=[]; let peak=startSar, maxDD=0, daysIn=0;
  for(let i=0;i<c.length;i++){
    const r=rsi[i];
    if(pos){
      daysIn++;
      const stop = pos.entry*(1-RULE.stopPct/100);
      let why=null;
      if(c[i] <= stop) why="Stop";
      else if(r!==null && r>RULE.sellAbove) why="Sell";
      if(why){
        const ret=(c[i]/pos.entry-1)*100;
        if(sh>0){ cash += sh*c[i]*rate; }
        trades.push({in:pos.date, out:dates[i], entry:pos.entry, exit:c[i], ret, why, days:i-pos.i, sh});
        pos=null; sh=0;
      }
    } else if(r!==null && r<RULE.buyBelow){
      pos={entry:c[i], date:dates[i], i};
      sh=cash/(c[i]*rate);  // part shares: all cash goes in
      cash = 0;
    }
    const v = cash + sh*c[i]*rate; eq.push(v);
    if(v>peak) peak=v; maxDD=Math.max(maxDD,(peak-v)/peak*100);
  }
  const closed=trades.length, wins=trades.filter(t=>t.ret>0).length;
  const avg = closed? trades.reduce((a,t)=>a+t.ret,0)/closed : 0;
  const comp = trades.reduce((a,t)=>a*(1+t.ret/100),1);
  const hold = (c[c.length-1]/c[0]-1)*100;
  // buy-and-hold with part shares on startSar
  const holdSar = startSar*c[c.length-1]/c[0];
  return {trades, open:pos, closed, wins, winRate: closed? wins/closed*100:0, avg,
    best: closed? Math.max(...trades.map(t=>t.ret)):0, worst: closed? Math.min(...trades.map(t=>t.ret)):0,
    stops: trades.filter(t=>t.why==="Stop").length,
    ruleRet:(comp-1)*100, holdRet:hold, endSar:eq[eq.length-1], holdSar, maxDD, timeIn: daysIn/c.length*100, eq, rsi};
}
function analytics(c){
  const n=c.length, last=c[n-1];
  const ret=(k)=> n>k ? (last/c[n-1-k]-1)*100 : null;
  const sma=(k)=> n>=k ? c.slice(n-k).reduce((a,b)=>a+b,0)/k : null;
  const yr=c.slice(Math.max(0,n-252)); let pk=yr[0], dd=0;
  for(const v of yr){ if(v>pk) pk=v; dd=Math.max(dd,(pk-v)/pk*100); }
  const rets=[]; for(let i=Math.max(1,n-252);i<n;i++) rets.push(c[i]/c[i-1]-1);
  const m=rets.reduce((a,b)=>a+b,0)/rets.length;
  const sd=Math.sqrt(rets.reduce((a,b)=>a+(b-m)**2,0)/(rets.length-1||1));
  return {r1m:ret(21), r3m:ret(63), r1y:ret(252), sma200:sma(200), sma50:sma(50), maxDrop1y:dd, vol:sd*Math.sqrt(252)*100};
}
if(typeof module!=="undefined") module.exports={rsiSeries,triggerPrices,backtest,analytics,RULE};
