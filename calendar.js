(function(){
  const $=id=>document.getElementById(id);
  const companion=new URLSearchParams(location.search).get('app')==='calendar';
  let companionDate,refreshSequence=0,weekScrollTop=8*32;
  let visibleKinds={event:true,task:true};
  const dayNames=['일','월','화','수','목','금','토'];
  let session,isOwner=false,timezone='Asia/Seoul',view='month',focusDate,events=[],tasks=[],employees=[],selectedPropertyIds=[],ownPropertyId=null;
  const viewKey=()=>`oms.calendar.view.v1:${session.sessionKind||'staff'}:${session.ownerId||session.employeeId||session.propertyId||'local'}`;
  function restoreView(){try{const saved=localStorage.getItem(viewKey());if(['month','week','day'].includes(saved))view=saved;}catch(_){/* Storage can be disabled; month remains usable. */}}
  function saveView(){try{localStorage.setItem(viewKey(),view);}catch(_){/* A storage failure must not block switching views. */}}
  const pad=value=>String(value).padStart(2,'0');
  const key=date=>`${date.getFullYear()}-${pad(date.getMonth()+1)}-${pad(date.getDate())}`;
  const parseKey=value=>{const [y,m,d]=value.split('-').map(Number);return new Date(y,m-1,d);};
  const addDays=(date,count)=>new Date(date.getFullYear(),date.getMonth(),date.getDate()+count);
  const sunday=date=>addDays(date,-date.getDay());
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
    if(view==='week'){const start=companion?sunday(focusDate):focusDate;return [start,addDays(start,7)];}
    const first=sunday(new Date(focusDate.getFullYear(),focusDate.getMonth(),1));
    const last=new Date(focusDate.getFullYear(),focusDate.getMonth()+1,0);
    return [first,addDays(sunday(last),7)];
  }
  function itemsFor(date){
    const start=new Date(dayStart(date)).getTime(),end=new Date(dayStart(addDays(date,1))).getTime();
    const now=Date.now(), current=today(), isToday=sameDay(date,current);
    const lastDueDate=key(addDays(current,7));
    const dueTasks=tasks.flatMap(item=>{
      if(!item.due_at)return item.timing==='today'&&isToday?[{...item,kind:'task',sort:now,late:false}]:[];
      const due=new Date(item.due_at).getTime();
      if((companion&&due<now&&isToday)||OMSMissionTasks.section(item,{timezone})==='overdue')return isToday?[{...item,kind:'task',sort:due,late:true}]:[];
      const deadline=zonedKey(due);
      return deadline<=lastDueDate&&key(date)>=key(current)&&key(date)<=deadline
        ?[{...item,kind:'task',sort:due,late:false}]:[];
    });
    return [
      ...events.filter(item=>new Date(item.start_at).getTime()<end&&new Date(item.end_at).getTime()>start).map(item=>({...item,kind:'event',sort:new Date(item.start_at).getTime()})),
      ...dueTasks
    ].sort((a,b)=>Number(!!b.late)-Number(!!a.late)||a.sort-b.sort);
  }
  function boardItems(date){return itemsFor(date).filter(item=>!companion||visibleKinds[item.kind]);}
  function todoUrl(item=null,create=false){
    const params=new URLSearchParams({app:'calendar-todo'});
    if(isOwner&&$('companionScope').value==='mine')params.set('scope','mine');
    if(item)params.set('task',item.id);
    if(create){params.set('create','1');params.set('date',key(companionDate||focusDate));}
    return 'mission.html?'+params;
  }
  function companionItemMarkup(item){
    const task=item.kind==='task',p=task||item.all_day?null:zonedParts(item.start_at);
    const time=task?'':item.all_day?'종일':zonedKey(item.start_at)<key(companionDate||focusDate)?'이전':`${pad(p.hour)}:${pad(p.minute)}`;
    const important=task&&['important','urgent'].includes(item.priority);
    return `<button type="button" class="companion-entry ${task?'task':'event'}${item.late?' late':''}" data-kind="${item.kind}" data-id="${escape(item.id)}">${task?'<span class="companion-task-icon" aria-hidden="true"></span>':`<time>${time}</time>`}<span class="companion-entry-copy"><span>${escape(calendarTitle(item))}</span>${selectedPropertyIds.length>1&&task&&item.property_name?`<small>${escape(item.property_name)}</small>`:''}</span>${important?`<span class="companion-priority" aria-label="${item.priority==='urgent'?'긴급':'중요'}">★</span>`:''}${item.late?'<span class="companion-overdue">지연</span>':''}<span class="companion-entry-arrow" aria-hidden="true">›</span></button>`;
  }
  function renderCompanionWeek(){
    const [first]=range(),selected=key(companionDate||focusDate);
    const days=Array.from({length:7},(_,i)=>addDays(first,i));
    const headers=days.map(d=>`<button type="button" class="companion-week-date${key(d)===selected?' selected':''}" data-date="${key(d)}" aria-label="${key(d)} 선택"><span>${dayNames[d.getDay()]}</span><b>${d.getDate()}</b></button>`).join('');
    const allDay=days.map(d=>`<div class="companion-week-all-day" data-date="${key(d)}">${boardItems(d).filter(i=>i.kind==='task'||i.all_day).slice(0,2).map(itemMarkup).join('')}${boardItems(d).filter(i=>i.kind==='task'||i.all_day).length>2?'<small>더 보기</small>':''}</div>`).join('');
    const columns=days.map(d=>{
      const start=+new Date(dayStart(d)),end=+new Date(dayStart(addDays(d,1)));
      const timed=boardItems(d).filter(i=>i.kind==='event'&&!i.all_day).map(i=>({...i,start:Math.max(start,+new Date(i.start_at)),end:Math.min(end,+new Date(i.end_at))})).sort((a,b)=>a.start-b.start||b.end-a.end);
      let group=[],groupEnd=0;
      function layout(){const lanes=[];for(const item of group){let lane=lanes.findIndex(t=>t<=item.start);if(lane<0)lane=lanes.length;lanes[lane]=item.end;item.lane=lane;}for(const item of group)item.lanes=lanes.length;group=[];}
      for(const item of timed){if(group.length&&item.start>=groupEnd)layout();if(!group.length)groupEnd=item.end;else groupEnd=Math.max(groupEnd,item.end);group.push(item);}layout();
      return `<div class="companion-week-column${key(d)===selected?' selected':''}" data-date="${key(d)}">${timed.map(i=>{const top=(i.start-start)/3600000*32,height=Math.max(16,(i.end-i.start)/3600000*32);return `<button type="button" class="companion-time-event" data-kind="event" data-id="${escape(i.id)}" style="top:${top}px;height:${height}px;left:${i.lane/i.lanes*100}%;width:${100/i.lanes}%" title="${escape(calendarTitle(i))}">${escape(calendarTitle(i))}</button>`;}).join('')}</div>`;
    }).join('');
    $('calendarBoard').innerHTML=`<div class="companion-week"><div class="companion-week-heading"><span></span>${headers}</div><div class="companion-week-all"><span>종일</span>${allDay}</div><div class="companion-week-scroll" tabindex="0" aria-label="주간 시간표 · 위아래로 스크롤"><div class="companion-week-times"><div class="companion-hour-labels">${Array.from({length:24},(_,h)=>`<span style="top:${h*32}px">${pad(h)}:00</span>`).join('')}</div>${columns}</div></div></div>`;
    const scroll=$('calendarBoard').querySelector('.companion-week-scroll');scroll.scrollTop=weekScrollTop;scroll.onscroll=()=>weekScrollTop=scroll.scrollTop;
  }
  function calendarTitle(item){
    let title;
    if(!item.holiday_request_id)title=item.title;
    else{
      const names=isOwner?(item.target_names||[]).filter(Boolean).join(", "):"";
      const pending=item.title.includes("미결재");
      title=`휴일${names?` · ${names}`:""}${pending?" (미결재)":""}`;
    }
    return item.kind!=='task'&&selectedPropertyIds.length>1&&item.property_name?`${title} · ${item.property_name}`:title;
  }
  function itemMarkup(item){
    const task=item.kind==='task',late=task&&item.late,title=calendarTitle(item);
    return `<button type="button" class="calendar-item ${task?'task':''}${late?' late':''}" data-kind="${item.kind}" data-id="${escape(item.id)}" title="${escape(title)}">${task&&!companion?'<span class="calendar-item-label">To do</span>':''}${late?'<span class="calendar-late-badge">지연</span>':''} ${task?OMSMissionTasks.propertyTag(item,ownPropertyId):''}${escape(title)}</button>`;
  }
  function dayItemMarkup(item){
    const task=item.kind==='task',late=task&&item.late,title=calendarTitle(item);
    const p=task||item.all_day?null:zonedParts(item.start_at);
    const detail=task?'To do 메뉴에서 확인':item.all_day?'종일':`${pad(p.hour)}:${pad(p.minute)}`;
    return `<button type="button" class="calendar-item calendar-day-entry ${task?'task':''}${late?' late':''}" data-kind="${item.kind}" data-id="${escape(item.id)}" title="${escape(title)}"><span class="calendar-day-primary"><span class="calendar-day-type">${task?'To do':'일정'}</span>${late?'<span class="calendar-late-badge">지연</span>':''}${task?OMSMissionTasks.propertyTag(item,ownPropertyId):''}<span class="calendar-day-title">${escape(title)}</span></span><small>${detail}</small></button>`;
  }
  function weekItemMarkup(item){
    const task=item.kind==='task',late=task&&item.late,title=calendarTitle(item);
    return `<button type="button" class="calendar-week-entry ${task?'task':''}${late?' late':''}" data-kind="${item.kind}" data-id="${escape(item.id)}" title="${escape(title)}"><span class="calendar-week-bullet" aria-hidden="true">•</span><span class="calendar-week-type">${task?'To do':'일정'}</span>${late?'<span class="calendar-late-badge">지연</span>':''}${task?OMSMissionTasks.propertyTag(item,ownPropertyId):''}<span class="calendar-week-title">${escape(title)}</span></button>`;
  }
  function renderHeader(){
    $('rangeTitle').textContent=view==='month'?`${focusDate.getFullYear()}년 ${focusDate.getMonth()+1}월`:view==='week'?(companion?`${range()[0].getMonth()+1}월 ${range()[0].getDate()}–${addDays(range()[0],6).getMonth()!==range()[0].getMonth()?(addDays(range()[0],6).getMonth()+1)+'월 ':''}${addDays(range()[0],6).getDate()}일`:'이번 주 일정'):`${focusDate.getMonth()+1}월 ${focusDate.getDate()}일 ${dayNames[focusDate.getDay()]}요일`;
    document.querySelector('.calendar-toolbar').classList.toggle('week-mode',view==='week');
    document.querySelectorAll('#viewButtons [data-view]').forEach(button=>{const active=button.dataset.view===view;button.classList.toggle('active',active);button.setAttribute('aria-pressed',String(active));});
  }
  function renderMonth(){
    const [first,end]=range(),now=today(),cells=[];
    for(let date=first;date<end;date=addDays(date,1)){
      const items=boardItems(date),outside=date.getMonth()!==focusDate.getMonth();
      cells.push(`<div class="calendar-day${outside?' other':''}${sameDay(date,now)?' today':''}" data-date="${key(date)}"><button class="calendar-day-number" type="button" aria-label="${key(date)} ${companion?'선택':'일정 추가'}">${date.getDate()}</button>${items.slice(0,2).map(item=>itemMarkup(item)).join('')}${items.length>2?`<span class="calendar-more">+${items.length-2}건</span>`:''}</div>`);
    }
    $('calendarBoard').innerHTML=`<div class="calendar-weekdays">${dayNames.map(day=>`<span>${day}</span>`).join('')}</div><div class="calendar-month">${cells.join('')}</div>`;
  }
  function renderWeek(){
    if(companion){renderCompanionWeek();return;}
    const first=focusDate,now=today(),cards=[];
    for(let i=0;i<7;i++){
      const date=addDays(first,i),items=itemsFor(date),isToday=sameDay(date,now);
      const heading=`<h2>${isToday?'<span class="calendar-today-label">Today</span>':''}<span>${date.getMonth()+1}월 ${date.getDate()}일 ${dayNames[date.getDay()]}요일</span></h2>`;
      cards.push(`<div class="calendar-week-card${isToday?' today':''}" data-date="${key(date)}">${heading}${items.length?`<div class="calendar-week-items">${items.map(weekItemMarkup).join('')}</div>`:'<span class="calendar-empty">일정 없음 · 눌러서 추가</span>'}</div>`);
    }
    $('calendarBoard').innerHTML=`<div class="calendar-week-grid">${cards.join('')}</div>`;
  }
  function renderDay(){
    const items=boardItems(focusDate);
    $('calendarBoard').innerHTML=`<div class="calendar-day-view" data-date="${key(focusDate)}">${items.length?items.map(dayItemMarkup).join(''):'<div class="calendar-empty">일정이 없습니다.</div>'}</div>`;
  }
  function render(){
    renderHeader();if(view==='month')renderMonth();else if(view==='week')renderWeek();else renderDay();
    if(!companion)return;
    const date=companionDate||focusDate;
    $('companionTodoLink').href=todoUrl();
    const items=itemsFor(date),priority={urgent:2,important:1,normal:0};
    const due=items.filter(i=>i.kind==='task').sort((a,b)=>Number(b.late)-Number(a.late)||(priority[b.priority]||0)-(priority[a.priority]||0)||a.sort-b.sort);
    $('companionTasks').innerHTML=due.map(companionItemMarkup).join('')||'<p class="calendar-empty">할 일이 없습니다.</p>';
    $('companionEvents').innerHTML=items.filter(i=>i.kind==='event').map(companionItemMarkup).join('')||'<p class="calendar-empty">일정이 없습니다.</p>';
    $('companionEventCount').textContent=items.filter(i=>i.kind==='event').length;
    $('companionTaskCount').textContent=due.length;
    $('calendarBoard').querySelectorAll('[data-date]').forEach(node=>node.classList.toggle('companion-selected',node.dataset.date===key(date)));
  }
  async function rpc(action,event){
    const {data,error}=await window.omgSupabase.rpc('calendar_event_action',{p_access_token:session.accessToken,p_action:action,p_event:event});
    if(error||!data?.ok)throw new Error(data?.message||error?.message||'캘린더를 불러오지 못했습니다.');
    return data;
  }
  async function refresh(){
    const sequence=++refreshSequence;
    const [start,end]=range();$('calendarMessage').textContent='';
    try{let result=await rpc('list',{range_start:dayStart(start),range_end:dayStart(end)});
      if(isOwner&&selectedPropertyIds.length){const {data,error}=await window.omgSupabase.rpc('list_shared_calendar_board',{p_access_token:session.accessToken,p_property_ids:selectedPropertyIds,p_from:dayStart(start),p_to:dayStart(end)});if(error||!data?.ok)throw new Error(data?.message||error?.message||'캘린더를 불러오지 못했습니다.');result={...result,events:data.events,tasks:data.tasks};}
      const missionData=await OMSMissionTasks.load(session,{isOwner,propertyIds:isOwner?selectedPropertyIds:undefined});
      result.tasks=OMSMissionTasks.pending(missionData.missions||[],isOwner?'':session.employeeId);
      if(isOwner){
        const privateItems=await OMSMissionTasks.privateAction(session,'list');
        const visible=privateItems.items.filter(i=>!selectedPropertyIds.length||selectedPropertyIds.includes(i.property_id));
        result.events=[...(result.events||[]),...visible.filter(i=>i.kind==='event')];
        result.tasks=[...result.tasks,...OMSMissionTasks.pending(visible.filter(i=>i.kind==='task'))];
      }
      if(sequence!==refreshSequence)return;
      if(!isOwner)result.events=OMSWorkerTasks.events(result.events||[],session.employeeId);
      if(companion&&isOwner&&$('companionScope').value==='mine'){
        result.events=(result.events||[]).filter(e=>e.private_owner_id===session.ownerId||e.owner_target&&!(e.target_employee_ids||[]).length&&e.property_id===ownPropertyId);
        result.tasks=(result.tasks||[]).filter(t=>t.private_owner_id===session.ownerId);
      }
      if(companion&&isOwner){
        const picker=$('companionEmployee'),selected=picker.value,all=$('companionScope').value==='all';
        $('companionEmployeeLabel').hidden=!all;
        if(all){
          const directory=await OMSTargetPicker.load(session);
          if(sequence!==refreshSequence)return;
          picker.replaceChildren(new Option('전체',''),...directory.people.filter(person=>!selectedPropertyIds.length||selectedPropertyIds.includes(person.property_id)).map(person=>new Option(person.name,person.employee_id)));
          if([...picker.options].some(option=>option.value===selected))picker.value=selected;
          if(picker.value){
            result.events=(result.events||[]).filter(item=>(item.target_employee_ids||[]).includes(picker.value));
            result.tasks=(result.tasks||[]).filter(item=>!item.private_owner_id&&(!(item.target_employee_ids||[]).length||item.target_employee_ids.includes(picker.value)));
          }
        }
      }
      if(companion)window.OMSCalendarCompanion?.session(session);
      events=result.events||[];tasks=result.tasks||[];employees=result.employees||[];renderTargets();render();
    }catch(error){if(sequence===refreshSequence){$('calendarMessage').textContent=error.message;render();}}
  }
  let targetPicker=null,targetDirectory={people:[],properties:[]};
  function closeTargetPanel(){targetPicker?.close();}
  function renderTargets(){}
  async function openEditor(date,event=null){
    if(isOwner){try{targetDirectory=await OMSTargetPicker.load(session);}catch(error){$('calendarMessage').textContent=error.message;return;}}

    $('eventForm').reset();$('eventFormMessage').textContent='';$('eventId').value=event?.id||'';
    $('dialogTitle').textContent=event?'일정 수정':'일정 추가';
    $('eventDate').value=event?zonedKey(event.start_at):date;
    $('eventTitle').value=event?calendarTitle(event):'';$('eventDetails').value=event?.details||'';
    $('allDay').checked=event?!!event.all_day:true;
    if(event){const start=zonedParts(event.start_at),end=zonedParts(event.end_at);$('startTime').value=`${pad(start.hour)}:${pad(start.minute)}`;$('endTime').value=`${pad(end.hour)}:${pad(end.minute)}`;}
    else{$('startTime').value='09:00';$('endTime').value='10:00';}
    $('timeFields').hidden=$('allDay').checked;
    $('startTime').required=$('endTime').required=!$('allDay').checked;
    if(isOwner){const propertyId=event?.property_id||ownPropertyId;targetPicker?.destroy();targetPicker=OMSTargetPicker.mount({host:$('calendarTargets'),ownPropertyId,items:[...targetDirectory.people.filter(e=>!event||e.property_id===propertyId),{key:'owner',name:propertyId===ownPropertyId?'본인':'지점 관리자',is_employee:false,property_id:propertyId,property_name:targetDirectory.properties.find(p=>p.id===propertyId)?.name}],properties:targetDirectory.properties.filter(p=>!event||p.id===propertyId),title:'일정 대상',selected:event?[...(event.target_employee_ids||[]),...(event.owner_target?['owner']:[])]:['owner']});}
    const personal=$('calendarPrivate');
    if(personal){personal.checked=!!event?.private_owner_id||(!event&&companion&&$('companionScope').value==='mine');personal.disabled=!!event;
      $('calendarTargets').hidden=personal.checked;personal.onchange=()=>{$('calendarTargets').hidden=personal.checked;};}
    const readonly=!!event&&!event.can_edit;
    $('dialogTitle').textContent=readonly?'일정 보기':event?'일정 수정':'일정 추가';
    $('eventForm').querySelectorAll('input:not([type=hidden]),textarea').forEach(input=>input.disabled=readonly);
    targetPicker?.setDisabled(readonly);
    $('saveEvent').hidden=readonly;$('deleteEvent').hidden=!event||readonly;
    const dialog=$('eventDialog');
    dialog.style.top='';
    dialog.style.bottom='';
    dialog.style.left='';
    dialog.style.right='';
    dialog.style.margin='';
    dialog.style.maxHeight='';
    dialog.showModal();
    // Keep the opening top edge in place while optional time fields expand below.
    const top=Math.max(16,Math.round(dialog.getBoundingClientRect().top));
    dialog.style.top=`${top}px`;
    dialog.style.bottom='auto';
    dialog.style.left='0';
    dialog.style.right='0';
    dialog.style.margin='0 auto';
    dialog.style.maxHeight=`calc(100dvh - ${top+16}px)`;
    dialog.scrollTop=0;
  }
  function closeEditor(){closeTargetPanel();if($('eventDialog').open)$('eventDialog').close();}
  $('viewButtons').onclick=event=>{const button=event.target.closest('[data-view]');if(!button||!['month','week','day'].includes(button.dataset.view)||button.dataset.view===view)return;if(companion&&companionDate)focusDate=companionDate;view=button.dataset.view;companionDate=null;saveView();if(view==='week'&&!companion)focusDate=today();companionDate=null;refresh();};
  $('todayButton').onclick=()=>{focusDate=today();companionDate=null;refresh();};
  function move(direction){companionDate=null;if(view==='month')focusDate=new Date(focusDate.getFullYear(),focusDate.getMonth()+direction,Math.min(focusDate.getDate(),28));else focusDate=addDays(focusDate,direction*(view==='week'?7:1));refresh();}
  $('prevButton').onclick=()=>move(-1);$('nextButton').onclick=()=>move(1);
  $('addEvent').onclick=()=>openEditor(key(companionDate||focusDate));
  $('calendarBoard').onclick=event=>{
    const item=event.target.closest('[data-kind]');
    if(item){if(item.dataset.kind==='task'){location.href=companion?todoUrl({id:item.dataset.id}):'mission.html';return;}const record=events.find(e=>e.id===item.dataset.id);if(record)openEditor(zonedKey(record.start_at),record);return;}
    const date=event.target.closest('[data-create-date]')?.dataset.createDate||event.target.closest('[data-date]')?.dataset.date;
    if(date&&companion){companionDate=parseKey(date);render();return;}
    if(date){if(view==='day')focusDate=parseKey(date);openEditor(date);}
  };
  if(companion){
    document.body.classList.add('calendar-companion');
    document.querySelector('.calendar-top>a').textContent='OMS 캘린더';
    document.querySelector('.calendar-top>a').removeAttribute('href');
    $('calendarCompanion').hidden=false;$('companionControls').hidden=false;
    const switcher=$('viewButtons');

    $('todayButton').before(switcher);
    $('companionSettings').hidden=!window.OMSCalendarAndroid;
    $('companionScope').onchange=refresh;
    $('companionAddTask').onclick=()=>{if(session&&focusDate)location.href=todoUrl(null,true);};
    $('companionAddEvent').onclick=()=>openEditor(key(companionDate||focusDate));
    $('companionEmployee').onchange=refresh;
    $('companionSettings').setAttribute('aria-label','알림 설정');
    $('companionSettings').title='알림 설정';
    $('companionSettings').innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"><path d="m9 3 1-1h4l1 3 3 1 3 3-1 3 1 3-3 3-3 1-1 3h-4l-1-3-3-1-3-3 1-3-1-3 3-3 3-1Z"/><circle cx="12" cy="12" r="3.5"/></svg>';
    $('calendarPropertyPicker').before($('companionControls'));
    document.querySelector('.calendar-top').after($('companionEmployeeLabel'));
    $('companionVisibility').hidden=false;
    for(const [id,kind] of [['showCalendarEvents','event'],['showCalendarTasks','task']])$(id).onchange=()=>{visibleKinds[kind]=$(id).checked;try{localStorage.setItem(viewKey()+':visibility',JSON.stringify(visibleKinds));}catch(_){}render();};
    $('companionSettings').onclick=()=>window.OMSCalendarCompanion?.settings();
    $('calendarCompanion').onclick=event=>{
      const button=event.target.closest('[data-kind]');if(!button)return;
      if(button.dataset.kind==='task'){location.href=todoUrl({id:button.dataset.id});return;}
      const record=events.find(item=>item.id===button.dataset.id);if(record)openEditor(zonedKey(record.start_at),record);
    };
  }
  $('closeDialog').onclick=closeEditor;
  $('eventDialog').onclick=event=>{if(event.target===$('eventDialog'))closeEditor();};
  $('allDay').onchange=()=>{$('timeFields').hidden=$('allDay').checked;$('startTime').required=$('endTime').required=!$('allDay').checked;};
  $('eventForm').onsubmit=async event=>{
    event.preventDefault();const date=$('eventDate').value,allDay=$('allDay').checked;
    const start=allDay?dayStart(parseKey(date)):zonedISO(date,$('startTime').value);
    const end=allDay?dayStart(addDays(parseKey(date),1)):zonedISO(date,$('endTime').value);
    if(new Date(end)<=new Date(start)){$('eventFormMessage').textContent='종료 시간을 시작 시간보다 늦게 선택해주세요.';return;}
    const personal=isOwner&&$('calendarPrivate')?.checked;
    const selected=isOwner?targetPicker.value():[];
    if(isOwner&&!personal&&!selected.length){$('eventFormMessage').textContent='일정 대상을 선택해주세요.';return;}
    const button=$('saveEvent');button.disabled=true;$('eventFormMessage').textContent='';
    try{const item={id:$('eventId').value||null,title:$('eventTitle').value.trim(),details:$('eventDetails').value.trim(),start_at:start,end_at:end,all_day:allDay,owner_target:selected.includes('owner'),target_employee_ids:selected.filter(value=>value!=='owner')};if(personal)await OMSMissionTasks.privateAction(session,'save',{...item,kind:'event'});else if(isOwner){const {data,error}=await omgSupabase.rpc('save_targeted_tasks',{p_access_token:session.accessToken,p_kind:'calendar',p_item:item,p_targets:targetPicker.groups()});if(error||!data?.ok)throw Error(data?.message||'저장하지 못했습니다.');}else await rpc('save',item);closeEditor();if(view==='day')focusDate=parseKey(date);await refresh();}
    catch(error){$('eventFormMessage').textContent=error.message;}finally{button.disabled=false;}
  };
  $('deleteEvent').onclick=async()=>{if(!confirm('이 일정을 삭제할까요?'))return;const button=$('deleteEvent');button.disabled=true;try{const id=$('eventId').value;if(events.find(i=>i.id===id)?.private_owner_id)await OMSMissionTasks.privateAction(session,'delete',{id});else await rpc('delete',{id});closeEditor();await refresh();}catch(error){$('eventFormMessage').textContent=error.message;}finally{button.disabled=false;}};
  document.addEventListener('visibilitychange',()=>{if(!document.hidden&&session)refresh();});
  (async()=>{session=await window.omgSession.require({allowCompleted:true});if(!session)return;
    isOwner=session.sessionKind==='owner';if(companion)$('companionControls').hidden=!isOwner;timezone=session.timezone||'Asia/Seoul';focusDate=today();restoreView();
    if(companion){try{const saved=JSON.parse(localStorage.getItem(viewKey()+':visibility'));if(saved&&typeof saved.event==='boolean'&&typeof saved.task==='boolean')visibleKinds=saved;}catch(_){}$('showCalendarEvents').checked=visibleKinds.event;$('showCalendarTasks').checked=visibleKinds.task;}
    $('targetFieldset').hidden=!isOwner;
    if(isOwner){const own=await window.omgWorkConfig.load(session.accessToken);ownPropertyId=own.property.property_id;const control=await window.omgPropertySelector.mount({accessToken:session.accessToken,permission:'missions',alwaysShow:companion,allLabel:companion?'전체':'All',host:$('calendarPropertyPicker'),onChange:async ids=>{selectedPropertyIds=ids;$('addEvent').hidden=false;await refresh();}});selectedPropertyIds=control.selectedIds();$('addEvent').hidden=false;}
    await refresh();window.omgTransition.ready();
  })().catch(error=>{$('calendarMessage').textContent=error.message;window.omgTransition.ready();});
})();

