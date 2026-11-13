(function(){
 let token='',queue=[],active=null,seen=new Set(),observed=null,confirming=false,pendingReads=new Set(),reading=new Set();
 const popup=()=>document.getElementById('messageArrival');
 function bind(accessToken){if(token===accessToken)return;token=accessToken;queue=[];active=null;observed=null;confirming=false;reading=new Set();if(popup())popup().hidden=true;try{seen=new Set(JSON.parse(sessionStorage.getItem('oms-popup-seen:'+token)||'[]'));}catch{seen=new Set();}try{pendingReads=new Set(JSON.parse(sessionStorage.getItem('oms-popup-pending:'+token)||'[]'));}catch{pendingReads=new Set();}}
 function render(){
  const root=popup();if(!root)return;
  if(!active)active=queue.shift();if(!active){root.hidden=true;return;}
  if(!root.querySelector('.message-arrival-confirm')){
   root.setAttribute('role','dialog');root.setAttribute('aria-modal','true');root.setAttribute('aria-label','새 알림');
   const card=root.querySelector('.message-arrival-card'),count=document.createElement('small'),button=document.createElement('button');
   count.className='message-arrival-count';count.setAttribute('aria-live','polite');card.append(count);
   button.type='button';button.className='message-arrival-confirm';button.textContent='확인';button.onclick=confirm;card.append(button);
  }
  const reminder=active.report?null:window.OMSReminderPopup?.parse(active.message,active.sender_label);
  root.classList.toggle('is-reminder',!!reminder);root.classList.toggle('is-overdue',!!reminder?.overdue);
  let banner=root.querySelector('.reminder-banner'),hint=root.querySelector('.reminder-hint'),date=root.querySelector('.reminder-date'),open=root.querySelector('.reminder-open');
  if(!banner){
   const card=root.querySelector('.message-arrival-card');
   banner=document.createElement('div');banner.className='reminder-banner';banner.innerHTML='<b></b><span></span>';card.prepend(banner);
   date=document.createElement('div');date.className='reminder-date';hint=document.createElement('div');hint.className='reminder-hint';document.getElementById('messageArrivalBody').after(date,hint);
   open=document.createElement('button');open.type='button';open.className='reminder-open';root.querySelector('.message-arrival-confirm').before(open);
  }
  banner.hidden=hint.hidden=date.hidden=open.hidden=!reminder;
  const conversation=!active.report&&active.sender_type!=='system'&&(!active.message_type||['general','guest_chat'].includes(active.message_type));
  document.getElementById('messageArrivalDog').src=reminder?(reminder.overdue?'oms-dog-overdue-plain.webp':'oms-dog-normal-plain.webp'):conversation?'shiba-worker-logo.png':'oms-dog-normal-plain.webp';
  if(reminder){banner.firstElementChild.textContent=reminder.heading;banner.lastElementChild.textContent=reminder.timing;hint.textContent=reminder.guidance;date.textContent=reminder.dateLine;date.hidden=!reminder.dateLine;open.textContent=reminder.button;open.onclick=()=>{const href=reminder.href;confirm();location.href=href;};}
  root.querySelector('strong').textContent=reminder?'OMS':active.report?'새 보고 도착':/^(To do 알림|일정 알림)$/.test(active.sender_label)?active.sender_label:'새 메세지 도착';
  document.getElementById('messageArrivalSender').textContent=reminder?'':active.report?active.sender_label:/^(To do 알림|일정 알림)$/.test(active.sender_label)?'업무 알림':(active.sender_label||'새 메세지');
  document.getElementById('messageArrivalBody').textContent=reminder?reminder.title:String(active.message||'메세지 메뉴에서 확인해주세요.').replace(/\\n/g,'\n').replace(/^(?:To do 알림|일정 알림)\s*\n/,'');
  root.querySelector('.message-arrival-count').textContent=`${queue.length+1}건 대기`;
  root.hidden=false;root.querySelector('button').focus({preventScroll:true});
 }
 function saveReads(){try{sessionStorage.setItem('oms-popup-pending:'+token,JSON.stringify([...pendingReads]));}catch{}}
 function flushReads(){
  const accessToken=token,pending=pendingReads,inFlight=reading;
  for(const id of pending){
   if(inFlight.has(id))continue;inFlight.add(id);
   Promise.resolve().then(()=>window.omgSupabase.rpc('mark_property_message_read',{p_access_token:accessToken,p_message_id:id})).then(({error,data})=>{
    if(!error&&data?.ok){pending.delete(id);if(token===accessToken){saveReads();window.dispatchEvent(new Event('omg:messages-changed'));}}
   }).catch(()=>{}).finally(()=>inFlight.delete(id));
  }
 }
 function confirm(){
  if(confirming||!active)return;confirming=true;
  const item=active;seen.add(item.message_id);try{sessionStorage.setItem('oms-popup-seen:'+token,JSON.stringify([...seen].slice(-1000)));}catch{}
  if(!item.report){pendingReads.add(item.message_id);saveReads();flushReads();}
  active=null;render();setTimeout(()=>confirming=false,200);
 }
 function add(items,accessToken){
  bind(accessToken);items=items.filter(i=>i.online_popup_allowed!==false);const ordinary=items.filter(i=>!i.report);
  if(typeof window.OMGNative?.showMessageAlerts==='function'&&ordinary.length){window.OMGNative.showMessageAlerts(JSON.stringify(ordinary));items=items.filter(i=>i.report);}
  for(const item of items)if(item.message_id&&!seen.has(item.message_id)&&active?.message_id!==item.message_id&&!queue.some(q=>q.message_id===item.message_id))queue.push(item);
  if(!active&&queue.length)render();else if(active)popup().querySelector('.message-arrival-count').textContent=`${queue.length+1}건 대기`;
 }
 function update(items,accessToken,announce){
  bind(accessToken);flushReads();
  const incoming=items.filter(i=>!i.is_sender&&!i.read_at&&!['announcement','attendance_warning','work_confirmation'].includes(i.message_type)&&
   (i.source==='reminder'||/^(To do 알림|일정 알림)$/.test(i.sender_label||'')||(announce&&observed&&!observed.has(i.message_id))))
   .sort((a,b)=>String(a.created_at||'').localeCompare(String(b.created_at||''))||String(a.message_id).localeCompare(String(b.message_id)));
  observed=new Set(items.map(i=>i.message_id));add(incoming,accessToken);
 }
 window.HomeMessageQueue={update,add};
})();
