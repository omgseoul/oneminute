/* Retry only the exact failed delivery/attempt represented by a server notice. */
window.OMSAutoMessageRetry={
 async request(session,propertyId,data){
  const r=await fetch(OMG_SUPABASE.url+'/functions/v1/beds24',{method:'POST',headers:{apikey:OMG_SUPABASE.publishableKey,'Content-Type':'application/json'},body:JSON.stringify({action:'auto_message_retry',access_token:session.accessToken,data:{...data,property_id:propertyId}}),signal:AbortSignal.timeout(25000)});
  const v=await r.json();if(!r.ok||!v.ok)throw Error(v.message||'재전송을 접수하지 못했습니다. 발송 기록을 확인해주세요.');return v;
 },
 async followup(session,meta,action){
  const r=await fetch(OMG_SUPABASE.url+'/functions/v1/beds24',{method:'POST',headers:{apikey:OMG_SUPABASE.publishableKey,'Content-Type':'application/json'},body:JSON.stringify({action:'auto_message_followup',access_token:session.accessToken,data:{delivery_id:meta.delivery_id,retry_count:meta.retry_count,action}}),signal:AbortSignal.timeout(25000)});
  const v=await r.json();if(!r.ok||!v.ok)throw Error(v.message||'처리 결과를 저장하지 못했습니다.');return v;
 },
 mountFollowup(host,item,session,onChanged){
  if(!host||!session?.accessToken||!item?.auto_message?.followup)return false;
  const meta=item.auto_message,wrap=document.createElement('div');wrap.className='auto-followup-actions';
  const state=document.createElement('small');state.setAttribute('role','status');
  const menu=document.createElement('details'),summary=document.createElement('summary');summary.textContent='처리 선택';menu.append(summary);
  const choices=document.createElement('div');choices.className='auto-followup-choices';menu.append(choices);
  const labels={external:'다른 방법으로 전송하였음',planned:'전송 예정임',ignored:'무시해도 되는 건임',sent:'발송 완료'};
  const paint=()=>{const open=['open','planned'].includes(meta.followup);state.textContent=open?(meta.followup==='planned'?'전송 예정 · 1시간마다 알림':'미해결 · 1시간마다 알림'):labels[meta.followup]||'처리 완료';menu.hidden=!open;};
  for(const [action,label] of Object.entries(labels).filter(([action])=>action!=='sent')){
   const button=document.createElement('button');button.type='button';button.textContent=label;
   button.onclick=async()=>{for(const b of choices.children)b.disabled=true;state.textContent='저장 중…';try{const v=await this.followup(session,meta,action);meta.followup=v.status;meta.can_retry=false;menu.open=false;paint();await onChanged?.();}catch(err){state.textContent=err.message;}finally{for(const b of choices.children)b.disabled=false;}};choices.append(button);
  }
  wrap.append(state,menu);host.append(wrap);paint();return true;
 },
 mount(host,item,session,onQueued){
  if(this.mountFollowup(host,item,session,onQueued))return;
  if(!host||session?.sessionKind!=='owner'||!item?.auto_message)return;
  const meta=item.auto_message,wrap=document.createElement('div');wrap.className='auto-retry-actions';
  const link=document.createElement('a');link.textContent='발송 기록';link.className='bot-chat-action';link.href='guest-auto-messages.html?property='+encodeURIComponent(item.property_id)+'&logs=1';
  const button=document.createElement('button');button.type='button';button.className='bot-chat-action';button.textContent='이 게스트에게 재전송';button.disabled=!meta.can_retry;
  const state=document.createElement('small');state.setAttribute('role','status');
  if(!meta.can_retry)state.textContent=({sent:'발송 완료',waiting:'재전송 접수됨',preparing:'예약정보 확인 중',sending:'발송 중',uncertain:'발송 여부 확인 필요'})[meta.status]||'최신 발송 기록을 확인해주세요.';
  button.onclick=async()=>{if(button.disabled)return;button.disabled=true;state.textContent='재전송 접수 중…';try{
   const v=await this.request(session,item.property_id,{notice_id:item.message_id});meta.can_retry=false;
   state.textContent=v.retry_queued?'이 게스트의 재전송을 접수했습니다.':v.retry_results?.[0]?.message||'최신 발송 기록을 확인해주세요.';
   if(v.retry_queued)meta.status='waiting';await onQueued?.();
  }catch(err){state.textContent=err.message;button.disabled=false;}};
  wrap.append(link,button,state);host.append(wrap);
 }
};
