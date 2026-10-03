(function(){
  const $=id=>document.getElementById(id);
  const dayNames=['일','월','화','수','목','금','토'];
  let session,isOwner=false,timezone='Asia/Seoul',view='month',focusDate,events=[],tasks=[],employees=[];
  const pad=value=>String(value).padStart(2,'0');
  const key=date=>`${date.getFullYear()}-${pad(date.getMonth()+1)}-${pad(date.getDate())}`;
  const parseKey=value=>{const [y,m,d]=value.split('-').map(Number);return new Date(y,m-1,d);};
  const addDays=(date,count)=>new Date(date.getFullYear(),date.getMonth(),date.getDate()+count);
  const monday=date=>addDays(date,-(date.getDay()+6)%7);
  const sameDay=(a,b)=>key(a)===key(b);
  const escape=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  function zonedParts(value){
    const parts=new Intl.DateTimeFormat('en-US',{timeZone:timezone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(new Date(value));
    return Object.fromEntries(parts.filter(part=>part.type!=='literal').map(part=>[part.type,Number(part.value)]));
  }
  function zonedKey(value){const p=zonedParts(value);return `${p.year}-${pad(p.month)}-${pad(p.day)}`;}
  function zonedISO(date,time){
    const [y,m,d]=date.split('-').map(Number),[h,min]=time.split(':').map(Number);
    let utc=Date.UTC(y,m-1,d,h,min);
    for(let i=0;i<2;i++){const p=zonedParts(utc),wall=Date.UTC(p.year,p.month-1,p.day,p.hour,p.minute);utc-=wall-Date.UTC(y,m-1,d,h,min);}
    return new Date(utc).toISOString();
  }
  function today(){const p=zonedParts(Date.now());return new Date(p.year,p.month-1,p.day);}
  function dayStart(date){return zonedISO(key(date),'00:00');}
  function range(){
    if(view==='day')return [focusDate,addDays(focusDate,1)];
    if(view==='week')return [focusDate,addDays(focusDate,7)];
    const first=monday(new Date(focusDate.getFullYear(),focusDate.getMonth(),1));
    const last=new Date(focusDate.getFullYear(),focusDate.getMonth()+1,0);
    return [first,addDays(monday(last),7)];
  }
  function itemsFor(date){
    const start=new Date(dayStart(date)).getTime(),end=new Date(dayStart(addDays(date,1))).getTime();
    return [
      ...events.filter(item=>new Date(item.start_at).getTime()<end&&new Date(item.end_at).getTime()>start).map(item=>({...item,kind:'event',sort:new Date(item.start_at).getTime()})),
      ...tasks.filter(item=>new Date(item.due_at).getTime()>=start&&new Date(item.due_at).getTime()<end).map(item=>({...item,kind:'task',sort:new Date(item.due_at).getTime()}))
    ].sort((a,b)=>a.sort-b.sort);
  }
  function itemMarkup(item,full=false){
    const task=item.kind==='task',p=zonedParts(task?item.due_at:item.start_at);
    const time=task?'To do':item.all_day?'종일':`${pad(p.hour)}:${pad(p.minute)}`;
    return `<button type="button" class="calendar-item ${task?'task':''}" data-kind="${item.kind}" data-id="${escape(item.id)}" title="${escape(item.title)}">${full?`${escape(time)} · `:''}${escape(item.title)}${full?`<small>${task?'To do 목록에서 확인':item.target_names?.length?escape(item.target_names.join(', ')):item.owner_target?'내 일정':'내 일정'}</small>`:''}</button>`;
  }
  function renderHeader(){
    const first=view==='week'?focusDate:monday(focusDate),last=addDays(first,6);
    $('rangeTitle').textContent=view==='month'?`${focusDate.getFullYear()}년 ${focusDate.getMonth()+1}월`:view==='week'?`${first.getMonth()+1}월 ${first.getDate()}일~${last.getMonth()+1}월 ${last.getDate()}일`:`${focusDate.getMonth()+1}월 ${focusDate.getDate()}일 ${dayNames[focusDate.getDay()]}요일`;
    document.querySelector('.calendar-toolbar').classList.toggle('week-mode',view==='week');
    $('rangeSub').textContent=view==='month'?'캘린더':view==='week'?'이번 주 일정':'하루 일정';
    $('viewButton').innerHTML=(view==='month'?'▦':view==='week'?'▤':'▥')+' <span>⌄</span>';
    document.querySelectorAll('[data-view]').forEach(button=>button.classList.toggle('active',button.dataset.view===view));
  }
  function renderMonth(){
    const [first,end]=range(),now=today(),cells=[];
    for(let date=first;date<end;date=addDays(date,1)){
      const items=itemsFor(date),outside=date.getMonth()!==focusDate.getMonth();
      cells.push(`<div class="calendar-day${outside?' other':''}${sameDay(date,now)?' today':''}" data-date="${key(date)}"><button class="calendar-day-number" type="button" aria-label="${key(date)} 일정 추가">${date.getDate()}</button>${items.slice(0,2).map(item=>itemMarkup(item)).join('')}${items.length>2?`<span class="calendar-more">+${items.length-2}건</span>`:''}</div>`);
    }
    $('calendarBoard').innerHTML=`<div class="calendar-weekdays">${['월','화','수','목','금','토','일'].map(day=>`<span>${day}</span>`).join('')}</div><div class="calendar-month">${cells.join('')}</div>`;
  }
  function renderWeek(){
    const first=focusDate,now=today(),cards=[];
    for(let i=0;i<7;i++){
      const date=addDays(first,i),items=itemsFor(date),isToday=sameDay(date,now);
      const heading=`<h2>${isToday?'<span class="calendar-today-label">Today</span>':''}<span>${date.getMonth()+1}월 ${date.getDate()}일 ${dayNames[date.getDay()]}요일</span></h2>`;
      cards.push(`<div class="calendar-week-card${isToday?' today':''}" data-date="${key(date)}">${heading}${items.length?items.map(item=>itemMarkup(item)).join(''):'<span class="calendar-empty">일정 없음 · 눌러서 추가</span>'}</div>`);
    }
    $('calendarBoard').innerHTML=`<div class="calendar-week-grid">${cards.join('')}</div>`;
  }
  function renderDay(){
    const items=itemsFor(focusDate);
    $('calendarBoard').innerHTML=`<div class="calendar-day-view" data-date="${key(focusDate)}">${items.length?items.map(item=>itemMarkup(item,true)).join(''):'<div class="calendar-empty">일정이 없습니다. 날짜를 눌러 추가하세요.</div>'}<button class="calendar-item" type="button" data-create-date="${key(focusDate)}">+ 일정 추가</button></div>`;
  }
  function render(){renderHeader();if(view==='month')renderMonth();else if(view==='week')renderWeek();else renderDay();}
  async function rpc(action,event){
    const {data,error}=await window.omgSupabase.rpc('calendar_event_action',{p_access_token:session.accessToken,p_action:action,p_event:event});
    if(error||!data?.ok)throw new Error(data?.message||error?.message||'캘린더를 불러오지 못했습니다.');
    return data;
  }
  async function refresh(){
    const [start,end]=range();$('calendarMessage').textContent='';
    try{const result=await rpc('list',{range_start:dayStart(start),range_end:dayStart(end)});
      events=result.events||[];tasks=result.tasks||[];employees=result.employees||[];renderTargets();render();
    }catch(error){$('calendarMessage').textContent=error.message;render();}
  }
  function renderTargets(){
    if(!isOwner)return;
    const host=$('targetOptions');
    host.innerHTML=`<label><input type="checkbox" value="owner" checked>본인</label>`+employees.map(e=>`<label><input type="checkbox" value="${escape(e.id)}">${escape(e.name)}</label>`).join('');
  }
  function openEditor(date,event=null){
    $('eventForm').reset();$('eventFormMessage').textContent='';$('eventId').value=event?.id||'';
    $('dialogTitle').textContent=event?'일정 수정':'일정 추가';
    $('eventDate').value=event?zonedKey(event.start_at):date;
    $('eventTitle').value=event?.title||'';$('eventDetails').value=event?.details||'';
    $('allDay').checked=!!event?.all_day;
    if(event){const start=zonedParts(event.start_at),end=zonedParts(event.end_at);$('startTime').value=`${pad(start.hour)}:${pad(start.minute)}`;$('endTime').value=`${pad(end.hour)}:${pad(end.minute)}`;}
    else{$('startTime').value='09:00';$('endTime').value='10:00';}
    $('timeFields').hidden=$('allDay').checked;
    $('startTime').required=$('endTime').required=!$('allDay').checked;
    if(isOwner){document.querySelectorAll('#targetOptions input').forEach(input=>input.checked=input.value==='owner'?event?!!event.owner_target:true:!!event?.target_employee_ids?.includes(input.value));}
    const readonly=!!event&&!event.can_edit;
    $('dialogTitle').textContent=readonly?'일정 보기':event?'일정 수정':'일정 추가';
    $('eventForm').querySelectorAll('input:not([type=hidden]),textarea').forEach(input=>input.disabled=readonly);
    $('saveEvent').hidden=readonly;$('deleteEvent').hidden=!event||readonly;
    $('eventDialog').showModal();
  }
  function closeEditor(){if($('eventDialog').open)$('eventDialog').close();}
  $('viewButton').onclick=()=>{const menu=$('viewMenu');menu.hidden=!menu.hidden;$('viewButton').setAttribute('aria-expanded',String(!menu.hidden));};
  $('viewMenu').onclick=event=>{const button=event.target.closest('[data-view]');if(!button)return;view=button.dataset.view;if(view==='week')focusDate=today();$('viewMenu').hidden=true;$('viewButton').setAttribute('aria-expanded','false');refresh();};
  $('todayButton').onclick=()=>{focusDate=today();refresh();};
  function move(direction){if(view==='month')focusDate=new Date(focusDate.getFullYear(),focusDate.getMonth()+direction,Math.min(focusDate.getDate(),28));else focusDate=addDays(focusDate,direction*(view==='week'?7:1));refresh();}
  $('prevButton').onclick=()=>move(-1);$('nextButton').onclick=()=>move(1);
  $('addEvent').onclick=()=>openEditor(key(focusDate));
  $('calendarBoard').onclick=event=>{
    const item=event.target.closest('[data-kind]');
    if(item){if(item.dataset.kind==='task'){location.href='mission.html';return;}const record=events.find(e=>e.id===item.dataset.id);if(record)openEditor(zonedKey(record.start_at),record);return;}
    const date=event.target.closest('[data-create-date]')?.dataset.createDate||event.target.closest('[data-date]')?.dataset.date;
    if(date){if(view==='day')focusDate=parseKey(date);openEditor(date);}
  };
  $('closeDialog').onclick=closeEditor;
  $('eventDialog').onclick=event=>{if(event.target===$('eventDialog'))closeEditor();};
  $('allDay').onchange=()=>{$('timeFields').hidden=$('allDay').checked;$('startTime').required=$('endTime').required=!$('allDay').checked;};
  $('eventForm').onsubmit=async event=>{
    event.preventDefault();const date=$('eventDate').value,allDay=$('allDay').checked;
    const start=allDay?dayStart(parseKey(date)):zonedISO(date,$('startTime').value);
    const end=allDay?dayStart(addDays(parseKey(date),1)):zonedISO(date,$('endTime').value);
    if(new Date(end)<=new Date(start)){$('eventFormMessage').textContent='종료 시간을 시작 시간보다 늦게 선택해주세요.';return;}
    const selected=isOwner?[...document.querySelectorAll('#targetOptions input:checked')].map(input=>input.value):[];
    if(isOwner&&!selected.length){$('eventFormMessage').textContent='일정 대상을 선택해주세요.';return;}
    const button=$('saveEvent');button.disabled=true;$('eventFormMessage').textContent='';
    try{await rpc('save',{id:$('eventId').value||null,title:$('eventTitle').value.trim(),details:$('eventDetails').value.trim(),start_at:start,end_at:end,all_day:allDay,owner_target:selected.includes('owner'),target_employee_ids:selected.filter(value=>value!=='owner')});closeEditor();if(view==='day')focusDate=parseKey(date);await refresh();}
    catch(error){$('eventFormMessage').textContent=error.message;}finally{button.disabled=false;}
  };
  $('deleteEvent').onclick=async()=>{if(!confirm('이 일정을 삭제할까요?'))return;const button=$('deleteEvent');button.disabled=true;try{await rpc('delete',{id:$('eventId').value});closeEditor();await refresh();}catch(error){$('eventFormMessage').textContent=error.message;}finally{button.disabled=false;}};
  document.addEventListener('visibilitychange',()=>{if(!document.hidden&&session)refresh();});
  (async()=>{session=await window.omgSession.require({allowCompleted:true});if(!session)return;
    isOwner=session.sessionKind==='owner';timezone=session.timezone||'Asia/Seoul';focusDate=today();
    $('propertyName').textContent=session.propertyName||'One Minute';$('targetFieldset').hidden=!isOwner;
    await refresh();window.omgTransition.ready();
  })().catch(error=>{$('calendarMessage').textContent=error.message;window.omgTransition.ready();});
})();
