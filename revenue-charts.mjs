const escape=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const colors=['#a8ccfa','#609eea','#246cc6'];
const monthLabel=m=>m.replace('-','.');
const currencyLabel=c=>c==='UNKNOWN'?'통화 미확인':c;
export const revenueAmountText=value=>`<span style="--amount-chars:${Math.max(1,Array.from(String(value)).length)}">${escape(value)}</span>`;
const fitText=revenueAmountText;
// Observe each amount as well as the page: WebView font inflation can change glyph
// widths after first layout without changing the width of the results section.
export function fitRevenueAmounts(root){
 let frame=0,stopped=false;const watched=new Map();
 const metrics=node=>{const r=node.getBoundingClientRect();return {width:r.width,height:r.height};};
 const record=node=>watched.set(node,metrics(node));
 const fit=()=>{
  frame=0;if(stopped)return;const amounts=[...root.querySelectorAll('[data-fit-amount]')],nodes=new Set([root]);
  for(const el of amounts){
   const text=el.firstElementChild;if(!text)continue;nodes.add(el);nodes.add(text);
   el.style.removeProperty('font-size');text.style.removeProperty('font-size');
   const style=getComputedStyle(el),available=el.clientWidth-parseFloat(style.paddingLeft)-parseFloat(style.paddingRight)-2;
   if(available<=0)continue;
   let size=parseFloat(getComputedStyle(text).fontSize);
   for(let attempt=0;attempt<4;attempt++){
    const width=text.getBoundingClientRect().width;if(width<=available)break;
    size=Math.max(.1,Math.floor(size*available/width*10)/10);
    text.style.setProperty('font-size',size+'px','important');
   }
   el.style.setProperty('font-size',size+'px');
  }
  for(const node of watched.keys())if(!nodes.has(node)){observer?.unobserve(node);watched.delete(node);}
  for(const node of nodes){if(!watched.has(node))observer?.observe(node);record(node);}
 };
 const schedule=()=>{if(!stopped&&!frame)frame=requestAnimationFrame(fit);};
 const observer=typeof ResizeObserver==='function'?new ResizeObserver(entries=>{
  // Ignore our own measured changes, preventing resize/fit feedback loops.
  if(entries.some(({target})=>{const before=watched.get(target),now=metrics(target);return !before||Math.abs(before.width-now.width)>.25||(target.matches('[data-fit-amount]>span')&&Math.abs(before.height-now.height)>.25);}))schedule();
 }):null;
 const mutations=new MutationObserver(schedule);mutations.observe(root,{childList:true,subtree:true,characterData:true});
 record(root);observer?.observe(root);window.addEventListener('resize',schedule);window.addEventListener('pageshow',schedule);window.visualViewport?.addEventListener('resize',schedule);document.fonts?.ready.then(schedule);document.fonts?.addEventListener('loadingdone',schedule);
 return {schedule,destroy(){stopped=true;observer?.disconnect();mutations.disconnect();window.removeEventListener('resize',schedule);window.removeEventListener('pageshow',schedule);window.visualViewport?.removeEventListener('resize',schedule);document.fonts?.removeEventListener('loadingdone',schedule);cancelAnimationFrame(frame);}};
}
export function createPropertyRevenueChart(host,{name,money,compact,covered,onDrilldown,onLayout,isBusy=()=>false}){
 let state=null,currency=null,page=0,selection=null,entries=[],view='month',focusedProperty=null;
 const propertyColors=new Map(),palette=['#3078c9','#78a8de','#afcbed','#786dc2','#48a7a0','#bd8653'];
 const colorFor=key=>{if(!propertyColors.has(key))propertyColors.set(key,palette[propertyColors.size%palette.length]);return propertyColors.get(key);};
 function update(next){const changed=!state||state.from!==next.from||state.to!==next.to||state.months.join()!==next.months.join();state=next;if(changed)page=next.startPage||0;page=Math.max(0,Math.min(page,Math.ceil(Math.max(1,next.months.length)/3)-1));selection=null;if(!next.reports.some(r=>r.currency===currency))currency=next.reports[0]?.currency||null;render();}
 function details(){const target=host.querySelector('.revenue-bar-detail');if(!target)return;const entry=entries[selection];target.hidden=!entry;if(!entry)return;
  target.innerHTML=`<div><b title="${escape(entry.name)}">${escape(entry.name)}${entry.month?' · '+monthLabel(entry.month):''}</b><small>${entry.from.replaceAll('-','.')} – ${entry.to.replaceAll('-','.')}${entry.complete?'':' · 일부 자료'}</small></div><strong data-fit-amount>${fitText(entry.empty?'미확인':money(entry.amount,currency))}</strong>${entry.month?'<button type="button" data-property-drill>월 상세 ›</button>':''}`;
  onLayout?.();
 }
 function render(){
  if(!state)return;const r=state.reports.find(r=>r.currency===currency);entries=[];
  if(!r){host.innerHTML='<h2>지점별 매출</h2><p class="note">해당 예약이 없습니다.</p>';renderEmpty();return;}
  const known=currency!=='UNKNOWN',grouped=state.months.length>1,visible=grouped?state.months.slice(page*3,page*3+3):[null];
  const order=state.propertyOrder||[];
  const groups=[...r.properties].sort(state.monthly?(a,b)=>order.indexOf(a.key)-order.indexOf(b.key):(a,b)=>b.amount-a.amount),pages=Math.ceil(state.months.length/3);
  const tabButtons=state.reports.map(report=>`<button type="button" role="tab" id="revenue-tab-${escape(report.currency)}" aria-controls="revenue-property-panel" aria-selected="${report.currency===currency}" tabindex="${report.currency===currency?0:-1}" data-property-currency="${escape(report.currency)}">${escape(currencyLabel(report.currency))}</button>`).join('');
  if(state.monthly){renderMonthly(groups,tabButtons);return;}
  host.innerHTML=`<div class="revenue-property-tools"><h2>지점별 매출</h2><div class="revenue-currency-tabs" role="tablist" aria-label="지점별 매출 통화">${tabButtons}</div><small>${currency==='KRW'?'단위: 만원':known?'단위: '+escape(currency):'금액 합산 제외'}</small></div><div id="revenue-property-panel" role="tabpanel" aria-labelledby="revenue-tab-${escape(currency)}"></div>`;
  const panel=host.querySelector('[role=tabpanel]');
  if(!known){panel.innerHTML='<p class="note">통화를 확인할 수 없는 예약은 금액 합계와 그래프에서 제외합니다.</p>'+groups.map(g=>`<div class="revenue-unknown-property"><span>${escape(name(g.key))}</span><b>${g.bookings}건</b></div>`).join('');renderEmpty();onLayout?.();return;}
  const windowBounds=m=>{if(!m)return {from:state.from,to:state.to};const [y,n]=m.split('-').map(Number),end=new Date(Date.UTC(y,n,0)).toISOString().slice(0,10);return {from:m+'-01'<state.from?state.from:m+'-01',to:end>state.to?state.to:end};};
  const columnGroups=groups.map(g=>({name:name(g.key),columns:visible.map((m,i)=>{const range=windowBounds(m),amount=m?g.periods[m+'-01']||0:g.amount,complete=covered(range.from,range.to,g.key);const entry={property:g.key,name:name(g.key),month:m,amount,...range,complete,empty:amount===0&&!complete,index:entries.length,color:grouped?colors[i]:colors[2]};entries.push(entry);return entry;})}));
  const scale=currency==='KRW'?10000:1,max=Math.max(0,...entries.map(e=>e.amount/scale));
  const rawStep=(max||1)/4,power=10**Math.floor(Math.log10(rawStep)),step=([1,2,2.5,5,10].find(n=>n>=rawStep/power)||10)*power,ceiling=step*4;
  const tick=n=>new Intl.NumberFormat('en',{notation:n>=10000?'compact':'standard',maximumFractionDigits:currency==='USD'?0:2}).format(n);
  const rangeHeader=grouped?`<div class="revenue-property-range"><span>${monthLabel(visible[0])} – ${monthLabel(visible.at(-1))}</span>${pages>1?`<div class="revenue-month-pages"><button type="button" data-property-page="-1" aria-label="이전 3개월" ${page===0?'disabled':''}>‹</button><small>${page+1}/${pages}</small><button type="button" data-property-page="1" aria-label="다음 3개월" ${page===pages-1?'disabled':''}>›</button></div>`:'<small>월별 비교</small>'}</div>`:'';
  panel.innerHTML=rangeHeader+`<div class="revenue-column-chart ${grouped?'is-grouped':''}" data-chart-currency="${escape(currency)}"><div class="revenue-y-axis" aria-hidden="true">${[0,1,2,3,4].map(i=>`<span style="bottom:${i*25}%">${tick(step*i)}</span>`).join('')}</div><div class="revenue-plot-scroll" tabindex="0" aria-label="지점별 그래프, 지점이 많으면 좌우로 스크롤"><div class="revenue-plot-inner" style="--property-count:${groups.length}"><div class="revenue-plot-grid" aria-hidden="true">${[0,1,2,3,4].map(i=>`<i style="bottom:${i*25}%"></i>`).join('')}</div><div class="revenue-plot-groups">${columnGroups.map(g=>`<div class="revenue-property-group"><div class="revenue-property-columns">${g.columns.map(e=>{
   const height=e.amount/scale/ceiling*100,label=e.empty?'—':compact(e.amount,currency)+(e.complete?'':'*');
   return `<button type="button" class="revenue-property-bar ${e.complete?'':'is-incomplete'} ${e.empty?'is-empty':''}" data-property-bar="${e.index}" data-amount="${e.amount}" data-property="${escape(e.property)}" ${e.month?`data-chart-month="${e.month}"`:''} aria-pressed="${selection===e.index}" aria-label="${escape(e.name+(e.month?' '+monthLabel(e.month):'')+' '+(e.empty?'미확인':money(e.amount,currency))+(e.complete?'':' · 일부 자료'))}" style="--bar-height:${height}%;--bar-color:${e.color}">${grouped?'':`<b data-fit-amount>${fitText(label)}</b>`}<i aria-hidden="true"></i>${e.empty?'<span class="revenue-missing-marker" aria-hidden="true">—</span>':''}</button>`;
  }).join('')}</div><div class="revenue-property-name" title="${escape(g.name)}">${escape(g.name)}</div></div>`).join('')}</div></div></div></div>`+(grouped?`<div class="revenue-month-legend">${visible.map((m,i)=>`<span><i style="background:${colors[i]}"></i>${monthLabel(m)}</span>`).join('')}</div>`:'')+`<p class="revenue-chart-hint">막대를 누르면 정확한 금액${grouped?'과 월 상세':''}을 확인합니다.</p><div class="revenue-bar-detail" aria-live="polite" hidden></div><div class="revenue-property-total"><span>${escape(currency)} ${grouped?'조회기간 합계':'합계'}</span><strong data-fit-amount>${fitText(money(r.total,currency))}</strong></div>`;
  renderEmpty();details();onLayout?.();
 }

 function renderMonthly(groups,tabButtons){
  const known=currency!=='UNKNOWN',months=state.months;
  if(!groups.some(g=>g.key===focusedProperty))focusedProperty=groups[0]?.key;
  groups.forEach(g=>colorFor(g.key));
  const shown=view==='property'?groups.filter(g=>g.key===focusedProperty):groups;
  const columns=months.map(month=>({month,entries:shown.map(g=>{
   const [y,m]=month.split('-').map(Number),end=new Date(Date.UTC(y,m,0)).toISOString().slice(0,10);
   const from=month+'-01'<state.from?state.from:month+'-01',to=end>state.to?state.to:end;
   const amount=g.periods[month+'-01']||0,complete=covered(from,to,g.key);
   const entry={property:g.key,name:name(g.key),month,amount,from,to,complete,empty:amount===0&&!complete,index:entries.length,color:colorFor(g.key)};
   entries.push(entry);return entry;
  })}));
  const maxAmount=Math.max(0,...entries.map(e=>e.amount));
  // Keep labels short; exact amounts are always available by selecting a bar.
  let scale=currency==='KRW'?(view==='month'?1000000:10000):1,unit=currency==='KRW'?(view==='month'?'백만원':'만원'):currency;
  if(currency!=='KRW'&&maxAmount>=10000){for(const [factor,label] of [[1000,'천'],[10000,'만'],[1000000,'백만'],[100000000,'억'],[1000000000000,'조']]){scale=factor;unit=label+' '+currency;if(maxAmount/factor<10000)break;}}
  const max=maxAmount/scale,rawStep=(max||1)/4,power=10**Math.floor(Math.log10(rawStep));
  let step=([1,2,2.5,5,10].find(n=>n>=rawStep/power)||10)*power;if(currency==='USD')step=Math.max(1,Math.ceil(step));
  const ceiling=step*4,digits=currency==='USD'||view==='property'||max>=100?0:1;
  const number=n=>new Intl.NumberFormat('ko-KR',{useGrouping:false,maximumFractionDigits:digits}).format(n);
  const tick=n=>new Intl.NumberFormat('ko-KR',{useGrouping:false,maximumFractionDigits:currency==='USD'?0:2}).format(n);
  const switcher=`<div class="revenue-view-switch" role="group" aria-label="월간 매출 보기"><button type="button" data-revenue-view="month" aria-pressed="${view==='month'}">월별</button><button type="button" data-revenue-view="property" aria-pressed="${view==='property'}">지점별</button></div>`;
  host.innerHTML=`<div class="revenue-property-tools">${switcher}<div class="revenue-currency-tabs" role="tablist" aria-label="지점별 매출 통화">${tabButtons}</div></div><div id="revenue-property-panel" role="tabpanel" aria-labelledby="revenue-tab-${escape(currency)}"></div>`;
  const panel=host.querySelector('[role=tabpanel]');
  if(!known){panel.innerHTML='<p class="note">통화를 확인할 수 없는 예약은 금액 합계와 그래프에서 제외합니다.</p>'+groups.map(g=>`<div class="revenue-unknown-property"><span>${escape(name(g.key))}</span><b>${g.bookings}건</b></div>`).join('');renderEmpty();onLayout?.();return;}
  const visibleMonths=Math.min(months.length,view==='month'?3:6);
  const propertyTabs=view==='property'&&groups.length>1?`<div class="revenue-focus-tabs" role="group" aria-label="월별 매출 지점 선택">${groups.map(g=>`<button type="button" data-revenue-focus="${escape(g.key)}" aria-pressed="${g.key===focusedProperty}" title="${escape(name(g.key))}">${escape(name(g.key))}</button>`).join('')}</div>`:'';
  const monthText=m=>months[0].slice(0,4)===months.at(-1).slice(0,4)?Number(m.slice(5))+'월':m.slice(2).replace('-','.');
  const chart=columns.map(col=>`<div class="revenue-property-group"><div class="revenue-property-columns">${col.entries.map(e=>`<button type="button" class="revenue-property-bar ${e.complete?'':'is-incomplete'} ${e.empty?'is-empty':''}" data-property-bar="${e.index}" data-amount="${e.amount}" data-property="${escape(e.property)}" data-chart-month="${e.month}" aria-pressed="false" aria-label="${escape(e.name+' '+monthLabel(e.month)+' '+(e.empty?'미확인':money(e.amount,currency))+(e.complete?'':' · 일부 자료'))}" style="--bar-height:${e.amount/scale/ceiling*100}%;--bar-color:${e.color}"><b data-fit-amount>${fitText(e.empty?'—':number(e.amount/scale))}</b><i aria-hidden="true"></i></button>`).join('')}</div><div class="revenue-property-name">${escape(monthText(col.month))}</div></div>`).join('');
  panel.innerHTML=`<div class="revenue-monthly-meta"><span>${monthLabel(months[0])}${months.length>1?' – '+monthLabel(months.at(-1)):''}</span><small>단위: ${escape(unit)} · 반올림</small></div>${propertyTabs}${view==='property'&&groups.length===1?`<div class="revenue-focused-name">${escape(name(focusedProperty))}</div>`:''}<div class="revenue-column-chart is-monthly ${view==='property'?'is-property-focus':''}" data-chart-currency="${escape(currency)}" data-monthly-view="${view}"><div class="revenue-y-axis" aria-hidden="true">${[0,1,2,3,4].map(i=>`<span style="bottom:${i*25}%">${tick(step*i)}</span>`).join('')}</div><div class="revenue-plot-scroll" tabindex="0" aria-label="월별 매출, 좌우로 스크롤" style="--month-count:${months.length};--visible-months:${visibleMonths};--series-count:${shown.length}"><div class="revenue-plot-inner"><div class="revenue-plot-grid" aria-hidden="true">${[0,1,2,3,4].map(i=>`<i style="bottom:${i*25}%"></i>`).join('')}</div><div class="revenue-plot-groups">${chart}</div></div></div></div>${view==='month'?`<div class="revenue-property-legend">${groups.map(g=>`<span title="${escape(name(g.key))}"><i style="background:${colorFor(g.key)}"></i><span>${escape(name(g.key))}</span></span>`).join('')}</div>`:''}<div class="revenue-bar-detail" aria-live="polite" hidden></div><p class="revenue-monthly-hint">${months.length>visibleMonths?'좌우로 이동 · ':''}막대를 누르면 금액·월 상세를 확인합니다.</p>`;
  renderEmpty();onLayout?.();
 }
 function renderEmpty(){for(const p of state.emptyProperties||[])host.insertAdjacentHTML('beforeend',`<p class="revenue-empty-property">${escape(name(p))}<span>선택 조건의 예약 없음${covered(state.from,state.to,p)?'':' · 불러오기 필요'}</span></p>`);}
 host.addEventListener('click',event=>{
  if(isBusy())return;const viewButton=event.target.closest('[data-revenue-view]'),focusButton=event.target.closest('[data-revenue-focus]');
  if(viewButton){view=viewButton.dataset.revenueView;selection=null;render();host.querySelector('[data-revenue-view="'+view+'"]')?.focus({preventScroll:true});return;}
  if(focusButton){focusedProperty=focusButton.dataset.revenueFocus;selection=null;render();[...host.querySelectorAll('[data-revenue-focus]')].find(b=>b.dataset.revenueFocus===focusedProperty)?.focus({preventScroll:true});return;}
  const tab=event.target.closest('[data-property-currency]'),pager=event.target.closest('[data-property-page]'),bar=event.target.closest('[data-property-bar]'),drill=event.target.closest('[data-property-drill]');
  if(tab){currency=tab.dataset.propertyCurrency;selection=null;render();host.querySelector('[aria-selected=true]')?.focus({preventScroll:true});}
  else if(pager){page+=Number(pager.dataset.propertyPage);selection=null;render();host.querySelector('[data-property-page="'+pager.dataset.propertyPage+'"]:not(:disabled)')?.focus({preventScroll:true});}
  else if(bar){selection=Number(bar.dataset.propertyBar);host.querySelectorAll('[data-property-bar]').forEach(b=>b.setAttribute('aria-pressed',String(Number(b.dataset.propertyBar)===selection)));details();}
  else if(drill){const e=entries[selection];if(e?.month)onDrilldown(e.property,e.month);}
 });
 host.addEventListener('keydown',event=>{const tabs=[...host.querySelectorAll('[role=tab]')],current=tabs.indexOf(event.target);if(current<0||!['ArrowLeft','ArrowRight','Home','End'].includes(event.key)||isBusy())return;event.preventDefault();const next=event.key==='Home'?0:event.key==='End'?tabs.length-1:(current+(event.key==='ArrowRight'?1:tabs.length-1))%tabs.length;tabs[next].click();});
 return {update};
}
