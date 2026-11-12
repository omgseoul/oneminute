(async()=>{
 const $=id=>document.getElementById(id),session=await omgSession.require({allowCompleted:true});if(!session)return;if(session.sessionKind!=='owner'){location.replace('app.html');return;}
 const escape=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 let settings={},view='',bookingId=null,version=0,activeBasis='arrival',busy=false,sendId=null,sending=false,selectedProperty=null,switching=false,taskCount=0,bookingRows=null,inboxRows=null,selectedProperties=[],branches=[],propertyPicker=null,pickerMode=null,threadProperty=null;
 const settingsCache=new Map(),formPickers=[],resultCache=new Map(),inFlight=new Map(),autoChecked=new Map();
 let messageDays=7,messageFrom="",messageTo="";
 const reservationStates={new:'신규',confirmed:'확정',request:'요청',inquiry:'문의',cancelled:'취소',black:'차단',unknown:'미확인'};
 let selectedStatuses=new Set(['new','confirmed','request','inquiry']);
 const stateLabel={generating:'AI 생성 중',draft:'승인 대기',sending:'발송 중',sent:'발송 완료',failed:'실패',uncertain:'결과 확인 필요',rejected:'반려',stale:'새 메시지 · 재검토 필요'};
 function status(text='',error=false){$('status').textContent=text;$('status').className=error?'error':'';}
 function time(v){return v?new Date(v).toLocaleString('ko-KR',{timeZone:settings.timezone||'Asia/Seoul',month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit'}):'—';}
 function today(){return new Intl.DateTimeFormat('en-CA',{timeZone:settings.timezone||'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());}
 async function rawCall(action,data={},property=selectedProperty){data={...data,...(property?{property_id:property}:{})};let r;try{r=await fetch(OMG_SUPABASE.url+'/functions/v1/beds24',{method:'POST',headers:{apikey:OMG_SUPABASE.publishableKey,'Content-Type':'application/json'},body:JSON.stringify({action,data,access_token:session.accessToken}),signal:AbortSignal.timeout(65000)});}catch{throw Error(action==='send'?'연결이 끊겼습니다. 발송 결과를 대화내역·로그에서 확인해주세요. 같은 메시지를 바로 다시 보내지 마세요.':'연결을 확인하고 다시 시도해주세요.');}const v=await r.json();if(!r.ok||!v.ok)throw Error(v.message||'처리하지 못했습니다.');return v;}
 async function call(action,data={},property=selectedProperty){
  const read=['settings','inbox','bookings','logs','thread','sync_messages','sync_bookings'].includes(action),key=JSON.stringify([action,property,data]);
  if(read&&inFlight.has(key))return inFlight.get(key);
  const pending=rawCall(action,data,property);if(read)inFlight.set(key,pending);
  try{return await pending;}finally{if(read&&inFlight.get(key)===pending)inFlight.delete(key);}
 }
 function messageRange(){const end=messageDays?today():messageTo,start=messageDays?new Date(Date.parse(end+'T12:00:00Z')-(messageDays-1)*86400000).toISOString().slice(0,10):messageFrom;return {message_from:start,message_to:end};}
 function stamp(v,property){if(!v)return '시간 미정';const d=new Date(v);if(!Number.isFinite(d.getTime()))return '시간 미정';const parts=new Intl.DateTimeFormat('en-GB',{timeZone:settingsCache.get(property)?.timezone||settings.timezone||'Asia/Seoul',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(d),get=k=>parts.find(p=>p.type===k)?.value;return get('month')+'.'+get('day')+' '+get('hour')+':'+get('minute');}
 function closeFilters(){for(const name of ['period','status']){$(name+'Panel').hidden=true;$(name+'Button').setAttribute('aria-expanded','false');}}
 function initInboxFilters(){
  for(const name of ['period','status'])$(name+'Button').onclick=()=>{const open=$(name+'Panel').hidden;closeFilters();$(name+'Panel').hidden=!open;$(name+'Button').setAttribute('aria-expanded',String(open));};
  document.addEventListener('click',e=>{if(!e.target.closest('.filter-anchor'))closeFilters();});
  document.addEventListener('keydown',e=>{if(e.key==='Escape'){const active=['period','status'].find(n=>!$(n+'Panel').hidden);closeFilters();if(active)$(active+'Button').focus();}});
  const apply=()=>{version++;$('periodButton').innerHTML='<span class="period-label">'+escape(messageDays?(messageDays===1?'오늘':messageDays+'일'):shortDate(messageFrom)+'–'+shortDate(messageTo))+'</span> <span aria-hidden="true">⌄</span>';document.querySelectorAll('[data-days]').forEach(b=>b.setAttribute('aria-pressed',String(Number(b.dataset.days)===messageDays)));closeFilters();loadInbox().catch(e=>status(e.message,true));};
  document.querySelectorAll('[data-days]').forEach(b=>{b.setAttribute('aria-pressed',String(Number(b.dataset.days)===messageDays));b.onclick=()=>{messageDays=Number(b.dataset.days);apply();};});
  $('customPeriodButton').onclick=()=>{const r=messageRange();$('messagePeriodForm').hidden=false;$('messageFrom').value=r.message_from;$('messageTo').value=r.message_to;$('messageFrom').focus();};
  $('messagePeriodForm').onsubmit=e=>{e.preventDefault();const from=$('messageFrom').value,to=$('messageTo').value;if(!from||!to||to<from){$('messageTo').setCustomValidity('종료일은 시작일 이후로 선택해주세요.');$('messageTo').reportValidity();return;}$('messageTo').setCustomValidity('');messageDays=0;messageFrom=from;messageTo=to;apply();};$('messageTo').oninput=()=> $('messageTo').setCustomValidity('');$('statusDone').onclick=()=>{closeFilters();$('statusButton').focus();};
 }
 async function task(button,fn){if(button?.disabled)return;const locksBranch=!['searchButton','refreshInbox','refreshThread','refreshLogs'].includes(button?.id);if(locksBranch){taskCount++;lockPicker(true);}const taskVersion=version,text=button?.textContent;if(button){button.disabled=true;button.setAttribute('aria-busy','true');if(button.id!=='refreshInbox')button.textContent='처리 중…';}try{await fn();}catch(e){if(taskVersion===version)status(e.message,true);}finally{if(button){button.disabled=false;button.removeAttribute('aria-busy');if(button.id!=='refreshInbox')button.textContent=text;}if(locksBranch)taskCount--;lockPicker(switching||taskCount>0);}}
 function updateSettings(v){settings=v;selectedProperty=v.property_id;settingsCache.set(v.property_id,v);branches=v.branches||[{id:v.property_id,name:v.property_name}];if(!selectedProperties.length)selectedProperties=[v.property_id];$('mappingPropertyName').textContent=v.property_name;$('bedsProperty').disabled=!!v.beds_property_id;$('mappingHelp').textContent=v.beds_property_id?'지점 전환은 화면 오른쪽 위에서 선택하세요. 이 지점의 숙소 연결은 고정되어 있습니다.':'현재 OMS 지점에 해당하는 Beds24 숙소를 선택하고 저장하세요.';$('reuseConnection').hidden=v.connected||!v.connection_sources?.length;$('connectionSource').innerHTML=(v.connection_sources||[]).map(p=>`<option value="${escape(p.id)}">${escape(p.name)}</option>`).join('');$('webhookProperty').textContent=v.property_name;$('connectionLabel').textContent=v.beds_property_id?'Beds24 연결됨 · '+v.beds_name:v.connected?'숙소 선택 필요':'Beds24 연결 전';$('lastSync').textContent=v.synced_at?'최근 동기화 '+time(v.synced_at):'';$('connectedStatus').textContent=v.connected?'연결 정보가 서버에 등록되어 있습니다.':'';$('bedsProperty').innerHTML='<option value="">숙소 선택</option>'+v.properties.map(p=>`<option value="${escape(p.id)}">${escape(p.name)} · ${escape(p.id)}</option>`).join('');$('bedsProperty').value=v.beds_property_id||'';$('aiMode').value=v.ai_mode;document.querySelector('a[href="guest-ai-settings.html"]').hidden=v.property_id!==session.propertyId;$('dataCount').textContent=`현재 지점 안내 DATA ${v.data_count||0}개`;$('webhookUrl').value=v.beds_property_id?OMG_SUPABASE.url+'/functions/v1/beds24/webhook?property='+v.property_id+'&key='+v.webhook_key:'';$('copyWebhook').disabled=!v.beds_property_id;$('webhookStatus').textContent=v.webhook_at?'최근 수신 '+time(v.webhook_at):v.beds_property_id?'아직 수신된 웹훅이 없습니다. Beds24 등록 후 실제 수신을 확인하세요.':'숙소를 선택하고 저장하면 주소가 표시됩니다.';formPickers.forEach(p=>p.refresh());mountPropertyPicker();}
 function threadURL(id,property,from=view){return '#thread/'+encodeURIComponent(id)+'?property='+encodeURIComponent(property||selectedProperty)+'&from='+encodeURIComponent(['today','search','logs'].includes(from)?from:'inbox');}
 function rowKey(row){return String(row.property_id||selectedProperty)+':'+String(row.id??row.booking_id);}
 function renderBookings(v){
  bookingRows=v;const rows=(v.bookings||[]).filter(b=>selectedStatuses.has(b.status||'unknown')),list=$('bookingList'),opened=new Set([...list.querySelectorAll('details[open]')].map(x=>x.dataset.booking));
  $('bookingCount').textContent=`예약 ${rows.length}건`;
  $('bookingFreshness').textContent=[v.synced_at?'최근 동기화 '+time(v.synced_at):'아직 동기화된 정보가 없습니다.',...(v.warnings||[])].join(' · ');
  list.innerHTML=rows.length?rows.map(b=>{
   const name=b.guest_name||'이름 미등록',channel=b.channel||'직접 예약',property=b.property_name||settings.property_name,dates=shortDate(b.arrival)+'–'+shortDate(b.departure),key=rowKey(b);
   return `<details class="booking-item" data-booking="${escape(key)}" ${opened.has(key)?'open':''}><summary aria-label="${escape(name+' · '+channel+' · '+(b.arrival||'미정')+' ~ '+(b.departure||'미정')+' · '+property)}"><span class="booking-name" title="${escape(name)}">${escape(name)}</span><span class="booking-channel" title="${escape(channel)}">${escape(channel.replace(/booking\.com/i,'Booking'))}</span><span class="booking-dates" title="${escape(b.arrival)} ~ ${escape(b.departure)}">${escape(dates)}</span><span class="booking-property" title="${escape(property)}">${escape(property)}</span><span class="inbox-chevron" aria-hidden="true">⌄</span></summary><div class="inbox-expanded"><div class="item-title"><span>${escape(name)}</span><span class="status-tag">${escape(reservationStates[b.status]||'미확인')}</span></div><p class="item-meta">${escape(property)} · ${escape(channel)}<br>${escape(b.room_name||'객실 미정')} · 성인 ${escape(b.data?.numAdult??'—')} / 아동 ${escape(b.data?.numChild??'—')}<br>체크인 ${escape(b.arrival)} · 체크아웃 ${escape(b.departure)}<br>예약일 ${time(b.booked_at)} · #${escape(b.id)}</p><a class="text-link" href="${escape(threadURL(b.id,b.property_id))}">대화 열기 ›</a></div></details>`;
  }).join(''):'<div class="empty">이 조건으로 저장된 예약이 없습니다.<br>조회·새로고침으로 Beds24 정보를 확인하세요.</div>';
 }
 function range(){if(view==='today')return {basis:activeBasis,from:today(),to:today(),statuses:[...selectedStatuses]};return {basis:$('dateBasis').value,from:$('dateFrom').value,to:$('dateTo').value,statuses:[...selectedStatuses]};}
 async function loadBookings(refresh=false){const n=version,d=range();if(refresh)status('Beds24에서 예약정보를 가져오는 중입니다.');const v=await collect(refresh?'sync_bookings':'bookings',d);if(n!==version)return;renderBookings(v);if(refresh)status(v.warnings?.length?v.warnings.join('\n'):'예약정보를 갱신했습니다.',!!v.warnings?.length);}
 function shortDate(v){const m=String(v||'').match(/^\d{4}-(\d{2})-(\d{2})/);return m?m[1]+'.'+m[2]:'—';}
 function renderInbox(v){
  inboxRows=v;const rows=(v.threads||[]).filter(t=>selectedStatuses.has(t.status||'unknown')),unread=rows.reduce((n,x)=>n+Number(x.unread||0),0),list=$('inboxList');$('inboxCount').textContent=`대화 ${rows.length}건`;$('unreadBadge').hidden=!unread;$('unreadBadge').textContent=unread;
  const signature=JSON.stringify([settings.property_name,rows]);if(list.dataset.signature===signature)return;
  const opened=new Set([...list.querySelectorAll('details[open]')].map(x=>x.dataset.booking)),focused=document.activeElement?.closest('.inbox-item')?.dataset.booking;
  list.dataset.signature=signature;
  list.innerHTML=rows.length?rows.map(t=>{
   const name=t.guest_name||'예약 #'+t.booking_id,room=t.room_name||'객실 미정',property=t.property_name||settings.property_name||'지점 미정',dates=shortDate(t.arrival)+' → '+shortDate(t.departure),preview=String(t.preview||'');
   return `<details class="inbox-item" data-booking="${escape(rowKey(t))}" ${opened.has(rowKey(t))?'open':''}><summary aria-label="${escape(name)} 메시지 펼치기"><span class="inbox-reservation"><span class="inbox-name" title="${escape(name)}">${escape(name)}</span><span class="inbox-room" title="${escape(room)}">${escape(room)}</span><span class="inbox-dates" title="체크인 ${escape(t.arrival||'미정')} · 체크아웃 ${escape(t.departure||'미정')}">${escape(dates)}</span><span class="inbox-property" title="${escape(property)}">${escape(property)}</span></span><span class="inbox-preview-row"><time class="inbox-timestamp" datetime="${escape(t.sent_at)}">${escape(stamp(t.sent_at,t.property_id))}</time><span class="inbox-preview">${escape(preview.replace(/\s+/g,' ').trim()||'첨부 메시지')}</span>${t.drafts?'<span class="inbox-ai">AI 승인</span>':''}${t.unread?`<span class="badge">${Number(t.unread)}</span>`:''}<span class="inbox-chevron" aria-hidden="true">⌄</span></span></summary><div class="inbox-expanded"><p class="item-meta">${escape(name)} · ${escape(room)} · ${escape(property)}<br>체크인 ${escape(t.arrival||'미정')} · 체크아웃 ${escape(t.departure||'미정')}<br>최근 메시지 ${time(t.sent_at)}</p><p class="inbox-full-message">${escape(preview||'첨부 내용은 대화에서 확인해주세요.')}</p><a class="text-link" href="${escape(threadURL(t.booking_id,t.property_id))}">전체 대화·답변 열기 ›</a></div></details>`;
  }).join(''):'<div class="empty">선택한 기간·예약상태에 해당하는 대화가 없습니다.</div>';
  if(focused)[...list.querySelectorAll('.inbox-item')].find(x=>x.dataset.booking===focused)?.querySelector('summary')?.focus({preventScroll:true});
 }
 async function loadInbox(refresh=false){const n=version,d={statuses:[...selectedStatuses],...(view==='inbox'?messageRange():{})};const v=await collect(refresh?'sync_messages':'inbox',d);if(n!==version)return;renderInbox(v);$('inboxFreshness').textContent=v.warnings?.length?v.warnings.join(' · '):v.synced_at?'최근 동기화 '+time(v.synced_at):'';if(refresh&&!v.warnings?.length)status();}
 function maybeSyncInbox(){
  if(view!=='inbox'||document.hidden||$('refreshInbox').disabled)return;
  const now=Date.now(),due=selectedProperties.filter(id=>{const cfg=settingsCache.get(id);return cfg?.beds_property_id&&now-Math.max(autoChecked.get(id)||0,Date.parse(cfg.synced_at)||0)>=300000;});
  if(!due.length)return;selectedProperties.forEach(id=>autoChecked.set(id,now));task($('refreshInbox'),()=>loadInbox(true));
 }
 function logCard(d){return `<article class="item"><div class="item-title"><span>${d.kind==='ai'?'AI 답변':'직접 답변'} · #${escape(d.booking_id)}</span><span class="status-tag ${escape(d.status)}">${escape(stateLabel[d.status]||d.status)}</span></div><p class="item-meta">${escape(d.property_name||branchName(d.property_id||threadProperty))} · ${time(d.created_at)}${d.charged_micro?' · '+Number(d.charged_micro/1000).toFixed(3)+' 크레딧':''}</p><p class="log-text">${escape(d.body||d.error||'답변 생성 중')}</p>${d.error?`<p class="item-meta">${escape(d.error)}</p>`:''}<details class="log-details"><summary>처리 상세</summary>승인자: ${escape(d.approved_name||d.approved_by||'미승인')}<br>처리시간: ${time(d.updated_at)}<br>판단: ${escape(d.result?.reason||'—')}<br>참고 DATA: ${escape((d.result?.sources||[]).filter(x=>(d.result?.parts||[]).some(p=>p.sources?.includes(String(x.id)))).map(x=>x.title).join(', ')||'—')}</details><p><a class="text-link" href="${escape(threadURL(d.booking_id,d.property_id||threadProperty))}">대화 열기 ›</a></p></article>`;}
 function renderThread(v){const b=v.booking;$('guestName').textContent=b?.guest_name||'예약 #'+bookingId;$('guestMeta').textContent=b?`${branchName(threadProperty)} · ${b.room_name||'객실 미정'} · ${b.arrival} → ${b.departure} · ${b.channel||'직접 예약'}`:'대화를 새로고침하면 예약정보를 가져옵니다.';$('threadMessages').innerHTML=v.messages.length?v.messages.map(m=>`<div class="message ${escape(m.source==='host'?'host':m.source==='guest'?'guest':'system')}">${escape(m.body)}${m.attachment_name?`<p class="note">첨부: ${escape(m.attachment_name)} · 원본은 Beds24에서 확인</p>`:''}<small>${escape(({guest:'게스트',host:'숙소',system:'시스템',internalNote:'내부 메모'})[m.source]||m.source)} · ${time(m.sent_at)}</small></div>`).join(''):'<div class="empty">저장된 메시지가 없습니다. 대화를 새로고침하세요.</div>';
  // Do not replace edited approval text while polling.
  const drafts=v.outbox.filter(d=>d.status==='draft');const signature=drafts.map(x=>x.id+':'+x.updated_at).join('|');if($('drafts').dataset.signature!==signature){$('drafts').dataset.signature=signature;$('drafts').innerHTML=drafts.map(d=>`<section class="card draft" data-draft="${escape(d.id)}"><h3>AI 답변 · 승인 대기</h3><p class="note">${escape(d.result?.reason||'안내 DATA를 참고한 답변입니다.')}<br>수정 후 승인하면 게스트에게 발송됩니다.</p><textarea rows="5" maxlength="4000" aria-label="AI 답변 수정">${escape(d.body)}</textarea><div class="actions"><button data-reject="${escape(d.id)}">반려</button><button data-approve="${escape(d.id)}" class="primary">승인하고 발송</button></div></section>`).join('');$('drafts').querySelectorAll('[data-approve]').forEach(el=>el.onclick=()=>task(el,async()=>{const body=el.closest('.draft').querySelector('textarea').value;await send(body,el.dataset.approve);}));$('drafts').querySelectorAll('[data-reject]').forEach(el=>el.onclick=()=>task(el,async()=>{await call('reject',{id:el.dataset.reject},threadProperty);await loadThread();}));}
  $('sendState').innerHTML=v.outbox.filter(x=>['sending','failed','uncertain','stale','generating'].includes(x.status)).map(logCard).join('');
 }
 async function loadThread(refresh=false){if(view!=='thread'||!bookingId||!threadProperty)return;const n=version,id=bookingId;const v=await call(refresh?'sync_messages':'thread',{booking_id:id},threadProperty);if(n!==version||id!==bookingId)return;renderThread(v);if(v.warning)status(v.warning);}
 async function send(body,id){if(sending)return;if(!body.trim())throw Error('답변을 입력해주세요.');sending=true;const n=version,property=threadProperty,targetBooking=bookingId;try{status('메시지를 전송하고 있습니다.');const v=await call('send',{booking_id:targetBooking,body,id},property);if(n!==version)return;if(v.status==='sent'){$('replyBody').value='';sendId=null;status('Beds24에 메시지를 발송했습니다.');}else{status(v.error||({'stale':'새 메시지가 도착했습니다. 대화를 확인하고 답변을 다시 작성해주세요.','uncertain':'발송 여부를 확인해야 합니다. 대화를 새로고침하세요.','sending':'발송 처리 중입니다. 잠시 후 로그를 확인해주세요.','failed':'발송하지 못했습니다. 로그를 확인해주세요.'})[v.status]||'처리 상태를 확인해주세요.',true);}await loadThread();}finally{sending=false;}}
 async function loadLogs(){const n=version;const v=await collect('logs');if(n!==version)return;if(v.warnings?.length)status(v.warnings.join('\n'),true);$('logList').innerHTML=v.logs.length?v.logs.map(logCard).join(''):'<div class="empty">아직 AI·메시지 처리 기록이 없습니다.</div>';}
 async function navigate(){const navigationVersion=++version;status();const route=location.hash.slice(1);view=route.startsWith('thread/')?'thread':route||'menu';document.body.dataset.view=view;bookingId=view==='thread'?Number(route.split('/')[1].split('?')[0]):null;const routeParams=new URLSearchParams(route.split('?')[1]||'');threadProperty=view==='thread'?(routeParams.get('property')||selectedProperty):null;if(view==='thread'&&(!Number.isSafeInteger(bookingId)||bookingId<=0)){location.hash='inbox';return;}
  document.querySelectorAll('.view').forEach(x=>x.hidden=true);const names={menu:['온라인 관리','예약과 게스트 대화를 한곳에서 관리합니다.'],settings:['기본정보','이 지점의 Beds24 연결을 관리합니다.'],today:['당일 체크인 명단','오늘의 도착 일정과 숙박 중인 게스트를 확인합니다.'],search:['체크인 명단 조회','체크인 날짜 또는 예약 생성 날짜로 조회합니다.'],inbox:['메시지','예약사이트에서 받은 문의에 답변합니다.'],thread:['게스트 대화','Beds24 대화내역과 AI 초안을 함께 확인합니다.'],logs:['AI 승인·로그','발송 전 승인과 처리 결과를 확인합니다.']};if(!names[view]){location.hash='';return;}$('pageTitle').textContent=names[view][0];$('pageDescription').textContent=names[view][1];$(view==='today'||view==='search'?'bookingsView':view+'View').hidden=false;mountPropertyPicker();updateBackLink(routeParams);
  if(view==='today'||view==='search'){$('todayTabs').hidden=view!=='today';$('searchFilters').hidden=view==='today';await loadBookings();if(navigationVersion===version&&selectedProperties.length)await task($('searchButton'),()=>loadBookings(true));}
  else if(view==='inbox'){await loadInbox();if(navigationVersion===version)maybeSyncInbox();}
  else if(view==='thread'){$('replyBody').value='';sendId=null;$('drafts').dataset.signature='';await loadThread();if(navigationVersion===version&&threadProperty)await task($('refreshThread'),()=>loadThread(true));}
  else if(view==='logs')await loadLogs();else if(view==='menu'){updateConnectionSummary();await loadInbox();}
 }
 function renderStatusFilters(){
  $('bookingStatusFilters').innerHTML=Object.entries(reservationStates).map(([value,label])=>`<button type="button" data-reservation-status="${value}" aria-pressed="${selectedStatuses.has(value)}">${label}</button>`).join('');
  $('inboxStatusFilters').innerHTML=Object.entries(reservationStates).map(([value,label])=>`<label><input type="checkbox" data-reservation-status="${value}" ${selectedStatuses.has(value)?'checked':''}>${label}</label>`).join('');$('statusSelectedCount').textContent=selectedStatuses.size;
  for(const el of document.querySelectorAll('[data-reservation-status]'))el.addEventListener(el.tagName==='INPUT'?'change':'click',()=>{const key=el.dataset.reservationStatus;if(selectedStatuses.has(key))selectedStatuses.delete(key);else selectedStatuses.add(key);renderStatusFilters();if(bookingRows)renderBookings(bookingRows);if(inboxRows)renderInbox(inboxRows);version++;if(view==='inbox')loadInbox().catch(e=>status(e.message,true));else if(view==='search'||view==='today')loadBookings().catch(e=>status(e.message,true));});
 }
 function branchName(id){return branches.find(p=>String(p.id)===String(id))?.name||settingsCache.get(id)?.property_name||'지점 미정';}
 function lockPicker(locked){$('propertyName').inert=locked;$('propertyName').querySelectorAll('button,input').forEach(el=>el.disabled=locked);}
 function updateConnectionSummary(){if(selectedProperties.length===1){const v=settingsCache.get(selectedProperties[0]);$('connectionLabel').textContent=branchName(selectedProperties[0])+' · '+(v?.beds_property_id?'Beds24 연결됨':'연결 상태는 기본정보에서 확인');}else $('connectionLabel').textContent=selectedProperties.length?selectedProperties.length+'개 지점 통합 조회':'조회할 지점을 선택하세요.';$('lastSync').textContent='';}
 function mountPropertyPicker(){
  const mode=view==='settings'?'single':'multi',signature=JSON.stringify([mode,branches,mode==='single'?selectedProperty:selectedProperties]);
  if(pickerMode===signature)return;propertyPicker?.destroy?.();pickerMode=signature;
  const options={host:$('propertyName'),items:branches.map(p=>({value:String(p.id),label:p.name})),title:'온라인 관리 지점'};
  propertyPicker=mode==='single'?omgPropertySelector.mountSingle({...options,value:selectedProperty,onChange:changeSettingsProperty}):omgPropertySelector.mountMulti({...options,allLabel:'All',allOptionLabel:'모든 지점',selectionUnit:'개 지점',selectedValues:selectedProperties,onChange:ids=>{
   if(switching||taskCount||sending){propertyPicker.setValues(selectedProperties,false);return;}
   selectedProperties=ids;pickerMode=JSON.stringify(['multi',branches,selectedProperties]);version++;bookingRows=inboxRows=null;$('bookingList').replaceChildren();$('inboxList').replaceChildren();delete $('inboxList').dataset.signature;$('logList').replaceChildren();
   if(view==='thread'){go('inbox',true);return;}navigate().catch(e=>status(e.message,true));
  }});lockPicker(switching||taskCount>0);
 }
 async function changeSettingsProperty(next){
  if(next===selectedProperty||switching||taskCount||sending)return;
  switching=true;lockPicker(true);version++;const n=version;status('지점 정보를 불러오고 있습니다.');$('settingsView').inert=true;
  try{const v=await call('settings',{},next);updateSettings(v);if(n===version)status();}
  catch(e){pickerMode=null;mountPropertyPicker();status(e.message,true);}
  finally{switching=false;$('settingsView').inert=false;lockPicker(taskCount>0);}
 }
 async function collect(action,data={}){
  const ids=[...selectedProperties],out={bookings:[],threads:[],logs:[],warnings:[],synced_at:null};
  const results=await Promise.allSettled(ids.map(async id=>{
   let cfg=settingsCache.get(id);if(!cfg){cfg=await call('settings',{},id);settingsCache.set(id,cfg);}
   const sync=action.startsWith('sync_'),fallback=action==='sync_bookings'?'bookings':'inbox';
   const readAction=sync?fallback:action,cacheKey=JSON.stringify([id,readAction,data]);let result;
   try{
    result=await call(sync&&!cfg.beds_property_id?fallback:action,data,id);
    if(readAction==='inbox'&&result.threads?.length===300){result={...result,threads:[...result.threads]};for(let offset=300;;offset+=300){const page=await call('inbox',{...data,offset},id);result.threads.push(...(page.threads||[]));if((page.threads||[]).length<300)break;if(offset>=14700){result.warning='조회량이 많습니다. 기간을 줄여주세요.';break;}}}
    resultCache.set(cacheKey,result);
   }catch(e){
    if(sync){try{result=await call(fallback,data,id);result={...result,warning:e.message+' · 저장된 내역을 표시합니다.'};}catch{}}
    if(!result){const cached=resultCache.get(cacheKey);if(!cached)throw e;result={...cached,warning:'연결 지연 · 마지막으로 확인한 내역을 표시합니다.'};}
   }
   return {id,cfg,result,unlinked:!cfg.beds_property_id};
  }));
  if(ids.length&&results.every(r=>r.status==='rejected'))throw Error('목록을 불러오지 못했습니다. 기존 내역을 유지합니다.');
  results.forEach((entry,index)=>{
   if(entry.status==='rejected'){out.warnings.push(branchName(ids[index])+': '+entry.reason.message);return;}
   const {id,cfg,result,unlinked}=entry.value;
   for(const key of ['bookings','threads','logs'])out[key].push(...(result[key]||[]).map(row=>({...row,property_id:id,property_name:cfg.property_name})));
   if(result.warning)out.warnings.push(cfg.property_name+': '+result.warning);
   if(result.synced_at)settingsCache.set(id,{...cfg,synced_at:result.synced_at});
   if(result.synced_at&&(!out.synced_at||result.synced_at<out.synced_at))out.synced_at=result.synced_at;
   if(unlinked)out.warnings.push(cfg.property_name+': 기본정보에서 Beds24 숙소를 연결해주세요.');
   if(result.bookings?.length>=2000)out.warnings.push(cfg.property_name+': 조회 한도 2,000건입니다. 기간을 줄여주세요.');
  });
  out.bookings.sort((a,b)=>String(a.arrival).localeCompare(String(b.arrival))||String(a.guest_name).localeCompare(String(b.guest_name)));
  out.threads.sort((a,b)=>String(b.sent_at).localeCompare(String(a.sent_at)));out.logs.sort((a,b)=>String(b.created_at).localeCompare(String(a.created_at)));
  return out;
 }
 function parentRoute(){if(view!=='thread')return '';const from=new URLSearchParams(location.hash.split('?')[1]||'').get('from');return ['today','search','logs'].includes(from)?from:'inbox';}
 function updateBackLink(){const route=parentRoute(),back=$('onlineBack');back.href=view==='menu'?'app.html':'#'+route;back.textContent=view==='menu'?'← Home':view==='thread'?'‹ 목록':'‹ 온라인 관리';if(view==='thread'){$('threadView').querySelector('.back').href='#'+route;$('threadView').querySelector('.back').textContent='‹ '+({today:'당일 체크인 명단',search:'체크인 명단 조회',logs:'AI 승인·로그',inbox:'메시지 목록'}[route]);}}
 function go(route,replace=false){
  propertyPicker?.close?.();const url=location.pathname+location.search+(route?'#'+route:'');
  if(replace)history.replaceState({...history.state,online:true},'',url);else if(location.href!==new URL(url,location.href).href)history.pushState({online:true,onlineParent:location.hash.slice(1)},'',url);
  navigate().catch(e=>status(e.message,true));
 }
 document.addEventListener('click',event=>{
  const a=event.target.closest('a[href^="#"]');if(!a||event.defaultPrevented||event.button!==0||event.metaKey||event.ctrlKey||event.shiftKey||event.altKey)return;
  event.preventDefault();const route=a.getAttribute('href').slice(1);if(a.id==='onlineBack'||a.classList.contains('back')){propertyPicker?.close?.();if(history.state?.onlineParent===route){history.back();return;}go(route,true);return;}go(route);
 });
 addEventListener('popstate',()=>navigate().catch(e=>status(e.message,true)));
 $('reuseButton').onclick=e=>task(e.currentTarget,async()=>{updateSettings(await call('reuse_connection',{source_property_id:$('connectionSource').value}));status('기존 Beds24 연결을 등록했습니다. 이 OMS 지점과 연결할 숙소를 선택하고 저장하세요.');});
 renderStatusFilters();initInboxFilters();
 $('connectForm').onsubmit=e=>{e.preventDefault();task($('connectButton'),async()=>{status('Beds24 연결을 확인하고 있습니다.');try{const v=await call('connect',{code:$('inviteCode').value});updateSettings(v);status('연결되었습니다. 이 지점에 해당하는 숙소를 선택하고 설정을 저장하세요.');}finally{$('inviteCode').value='';}});};
 $('reloadProperties').onclick=e=>task(e.currentTarget,async()=>{updateSettings(await call('properties'));status('숙소 목록을 갱신했습니다.');});
 $('settingsForm').onsubmit=e=>{e.preventDefault();task(e.submitter,async()=>{await call('save_settings',{beds_property_id:$('bedsProperty').value,ai_mode:$('aiMode').value});updateSettings(await call('settings'));status('설정을 저장했습니다. 아래 웹훅 주소를 Beds24에 등록하세요.');});};
 $('copyWebhook').onclick=e=>task(e.currentTarget,async()=>{try{await navigator.clipboard.writeText($('webhookUrl').value);status(settings.property_name+' 지점의 웹훅 주소를 복사했습니다.');}catch{$('webhookUrl').focus();$('webhookUrl').select();status('주소를 선택했습니다. 길게 눌러 복사하거나 Ctrl+C를 누르세요.');}});
 $('searchForm').onsubmit=e=>{e.preventDefault();task($('searchButton'),()=>loadBookings(true));};document.querySelectorAll('[data-basis]').forEach(el=>el.onclick=()=>{activeBasis=el.dataset.basis;document.querySelectorAll('[data-basis]').forEach(b=>b.classList.toggle('selected',b===el));task($('searchButton'),()=>loadBookings(true));});
 $('refreshInbox').onclick=e=>task(e.currentTarget,()=>loadInbox(true));$('refreshThread').onclick=e=>task(e.currentTarget,()=>loadThread(true));$('refreshLogs').onclick=e=>task(e.currentTarget,loadLogs);
 $('makeDraft').onclick=e=>task(e.currentTarget,async()=>{status('AI가 이 지점의 안내 DATA로 답변을 작성하고 있습니다.');await call('draft',{booking_id:bookingId},threadProperty);await loadThread();status('생성 결과를 확인해주세요. 승인 전에는 발송되지 않습니다.');});
 $('replyBody').oninput=()=>{sendId=null;};$('replyForm').onsubmit=e=>{e.preventDefault();sendId ||= crypto.randomUUID();task($('sendButton'),()=>send($('replyBody').value,sendId));};
 for(const id of ['bedsProperty','connectionSource','aiMode','dateBasis'])formPickers.push(omgSelectPicker.mount($(id),{title:({bedsProperty:'Beds24 연동 숙소',connectionSource:'기존 Beds24 연결',aiMode:'온라인 메시지 AI 응대',dateBasis:'조회 기준'})[id]}));
 const initialRoute=location.hash.slice(1);if(initialRoute&&!history.state?.online){history.replaceState({online:true},'',location.pathname+location.search);if(initialRoute.startsWith('thread/')){const from=new URLSearchParams(initialRoute.split('?')[1]||'').get('from'),parent=['today','search','logs'].includes(from)?from:'inbox';history.pushState({online:true,onlineParent:''},'','#'+parent);history.pushState({online:true,onlineParent:parent},'','#'+initialRoute);}else history.pushState({online:true,onlineParent:''},'','#'+initialRoute);}else history.replaceState({...history.state,online:true},'',location.href);
 updateSettings(await call('settings'));$('dateFrom').value=$('dateTo').value=today();await navigate();
 setInterval(async()=>{if(document.hidden||busy||sending||switching)return;busy=true;try{if(view==='thread')await loadThread();else if(view==='inbox'){await loadInbox();maybeSyncInbox();}else if(view==='logs')await loadLogs();else if(view==='menu'){updateConnectionSummary();await loadInbox();}}catch{/* foreground actions show actionable errors */}finally{busy=false;}},12000);
})().catch(e=>{const el=document.getElementById('status');el.textContent=e.message;el.className='error';});
