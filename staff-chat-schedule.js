/* Staff-only anchored reservation controls. Opening a menu never sends a message. */
window.OMSStaffSchedule={
 icon(person=false,dot=false){return `<svg viewBox="0 0 26 26" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${person?'<circle cx="13" cy="7" r="4"/><path d="M4 24v-3a9 9 0 0 1 18 0v3Z"/>':'<rect x="3" y="5" width="19" height="18" rx="3"/><path d="M3 10h19M8 2v5M17 2v5"/>'}${dot?'<circle cx="22" cy="22" r="3.4" fill="#e65359" stroke="white" stroke-width="1.7"/>':''}</svg>`;},
 bind({send,listButton,call,draft,accepted}){
  const e=GuestSupport.esc,icon=this.icon;let timer,start,suppress=false,busy=false,dialog,anchor,refreshing=false,closed=false,poll;
  listButton.innerHTML=icon(false,true);listButton.hidden=true;
  function count(items=[]){listButton.hidden=!items.length;listButton.setAttribute('aria-label',`예약 메시지 ${items.length}개 보기`);listButton.closest('.staff-input-wrap')?.classList.toggle('has-schedules',items.length>0);}
  function stop(){clearTimeout(timer);start=null;}
  function open(){if(send.disabled||busy)return;suppress=true;menu();}
  send.addEventListener('pointerdown',ev=>{if(ev.button!==0)return;suppress=false;start={x:ev.clientX,y:ev.clientY};timer=setTimeout(open,550);});
  send.addEventListener('pointermove',ev=>{if(start&&Math.hypot(ev.clientX-start.x,ev.clientY-start.y)>10)stop();});
  ['pointerup','pointercancel','pointerleave'].forEach(event=>send.addEventListener(event,stop));
  send.addEventListener('click',ev=>{if(suppress){ev.preventDefault();ev.stopImmediatePropagation();suppress=false;}},true);
  send.addEventListener('contextmenu',ev=>{ev.preventDefault();stop();if(!dialog?.open)open();});send.title='길게 눌러 예약 발송';
  function position(){if(!dialog?.open||!anchor)return;const a=anchor.getBoundingClientRect(),v=window.visualViewport,top=v?.offsetTop||0,left=v?.offsetLeft||0,width=v?.width||innerWidth;dialog.style.maxWidth=(width-24)+'px';dialog.querySelector('.schedule-content').style.maxHeight=Math.max(80,a.top-top-(dialog.querySelector('header')?84:40))+'px';const box=dialog.getBoundingClientRect(),x=Math.max(left+12,Math.min(a.right-box.width,left+width-box.width-12));dialog.style.left=x+'px';dialog.style.top=Math.max(top+12,a.top-box.height-10)+'px';dialog.style.setProperty('--tip',Math.max(18,Math.min(box.width-18,a.left+a.width/2-x))+'px');}
  function panel(title,target,kind=''){
   dialog?.remove();anchor=target;dialog=document.createElement('dialog');dialog.className='staff-schedule-popup '+kind+(target?' anchored':' schedule-editor');
   dialog.innerHTML=(title?`<header><h2>${e(title)}</h2><button type="button" class="schedule-close" aria-label="닫기">×</button></header>`:'')+'<div class="schedule-content"></div><p class="schedule-error" role="status"></p>';document.body.append(dialog);
   const close=dialog.querySelector('.schedule-close');if(close)close.onclick=()=>{if(!busy)dialog.close();};dialog.addEventListener('cancel',ev=>{if(busy)ev.preventDefault();});dialog.addEventListener('click',ev=>{if(busy||ev.target!==dialog)return;const b=dialog.getBoundingClientRect();if(ev.clientX<b.left||ev.clientX>b.right||ev.clientY<b.top||ev.clientY>b.bottom)dialog.close();});dialog.showModal();position();return dialog.querySelector('.schedule-content');
  }
  function error(err){dialog.querySelector('.schedule-error').textContent=err.message||String(err);position();}
  function localValue(date){return new Date(date.getTime()-date.getTimezoneOffset()*60000).toISOString().slice(0,16);}
  function menu(){if(busy)return;const snapshot=draft();if(!snapshot?.body)return;const box=panel('',send,'schedule-menu');box.innerHTML=`<button type="button" data-mode="time">${icon()}<span>날짜·시간 예약</span></button><button type="button" data-mode="checkin">${icon(true)}<span>근무자 출근 시</span></button>`;box.querySelectorAll('[data-mode]').forEach(b=>b.onclick=()=>edit(null,snapshot,b.dataset.mode));position();}
  async function edit(item,snapshot=item,initialMode=item?.mode||'time'){
   if(busy||!snapshot?.body)return;const client_id=crypto.randomUUID(),box=panel(item?'예약 메시지 수정':initialMode==='checkin'?'근무자 출근 시':'날짜·시간 예약');let people;
   busy=true;try{const r=await call('schedule_list');people=r.recipients||[];count(r.items);}catch(err){error(err);return;}finally{busy=false;}
   if(!dialog.open)return;let mode=initialMode;
   box.innerHTML=`<textarea aria-label="예약 메시지 내용" maxlength="2000" rows="2">${e(snapshot.body)}</textarea>${snapshot.photo||item?.attachment_mime?'<small>첨부 파일 포함</small>':''}${item?'<div class="schedule-modes"><button type="button" data-mode="time">날짜·시간</button><button type="button" data-mode="checkin">출근 시</button></div>':''}<div data-time><input type="datetime-local" aria-label="발송 날짜와 시간" value="${localValue(item?.send_at?new Date(item.send_at):new Date(Math.ceil((Date.now()+1800000)/60000)*60000))}"><small>기기 시간 · ${e(Intl.DateTimeFormat().resolvedOptions().timeZone)}</small></div><div data-checkin><select aria-label="출근 기준 근무자">${people.map(p=>`<option value="${e(p.id)}">${e(p.name)}</option>`).join('')}</select><small>${people.length?'다음 출근보고 완료 후 이 대화에 전달합니다.':'출근 기준 근무자가 없습니다.'}</small></div><button type="button" class="schedule-save">${item?'예약 변경':'예약하기'}</button>${item?'<button type="button" class="schedule-cancel" data-cancel>예약 취소</button>':''}`;
   const date=box.querySelector('[type=datetime-local]');date.min=localValue(new Date(Date.now()+60000));
   const toggle=()=>{box.querySelector('[data-time]').hidden=mode!=='time';box.querySelector('[data-checkin]').hidden=mode!=='checkin';box.querySelectorAll('[data-mode]').forEach(b=>{b.setAttribute('aria-pressed',String(b.dataset.mode===mode));b.disabled=b.dataset.mode==='checkin'&&!people.length;});};
   box.querySelectorAll('[data-mode]').forEach(b=>b.onclick=()=>{mode=b.dataset.mode;toggle();});if(item?.trigger_employee_id)box.querySelector('select').value=item.trigger_employee_id;toggle();
   box.querySelector('.schedule-save').onclick=async()=>{
    if(busy)return;const body=box.querySelector('textarea').value.trim(),when=new Date(date.value),employee=box.querySelector('select').value;
    if(!body){error('메시지 내용을 입력해주세요.');return;}if(mode==='checkin'&&!employee){error('출근 기준 근무자를 선택해주세요.');return;}if(mode==='time'&&(!Number.isFinite(when.getTime())||when<=new Date())){error('현재 이후 시간을 선택해주세요.');return;}
    busy=true;box.querySelectorAll('button,input,select,textarea').forEach(x=>x.disabled=true);
    try{const r=await call(item?'schedule_update':'schedule_create',{...(!item&&snapshot.photo?{photo:snapshot.photo}:{}),client_id,body,priority:snapshot.priority||'normal',mode,send_at:mode==='time'?when.toISOString():null,trigger_employee_id:mode==='checkin'?employee:null,...(item?{id:item.id,revision:item.revision}:{})});if(!item)accepted(snapshot);count(r.items);dialog.close();}
    catch(err){error(err);}finally{busy=false;box.querySelectorAll('button,input,select,textarea').forEach(x=>x.disabled=false);toggle();refresh();}
   };
   const cancel=box.querySelector('[data-cancel]');if(cancel)cancel.onclick=async()=>{if(busy||!confirm('이 메시지의 예약을 취소할까요?'))return;busy=true;try{const r=await call('schedule_cancel',{id:item.id,revision:item.revision});count(r.items);dialog.close();}catch(err){error(err);}finally{busy=false;refresh();}};
  }
  async function refresh(){if(refreshing||busy||closed||document.hidden)return;refreshing=true;try{const r=await call('schedule_list');count(r.items);return r.items;}catch{}finally{refreshing=false;clearTimeout(poll);if(!closed)poll=setTimeout(refresh,30000);}}
  async function list(){if(busy)return;const box=panel('예약 메시지',listButton,'schedule-list');box.textContent='불러오는 중…';busy=true;try{const r=await call('schedule_list'),items=r.items||[];count(items);dialog.querySelector('h2').innerHTML=`예약 메시지 <b>${items.length}</b>`;box.innerHTML=items.map((item,i)=>`<button type="button" class="schedule-item" data-edit="${i}">${icon(item.mode==='checkin')}<span><strong>${e(item.mode==='checkin'?'다음 출근 시 · '+(item.trigger_name||'근무자'):new Date(item.send_at).toLocaleString('ko-KR',{month:'long',day:'numeric',hour:'numeric',minute:'2-digit'}))}</strong><small>${e(item.body)}</small>${item.error?`<small class="schedule-error">발송 실패 · ${e(item.error)}</small>`:''}</span><i>›</i></button>`).join('')||'<small>예약된 메시지가 없습니다.</small>';box.querySelectorAll('[data-edit]').forEach(b=>b.onclick=()=>edit(items[Number(b.dataset.edit)]));position();}catch(err){box.textContent='';error(err);}finally{busy=false;}}
  listButton.onclick=list;addEventListener('resize',position);window.visualViewport?.addEventListener('resize',position);document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh();});addEventListener('pagehide',()=>{closed=true;clearTimeout(poll);stop();dialog?.close();});addEventListener('pageshow',()=>{closed=false;refresh();});return{refresh,open:menu};
 }
};
