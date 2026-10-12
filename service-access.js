(() => {
'use strict';const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const formatBytes=v=>Number(v)>=1073741824?(Number(v)/1073741824).toFixed(2)+'GB':(Number(v)/1048576).toFixed(1)+'MB';
async function get(token){const{data,error}=await omgSupabase.rpc('get_property_service',{p_access_token:token||null});if(error||!data?.ok)throw Error(data?.message||'이용 정보를 불러오지 못했습니다.');return data;}
async function render(token){try{const data=await get(token),s=data.service;let host=document.getElementById('serviceAccess');if(!host){host=document.createElement('aside');host.id='serviceAccess';document.querySelector('.oms-hero')?.after(host);if(!host.parentNode)document.querySelector('main')?.prepend(host);}if(!host)return;
 const notices=[];if(s.expired)notices.push(s.restricted?'이용 기간이 종료되어 새 업무 등록이 제한됩니다.':'이용 기간이 종료되었습니다. 구독 연장을 확인해주세요.');else if(s.remind)notices.push(`${s.status==='trial'?'무료 체험':'이용권'} 종료까지 ${Math.max(0,s.days_left)}일 남았습니다.`);if(s.storage_warn)notices.push(`저장 용량 ${formatBytes(s.used_bytes)} / ${formatBytes(s.limit_bytes)} 사용 중입니다.`);
 host.className='service-access'+(notices.length?' warn':'');host.hidden=!data.can_manage&&!notices.length;host.innerHTML=`<div><strong>${s.exempt?'내부 이용 · 과금 면제':s.status==='trial'?'무료 체험':'이용권 현황'}</strong>${notices.map(x=>`<p>${esc(x)}</p>`).join('')}</div>${data.can_manage?'<a href="subscription.html">이용권·용량 ›</a>':''}`;
 }catch(e){console.warn('Service status unavailable');}}
window.OMSService={get,render,formatBytes};
})();
