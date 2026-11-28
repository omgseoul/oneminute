const escape=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const colors=['#a8ccfa','#609eea','#246cc6'];
const monthLabel=m=>m.replace('-','.');
const currencyLabel=c=>c==='UNKNOWN'?'통화 미확인':c;
const fitText=value=>`<span>${escape(value)}</span>`;
// Measure the actual glyphs after layout, so currency signs, decimals and device fonts all fit.
export function fitRevenueAmounts(root){
 let frame=0,lastWidth=-1;
 const fit=()=>{frame=0;root.querySelectorAll('[data-fit-amount]').forEach(el=>{
  el.style.removeProperty('font-size');const text=el.firstElementChild,available=el.clientWidth;
  if(!text||!available)return;const size=parseFloat(getComputedStyle(el).fontSize),width=text.getBoundingClientRect().width;
  if(width>available){el.style.fontSize=(Math.floor(size*(available-1)/width*10)/10)+'px';}
 });};
 const schedule=()=>{if(!frame)frame=requestAnimationFrame(fit);};
 const observer=typeof ResizeObserver==='function'?new ResizeObserver(entries=>{const width=entries[0].contentRect.width;if(width!==lastWidth){lastWidth=width;schedule();}}):null;
 observer?.observe(root);window.addEventListener('resize',schedule);document.fonts?.ready.then(schedule);
 return {schedule,destroy(){observer?.disconnect();window.removeEventListener('resize',schedule);cancelAnimationFrame(frame);}};
}
export function createPropertyRevenueChart(host,{name,money,compact,covered,onDrilldown,onLayout,isBusy=()=>false}){
 let state=null,currency=null,page=0,selection=null,entries=[];
 function update(next){const changed=!state||state.from!==next.from||state.to!==next.to||state.months.join()!==next.months.join();state=next;if(changed)page=next.startPage||0;page=Math.max(0,Math.min(page,Math.ceil(Math.max(1,next.months.length)/3)-1));selection=null;if(!next.reports.some(r=>r.currency===currency))currency=next.reports[0]?.currency||null;render();}
 function details(){const target=host.querySelector('.revenue-bar-detail');if(!target)return;const entry=entries[selection];target.hidden=!entry;if(!entry)return;
  target.innerHTML=`<div><b title="${escape(entry.name)}">${escape(entry.name)}${entry.month?' · '+monthLabel(entry.month):''}</b><small>${entry.from.replaceAll('-','.')} – ${entry.to.replaceAll('-','.')}${entry.complete?'':' · 일부 자료'}</small></div><strong data-fit-amount>${fitText(entry.empty?'미확인':money(entry.amount,currency))}</strong>${entry.month?'<button type="button" data-property-drill>월 상세 ›</button>':''}`;
  onLayout?.();
 }
 function render(){
  if(!state)return;const r=state.reports.find(r=>r.currency===currency);entries=[];
  if(!r){host.innerHTML='<p class="note">해당 예약이 없습니다.</p>';renderEmpty();return;}
  const known=currency!=='UNKNOWN',grouped=state.months.length>1,visible=grouped?state.months.slice(page*3,page*3+3):[null];
  const groups=[...r.properties].sort((a,b)=>b.amount-a.amount),pages=Math.ceil(state.months.length/3);
  const tabButtons=state.reports.map(report=>`<button type="button" role="tab" id="revenue-tab-${escape(report.currency)}" aria-controls="revenue-property-panel" aria-selected="${report.currency===currency}" tabindex="${report.currency===currency?0:-1}" data-property-currency="${escape(report.currency)}">${escape(currencyLabel(report.currency))}</button>`).join('');
  host.innerHTML=`<div class="revenue-property-tools"><div class="revenue-currency-tabs" role="tablist" aria-label="지점별 매출 통화">${tabButtons}</div><small>${currency==='KRW'?'단위: 만원':known?'단위: '+escape(currency):'금액 합산 제외'}</small></div><div id="revenue-property-panel" role="tabpanel" aria-labelledby="revenue-tab-${escape(currency)}"></div>`;
  const panel=host.querySelector('[role=tabpanel]');
  if(!known){panel.innerHTML='<p class="note">통화를 확인할 수 없는 예약은 금액 합계와 그래프에서 제외합니다.</p>'+groups.map(g=>`<div class="revenue-unknown-property"><span>${escape(name(g.key))}</span><b>${g.bookings}건</b></div>`).join('');renderEmpty();onLayout?.();return;}
  const windowBounds=m=>{if(!m)return {from:state.from,to:state.to};const [y,n]=m.split('-').map(Number),end=new Date(Date.UTC(y,n,0)).toISOString().slice(0,10);return {from:m+'-01'<state.from?state.from:m+'-01',to:end>state.to?state.to:end};};
  const columnGroups=groups.map(g=>({name:name(g.key),columns:visible.map((m,i)=>{const range=windowBounds(m),amount=m?g.periods[m+'-01']||0:g.amount,complete=covered(range.from,range.to,g.key);const entry={property:g.key,name:name(g.key),month:m,amount,...range,complete,empty:amount===0&&!complete,index:entries.length,color:grouped?colors[i]:colors[2]};entries.push(entry);return entry;})}));
  const scale=currency==='KRW'?10000:1,max=Math.max(0,...entries.map(e=>e.amount/scale));
  const rawStep=(max||1)/4,power=10**Math.floor(Math.log10(rawStep)),step=([1,2,2.5,5,10].find(n=>n>=rawStep/power)||10)*power,ceiling=step*4;
  const tick=n=>new Intl.NumberFormat('en',{notation:n>=10000?'compact':'standard',maximumFractionDigits:2}).format(n);
  const rangeHeader=grouped?`<div class="revenue-property-range"><span>${monthLabel(visible[0])} – ${monthLabel(visible.at(-1))}</span>${pages>1?`<div class="revenue-month-pages"><button type="button" data-property-page="-1" aria-label="이전 3개월" ${page===0?'disabled':''}>‹</button><small>${page+1}/${pages}</small><button type="button" data-property-page="1" aria-label="다음 3개월" ${page===pages-1?'disabled':''}>›</button></div>`:'<small>월별 비교</small>'}</div>`:'';
  panel.innerHTML=rangeHeader+`<div class="revenue-column-chart ${grouped?'is-grouped':''}" data-chart-currency="${escape(currency)}"><div class="revenue-y-axis" aria-hidden="true">${[0,1,2,3,4].map(i=>`<span style="bottom:${i*25}%">${tick(step*i)}</span>`).join('')}</div><div class="revenue-plot-scroll" tabindex="0" aria-label="지점별 그래프, 지점이 많으면 좌우로 스크롤"><div class="revenue-plot-inner" style="--property-count:${groups.length}"><div class="revenue-plot-grid" aria-hidden="true">${[0,1,2,3,4].map(i=>`<i style="bottom:${i*25}%"></i>`).join('')}</div><div class="revenue-plot-groups">${columnGroups.map(g=>`<div class="revenue-property-group"><div class="revenue-property-columns">${g.columns.map(e=>{
   const height=e.amount/scale/ceiling*100,label=e.empty?'—':compact(e.amount,currency)+(e.complete?'':'*');
   return `<button type="button" class="revenue-property-bar ${e.complete?'':'is-incomplete'} ${e.empty?'is-empty':''}" data-property-bar="${e.index}" data-amount="${e.amount}" data-property="${escape(e.property)}" ${e.month?`data-chart-month="${e.month}"`:''} aria-pressed="${selection===e.index}" aria-label="${escape(e.name+(e.month?' '+monthLabel(e.month):'')+' '+(e.empty?'미확인':money(e.amount,currency))+(e.complete?'':' · 일부 자료'))}" style="--bar-height:${height}%;--bar-color:${e.color}">${grouped?'':`<b data-fit-amount>${fitText(label)}</b>`}<i aria-hidden="true"></i>${e.empty?'<span class="revenue-missing-marker" aria-hidden="true">—</span>':''}</button>`;
  }).join('')}</div><div class="revenue-property-name" title="${escape(g.name)}">${escape(g.name)}</div></div>`).join('')}</div></div></div></div>`+(grouped?`<div class="revenue-month-legend">${visible.map((m,i)=>`<span><i style="background:${colors[i]}"></i>${monthLabel(m)}</span>`).join('')}</div>`:'')+`<p class="revenue-chart-hint">막대를 누르면 정확한 금액${grouped?'과 월 상세':''}을 확인합니다.</p><div class="revenue-bar-detail" aria-live="polite" hidden></div><div class="revenue-property-total"><span>${escape(currency)} ${grouped?'조회기간 합계':'합계'}</span><strong data-fit-amount>${fitText(money(r.total,currency))}</strong></div>`;
  renderEmpty();details();onLayout?.();
 }
 function renderEmpty(){for(const p of state.emptyProperties||[])host.insertAdjacentHTML('beforeend',`<p class="revenue-empty-property">${escape(name(p))}<span>선택 조건의 예약 없음${covered(state.from,state.to,p)?'':' · 불러오기 필요'}</span></p>`);}
 host.addEventListener('click',event=>{
  if(isBusy())return;const tab=event.target.closest('[data-property-currency]'),pager=event.target.closest('[data-property-page]'),bar=event.target.closest('[data-property-bar]'),drill=event.target.closest('[data-property-drill]');
  if(tab){currency=tab.dataset.propertyCurrency;selection=null;render();host.querySelector('[aria-selected=true]')?.focus({preventScroll:true});}
  else if(pager){page+=Number(pager.dataset.propertyPage);selection=null;render();host.querySelector('[data-property-page="'+pager.dataset.propertyPage+'"]:not(:disabled)')?.focus({preventScroll:true});}
  else if(bar){selection=Number(bar.dataset.propertyBar);host.querySelectorAll('[data-property-bar]').forEach(b=>b.setAttribute('aria-pressed',String(Number(b.dataset.propertyBar)===selection)));details();}
  else if(drill){const e=entries[selection];if(e?.month)onDrilldown(e.property,e.month);}
 });
 host.addEventListener('keydown',event=>{const tabs=[...host.querySelectorAll('[role=tab]')],current=tabs.indexOf(event.target);if(current<0||!['ArrowLeft','ArrowRight','Home','End'].includes(event.key)||isBusy())return;event.preventDefault();const next=event.key==='Home'?0:event.key==='End'?tabs.length-1:(current+(event.key==='ArrowRight'?1:tabs.length-1))%tabs.length;tabs[next].click();});
 return {update};
}
