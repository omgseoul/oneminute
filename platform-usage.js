(() => {
 'use strict';
 const $=id=>document.getElementById(id),esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const number=v=>Number(v).toLocaleString('ko-KR',{maximumFractionDigits:3});
 const bytes=v=>{const n=Number(v);return n>=1073741824?number(n/1073741824)+' GB':n>=1048576?number(n/1048576)+' MB':n>=1024?number(n/1024)+' KB':number(n)+' B';};
 const amount=v=>v!==null&&v!==undefined&&v!==''&&Number.isFinite(Number(v))?Math.max(0,Number(v)):null;
 let dashboard=null,storageReady=false,translation=null,credits=null,busy=false,errors=[],updatedAt=null;
 const kinds=[['storage','저장공간'],['translation','번역량'],['credits','크레딧 사용량']];
 const format=(kind,n)=>kind==='storage'?bytes(n):number(n)+(kind==='translation'?'자':' 크레딧');
 function properties(){
  const rows=new Map();
  for(const p of dashboard?.properties||[])rows.set(p.property_id,{id:p.property_id,name:p.property_name,number:p.management_number,service:p.service});
  for(const p of [...(translation?.values()||[]),...(credits?.values()||[])])if(!rows.has(p.id))rows.set(p.id,{id:p.id,name:p.name,number:p.number});
  return [...rows.values()];
 }
 function metric(p,kind){
  const raw=kind==='storage'?(storageReady?p.service:null):kind==='translation'?translation?.get(p.id)?.usage:credits?.get(p.id)?.usage;
  if(!raw)return null;
  const used=amount(kind==='storage'?raw.used_bytes:raw.used),limit=amount(kind==='storage'?raw.limit_bytes:kind==='translation'?raw.limit:raw.monthly_limit);
  if(used===null||limit===null)return null;
  return {used,limit,remaining:kind==='storage'?Math.max(0,limit-used):amount(kind==='translation'?raw.remaining:raw.available),reserved:amount(raw.reserved)||0,personal:amount(raw.personal_used)||0,month:raw.month?String(raw.month).slice(0,7):null};
 }
 function meter(kind,m){
  if(!m)return '<p class="usage-unavailable">사용량을 확인할 수 없습니다.</p>';
  const percent=m.limit>0?Math.min(100,m.used/m.limit*100):m.used>0?100:0;
  return `<div class="usage-value"><strong>${format(kind,m.used)}</strong><span> / ${format(kind,m.limit)}</span></div><progress class="usage-meter ${percent>=80?'warn':''}" max="100" value="${percent}" aria-label="${kinds.find(x=>x[0]===kind)[1]} 사용 비율 ${Math.round(percent)}%"></progress><p class="usage-detail">${kind==='credits'?'사용 가능':'남은 제공량'} ${m.remaining===null?'확인 불가':format(kind,m.remaining)}${m.reserved?' · 처리 중 '+format(kind,m.reserved):''}</p>${kind==='translation'?`<p class="usage-detail">개인 API ${format(kind,m.personal)} · 총 번역 ${format(kind,m.used+m.personal)}</p>`:''}`;
 }
 function render(){
  const rows=properties();
  $('usageSummary').innerHTML=kinds.map(([kind,title])=>{
   const values=rows.map(p=>metric(p,kind)),ready=(kind==='storage'?storageReady:kind==='translation'?translation!==null:credits!==null)&&values.every(Boolean);
   const total=ready?values.reduce((s,m)=>s+m.used,0):null;
   return `<article class="usage-summary-card" data-usage-total="${kind}"><span>${title}</span><strong>${total===null?'—':format(kind,total)}</strong><small>${kind==='storage'?'현재 보관 중':kind==='translation'?'이번 달 기본 제공량 사용':'이번 달 사용'}${!ready?' · '+(busy?'불러오는 중':'확인 불가'):''}</small></article>`;
  }).join('');
  $('usageList').innerHTML=rows.map(p=>`<article class="ops-card usage-property" data-usage-property="${esc(p.id)}"><header><h3>${esc(p.name)}</h3>${p.number!=null?`<span>#${esc(p.number)}</span>`:''}</header><div class="usage-metrics">${kinds.map(([kind,title])=>{const m=metric(p,kind);return `<section class="usage-metric" data-usage-kind="${kind}"><h4>${title}${m?.month?`<small>${esc(m.month)}</small>`:''}</h4>${meter(kind,m)}</section>`;}).join('')}</div></article>`).join('')||`<p class="ops-empty">${busy?'사용량을 불러오는 중입니다.':errors.length?'사용량을 불러오지 못했습니다. 새로고침해주세요.':'등록된 지점이 없습니다.'}</p>`;
  $('usageStatus').textContent=busy?'사용량을 불러오는 중입니다.':errors.join(' · ');
  $('usageRefresh').disabled=busy;
  $('checkTime').textContent=updatedAt?'조회 '+updatedAt.toLocaleString('ko-KR',{timeZone:'Asia/Seoul'})+(storageReady&&dashboard?.last_checked_at?' · 저장공간 집계 '+new Date(dashboard.last_checked_at).toLocaleString('ko-KR',{timeZone:'Asia/Seoul'}):''):'';
 }
 async function translationStatus(token){
  const r=await fetch(OMG_SUPABASE.url+'/functions/v1/beds24',{method:'POST',headers:{'Content-Type':'application/json',apikey:OMG_SUPABASE.publishableKey},body:JSON.stringify({action:'translation_status',data:{},platform_token:token}),signal:AbortSignal.timeout(30000)}),v=await r.json();
  if(!r.ok||!v.ok)throw Error(v.message||'번역량 조회 실패');return v;
 }
 async function refresh(snapshot){
  if(busy)return;busy=true;errors=[];render();
  const auth=omgSupabase.auth.getSession().then(({data,error})=>{if(error||!data?.session?.access_token)throw Error('운영센터에 다시 로그인해주세요.');return data.session.access_token;});
  const storage=snapshot?Promise.resolve(snapshot):omgSupabase.rpc('platform_operations',{p_action:'usage',p_data:{}}).then(({data,error})=>{if(error||!data?.ok)throw Error(data?.message||error?.message||'저장공간 조회 실패');return data;});
  const results=await Promise.allSettled([storage,auth.then(translationStatus),auth.then(token=>GuestAI.call('list',{},{platform_token:token}))]);
  results.forEach((result,index)=>{
   const valid=result.status==='fulfilled'&&Array.isArray(result.value?.properties);
   if(index===0){storageReady=valid;if(valid)dashboard=result.value;}
   else if(index===1)translation=valid?new Map(result.value.properties.map(p=>[p.id,p])):null;
   else credits=valid?new Map(result.value.properties.map(p=>[p.id,p])):null;
   if(!valid)errors.push(kinds[index][1]+' 조회 실패: '+(result.reason?.message||'다시 시도해주세요.'));
  });
  updatedAt=new Date();busy=false;render();
 }
 window.PlatformUsage={setDashboard(value){dashboard=value;storageReady=true;render();if(!$('usage').hidden)void refresh(value);},refresh};
 $('usageRefresh').onclick=()=>void refresh();
 document.querySelector('[data-tab="usage"]').addEventListener('click',()=>void refresh());
})();
