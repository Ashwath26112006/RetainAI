/* Tiny dependency-free SVG chart helpers (bar, grouped bars, line, donut) */
const PAL=['#6366f1','#14b8a6','#f59e0b','#8b5cf6','#ef4444','#10b981','#64748b'];
const fmt={int:v=>Number(v).toLocaleString('en-US',{maximumFractionDigits:0}),
           pct:v=>Number(v).toFixed(1)+'%',usd:v=>'$'+Number(v).toLocaleString('en-US',{maximumFractionDigits:0})};
function css(n){return getComputedStyle(document.documentElement).getPropertyValue(n).trim()||'#888'}
function el(id){return typeof id==='string'?document.getElementById(id):id}
function svgWrap(w,h,inner){return `<svg viewBox="0 0 ${w} ${h}" role="img" font-family="inherit">${inner}</svg>`}
function niceMax(v){const p=Math.pow(10,Math.floor(Math.log10(v||1)));const m=v/p;return (m<=1?1:m<=2?2:m<=5?5:10)*p}

/* vertical bars: labels[], values[] (optionally series: [{name,values}]) */
function barChart(id,labels,series,opt={}){
  const f=opt.format||fmt.int, W=Math.max(260,Math.round(el(id).clientWidth)||640),H=opt.height||260,L=48,R=10,T=14,B=48;
  if(!Array.isArray(series[0])&&typeof series[0]==='number')series=[{name:'',values:series}];
  const max=niceMax(opt.max||Math.max(...series.flatMap(s=>s.values),1));
  const gw=(W-L-R)/labels.length, bw=Math.min(46,(gw*.7)/series.length);
  let g='';
  for(let i=0;i<=4;i++){const y=T+(H-T-B)*(1-i/4);g+=`<line x1="${L}" x2="${W-R}" y1="${y}" y2="${y}" stroke="${css('--line')}"/><text x="${L-6}" y="${y+4}" text-anchor="end" font-size="11" fill="${css('--muted')}">${f(max*i/4)}</text>`}
  labels.forEach((lb,i)=>{
    const x0=L+gw*i+(gw-bw*series.length)/2;
    series.forEach((s,j)=>{const v=s.values[i]||0,h=(H-T-B)*v/max,x=x0+j*bw,y=H-B-h;
      const c=(opt.colors&&opt.colors[opt.perBar?i:j])||PAL[opt.perBar?i%PAL.length:j%PAL.length];
      g+=`<rect class="bar-r" x="${x}" y="${y}" width="${bw-3}" height="${Math.max(h,0)}" rx="7" fill="${c}" fill-opacity=".92"><title>${lb}${s.name?' - '+s.name:''}: ${f(v)}</title></rect>`;
      if(series.length===1)g+=`<text x="${x+(bw-3)/2}" y="${y-5}" text-anchor="middle" font-size="11" font-weight="600" fill="${css('--ink')}">${f(v)}</text>`});
    const mx=Math.max(4,Math.floor(gw/6.6)),short=String(lb).length>mx?String(lb).slice(0,mx-1)+'…':lb;
    g+=`<text x="${L+gw*i+gw/2}" y="${H-B+18}" text-anchor="middle" font-size="11.5" fill="${css('--muted')}">${short}</text>`});
  el(id).innerHTML=svgWrap(W,H,g)+(series.length>1?`<div class="legend">${series.map((s,j)=>`<span><i style="background:${PAL[j%PAL.length]}"></i>${s.name}</span>`).join('')}</div>`:'');
}

/* line chart: labels[], series [{name,values}] */
function lineChart(id,labels,series,opt={}){
  const f=opt.format||fmt.usd,W=Math.max(260,Math.round(el(id).clientWidth)||640),H=opt.height||250,L=58,R=14,T=14,B=36;
  const max=niceMax(Math.max(...series.flatMap(s=>s.values),1)), n=labels.length, dx=(W-L-R)/Math.max(n-1,1);
  let g='';
  for(let i=0;i<=4;i++){const y=T+(H-T-B)*(1-i/4);g+=`<line x1="${L}" x2="${W-R}" y1="${y}" y2="${y}" stroke="${css('--line')}"/><text x="${L-6}" y="${y+4}" text-anchor="end" font-size="11" fill="${css('--muted')}">${f(max*i/4)}</text>`}
  labels.forEach((lb,i)=>{g+=`<text x="${L+dx*i}" y="${H-B+18}" text-anchor="middle" font-size="11.5" fill="${css('--muted')}">${lb}</text>`});
  series.forEach((s,j)=>{const pts=s.values.map((v,i)=>[L+dx*i,T+(H-T-B)*(1-v/max)]);
    const c=PAL[j%PAL.length];
    g+=`<polygon fill="${c}" fill-opacity=".10" points="${pts[0][0]},${H-B} ${pts.map(p=>p.join(',')).join(' ')} ${pts[pts.length-1][0]},${H-B}"/>`;
    g+=`<polyline fill="none" stroke="${c}" stroke-width="3" stroke-linejoin="round" points="${pts.map(p=>p.join(',')).join(' ')}"/>`;
    pts.forEach((p,i)=>g+=`<circle cx="${p[0]}" cy="${p[1]}" r="4.2" fill="${c}" stroke="${css('--panel')}" stroke-width="2"><title>${labels[i]} - ${s.name}: ${f(s.values[i])}</title></circle>`)});
  el(id).innerHTML=svgWrap(W,H,g)+`<div class="legend">${series.map((s,j)=>`<span><i style="background:${PAL[j%PAL.length]}"></i>${s.name}</span>`).join('')}</div>`;
}

/* donut: labels[], values[] */
function donut(id,labels,values,opt={}){
  const W=300,H=220,cx=105,cy=110,r=78,sw=30,tot=values.reduce((a,b)=>a+b,0)||1,col=opt.colors||PAL;
  let a0=-Math.PI/2,g='';
  values.forEach((v,i)=>{const a1=a0+2*Math.PI*v/tot,large=a1-a0>Math.PI?1:0;
    const p=(a)=>[cx+r*Math.cos(a),cy+r*Math.sin(a)];const s=p(a0),e=p(a1-0.0001);
    g+=`<path d="M${s[0]} ${s[1]} A${r} ${r} 0 ${large} 1 ${e[0]} ${e[1]}" fill="none" stroke="${col[i%col.length]}" stroke-width="${sw}" stroke-linecap="butt"><title>${labels[i]}: ${fmt.int(v)} (${(100*v/tot).toFixed(1)}%)</title></path>`;a0=a1});
  g+=`<text x="${cx}" y="${cy-2}" text-anchor="middle" font-size="22" font-weight="700" fill="${css('--ink')}">${fmt.int(tot)}</text><text x="${cx}" y="${cy+16}" text-anchor="middle" font-size="11" fill="${css('--muted')}">${opt.center||'total'}</text>`;
  labels.forEach((lb,i)=>{g+=`<rect x="205" y="${60+i*24}" width="10" height="10" rx="3" fill="${col[i%col.length]}"/><text x="221" y="${69+i*24}" font-size="11.5" fill="${css('--ink')}">${lb} (${fmt.int(values[i])})</text>`});
  el(id).innerHTML=svgWrap(W+60,H,g);
}
async function api(path){const r=await fetch(path);return r.json()}
