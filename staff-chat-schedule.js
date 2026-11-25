/* Staff-only deferred delivery. Drafts are cleared only after server acknowledgement. */
window.OMSStaffSchedule={
 bind(options){
  const {send,listButton,call,draft,accepted,members}=options,e=GuestSupport.esc;
  let timer,start,suppress=false,busy=false,dialog;
  function stop(){clearTimeout(timer);start=null;}
  function open(){if(send.disabled)return;suppress=true;edit();}
  send.addEventListener('pointerdown',ev=>{if(ev.button!==0)return;suppress=false;start={x:ev.clientX,y:ev.clientY};timer=setTimeout(open,550);});
  send.addEventListener('pointermove',ev=>{if(start&&Math.hypot(ev.clientX-start.x,ev.clientY-start.y)>10)stop();});
  ['pointerup','pointercancel','pointerleave'].forEach(event=>send.addEventListener(event,stop));
  send.addEventListener('click',ev=>{if(suppress){ev.preventDefault();ev.stopImmediatePropagation();suppress=false;}},true);
  send.addEventListener('contextmenu',ev=>{ev.preventDefault();stop();if(!dialog?.open)open();});
  send.title='길게 눌러 예약 발송';
  function sheet(title){dialog?.remove();dialog=document.createElement('dialog');dialog.className='staff-schedule-sheet';dialog.innerHTML=`<header><h2>${e(title)}</h2><button type="button" aria-label="닫기">×</button></header><div class="schedule-content"></div><p class="schedule-error" role="status"></p>`;document.body.append(dialog);dialog.querySelector('header button').onclick=()=>{if(!busy)dialog.close();};dialog.addEventListener('cancel',ev=>{if(busy)ev.preventDefault();});dialog.showModal();return dialog.querySelector('.schedule-content');}
  function error(err){dialog.querySelector('.schedule-error').textContent=err.message||String(err);}
  function localValue(date){return new Date(date.getTime()-date.getTimezoneOffset()*60000).toISOString().slice(0,16);}
  async function edit(item){
   const snapshot=item||draft();if(!snapshot?.body)return;
   const client_id=crypto.randomUUID(),box=sheet(item?'예약 메시지 수정':'예약 메시지');let people;try{people=(await call('schedule_list')).recipients||[];}catch(err){error(err);return;}
   box.innerHTML=`<textarea aria-label="예약 메시지 내용" maxlength="2000">${e(snapshot.body)}</textarea>${snapshot.photo||item?.attachment_mime?'<small>첨부 파일 포함</small>':''}<div class="schedule-modes"><label><input type="radio" name="schedule-mode" value="time" checked> ◷ 날짜·시간 예약</label><label><input type="radio" name="schedule-mode" value="checkin" ${people.length?'':'disabled'}> 근무자 출근 시</label></div><div data-time><input type="datetime-local" aria-label="발송 날짜와 시간" value="${localValue(item?.send_at?new Date(item.send_at):new Date(Math.ceil((Date.now()+1800000)/60000)*60000))}"><small>기기 시간 기준 · ${e(Intl.DateTimeFormat().resolvedOptions().timeZone)}</small></div><div data-checkin hidden><select aria-label="출근 기준 근무자">${people.map(p=>`<option value="${e(p.id)}">${e(p.name)}</option>`).join('')}</select><small>선택한 근무자의 다음 출근보고가 완료되면 이 채팅방으로 전달합니다.</small></div>${people.length?'':'<small>출근 시 전달은 수신자에 근무자가 있는 대화에서 사용할 수 있습니다.</small>'}<button type="button" class="schedule-save">${item?'예약 변경':'예약하기'}</button>`;
   const radios=box.querySelectorAll('[name=schedule-mode]'),date=box.querySelector('[type=datetime-local]');date.min=localValue(new Date(Date.now()+60000));
   function toggle(){const check=box.querySelector('[name=schedule-mode]:checked').value==='checkin';box.querySelector('[data-time]').hidden=check;box.querySelector('[data-checkin]').hidden=!check;}
   radios.forEach(r=>r.onchange=toggle);
   if(item?.mode==='checkin'&&people.some(p=>p.id===item.trigger_employee_id)){radios[1].checked=true;box.querySelector('select').value=item.trigger_employee_id;toggle();}
   box.querySelector('.schedule-save').onclick=async()=>{
    if(busy)return;const mode=box.querySelector('[name=schedule-mode]:checked').value,body=box.querySelector('textarea').value.trim(),when=new Date(date.value);
    if(!body){error('메시지 내용을 입력해주세요.');return;}
    if(mode==='time'&&(!Number.isFinite(when.getTime())||when<=new Date())){error('현재 이후 시간을 선택해주세요.');return;}
    busy=true;box.querySelectorAll('button,input,select,textarea').forEach(x=>x.disabled=true);
    try{await call(item?'schedule_update':'schedule_create',{...(!item&&snapshot.photo?{photo:snapshot.photo}:{}),client_id,body,priority:snapshot.priority||'normal',mode,send_at:mode==='time'?when.toISOString():null,trigger_employee_id:mode==='checkin'?box.querySelector('select').value:null,...(item?{id:item.id,revision:item.revision}:{})});if(!item)accepted(snapshot);dialog.close();await refresh();}
    catch(err){error(err);}finally{busy=false;box.querySelectorAll('button,input,select,textarea').forEach(x=>x.disabled=false);if(!people.length)radios[1].disabled=true;}
   };
  }
  async function refresh(){try{const v=await call('schedule_list');listButton.textContent='◷ 예약'+(v.items.length?' '+v.items.length:'');return v.items;}catch{ return []; }}
  async function list(){if(busy)return;const box=sheet('예약 메시지');box.textContent='불러오는 중…';try{const {items}=await call('schedule_list');box.innerHTML='';if(!items.length)box.textContent='예약된 메시지가 없습니다.';for(const item of items){const row=document.createElement('article');row.innerHTML=`<strong>${e(item.mode==='checkin'?(item.trigger_name+' · 다음 출근보고 완료 시'):new Date(item.send_at).toLocaleString('ko-KR'))}</strong><p>${e(item.body)}</p>${item.attachment_mime?'<small>첨부 파일 포함</small>':''}${item.error?`<p class="schedule-error">발송 실패 · ${e(item.error)}</p>`:''}<div><button type="button" data-edit>수정</button><button type="button" data-cancel>예약 취소</button></div>`;row.querySelector('[data-edit]').onclick=()=>edit(item);row.querySelector('[data-cancel]').onclick=async()=>{if(busy||!confirm('이 메시지의 예약을 취소할까요?'))return;busy=true;try{await call('schedule_cancel',{id:item.id,revision:item.revision});busy=false;await list();await refresh();}catch(err){error(err);}finally{busy=false;}};box.append(row);}}catch(err){box.textContent='';error(err);}}
  listButton.onclick=list;return {refresh,open:edit};
 }
};
