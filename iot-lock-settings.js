(async()=>{
 const $=id=>document.getElementById(id),esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const session=await omgSession.require({allowCompleted:true});if(!session)return;if(session.sessionKind!=='owner'){location.replace('app.html');return;}
 const {data:shares,error}=await omgSupabase.rpc('list_property_shares',{p_access_token:session.accessToken});if(error||!shares?.ok)throw Error('지점 목록을 불러오지 못했습니다.');
 const properties=shares.properties.filter(p=>p.is_own||['property_settings','messages'].every(k=>(p.permissions||[]).includes(k))),propertyId=new URLSearchParams(location.search).get('property_id')||(properties.find(p=>p.is_own)||properties[0])?.property_id;
 if(!properties.some(p=>p.property_id===propertyId))throw Error('이 지점의 도어락 설정 권한이 없습니다.');
 let state,busy=false,dirty=false,rows=[];const dirtyGroups=new Set();
 const blankMapping=()=>({kind:'room',lock_id:'',room_name:'',room_id:'',unit_id:''});
 const markDirty=group=>{dirtyGroups.add(group);dirty=true;};
 const pinFields={pin_strategy:'iotStrategy',pin_strategy_secondary:'iotStrategy2',pin_length:'iotDigits',pin_length_secondary:'iotDigits2',days_before:'iotDays',create_time:'iotCreateTime',start_time:'iotStartTime',end_time:'iotEndTime'};
 const pinValues=()=>Object.fromEntries(Object.entries(pinFields).map(([key,id])=>[key,['pin_length','pin_length_secondary','days_before'].includes(key)?Number($(id).value):$(id).value]));
 omgPropertySelector.mountSingle({host:$('iotPropertyPicker'),title:'지점 선택',items:properties.map(p=>({value:p.property_id,label:p.property_name,meta:p.is_own?'본지점':''})),value:propertyId,onChange:id=>{if(id!==propertyId)location.href='iot-lock-settings.html?property_id='+encodeURIComponent(id);}});
 window.addEventListener('beforeunload',e=>{if(dirty){e.preventDefault();e.returnValue='';}});
 const status=(v,bad=false)=>{$('iotStatus').textContent=v;$('iotStatus').classList.toggle('error',bad);};
 async function request(action,data={},fn='iot-locks'){const r=await fetch(OMG_SUPABASE.url+'/functions/v1/'+fn,{method:'POST',headers:{'Content-Type':'application/json',apikey:OMG_SUPABASE.publishableKey},body:JSON.stringify({access_token:session.accessToken,action,data:{...data,property_id:propertyId}}),signal:AbortSignal.timeout(60000)}),v=await r.json();if(!r.ok||!v.ok)throw Error(v.message||'도어락 요청을 처리하지 못했습니다.');return v;}
 const options=(items,value)=>'<option value="">선택</option>'+items.map(([id,name])=>`<option value="${esc(id)}" ${String(id)===String(value)?'selected':''}>${esc(name)}</option>`).join('');
 function mappings(){if(!rows.length)rows=[blankMapping()];const host=$('iotMappings');host.replaceChildren();rows.forEach((m,i)=>{
  const el=document.createElement('div');el.className='iot-map';const units=state.inventory.flatMap(t=>(t.units||[]).map(u=>[t.id+':'+u.id,`${u.name||u.id} · ${t.name||t.id}`]));
  el.innerHTML=`<div class="iot-map-row"><label for="iotKind${i}">연결유형</label><div class="iot-lock-pair"><select id="iotKind${i}" data-field="kind" aria-label="연결유형"><option value="room">객실</option><option value="common" ${m.kind==='common'?'selected':''}>공용</option></select><select data-field="lock_id" aria-label="TTLock 도어락" required>${options(state.settings.locks.map(l=>[l.lockId,l.lockAlias]),m.lock_id)}</select></div>${i?`<button type="button" class="iot-del" data-remove aria-label="${esc(m.room_name||'공용 출입문')} 매칭 삭제">DEL</button>`:''}</div><div class="iot-map-row"><label for="iotRoom${i}">OMS 객실</label>${m.kind==='room'?`<div class="iot-room-pair"><select id="iotRoom${i}" data-field="room_name" aria-label="OMS 객실" required>${options(state.rooms.map(r=>[r,r]),m.room_name)}</select><select data-field="unit" aria-label="Beds24 객실 · 유닛" required>${options(units,m.room_id+':'+m.unit_id).replace('>선택</option>','>Beds24 유닛</option>')}</select></div>`:'<span class="iot-common-rooms">연결된 모든 객실</span>'}${i===rows.length-1?'<button type="button" class="iot-add" data-add aria-label="객실 연결 추가">+</button>':''}</div>`;
  el.querySelectorAll('[data-field]').forEach(input=>input.onchange=()=>{markDirty('mapping');const k=input.dataset.field;if(k==='unit'){[m.room_id,m.unit_id]=input.value?input.value.split(':').map(Number):['',''];}else m[k]=k==='lock_id'?Number(input.value):input.value;if(k==='kind'){delete m.room_id;delete m.unit_id;delete m.room_name;mappings();}});const remove=el.querySelector('[data-remove]');if(remove)remove.onclick=()=>{rows.splice(i,1);markDirty('mapping');mappings();};const add=el.querySelector('[data-add]');if(add)add.onclick=()=>{rows.splice(i+1,0,blankMapping());markDirty('mapping');mappings();host.children[i+1].querySelector('[data-field=kind]').focus();};host.append(el);
 });}
 function dayHelp(){const n=Number($('iotDays').value);$('iotDaysHelp').textContent=n===0?'당일 발급 시각 이후 들어온 예약도 비밀번호가 자동 생성됩니다.':`${n}일 전으로 설정해도 ${n===1?'당일':'전날·당일'}에 들어온 예약은 비밀번호가 자동 생성됩니다.`;}
 $('iotDays').addEventListener('input',dayHelp);
 document.querySelectorAll('.iot-help').forEach(button=>button.onclick=e=>{e.preventDefault();e.stopPropagation();$('iotHelpTitle').textContent=button.dataset.help==='iotPinHelp'?'비밀번호 생성 방식':'체크인 며칠 전';$('iotHelpBody').textContent=$(button.dataset.help).textContent;$('iotHelpDialog').showModal();});
 $('iotHelpClose').onclick=()=>$('iotHelpDialog').close();
 // Reveal invalid fields before the browser focuses them, including collapsed mappings.
 document.addEventListener('invalid',e=>{const section=e.target.closest('details.iot-section');if(section)section.open=true;},true);
 function controls(){if(!state)return;const s=state.settings;$('iotEditable').querySelectorAll('input,select,button:not(.iot-help)').forEach(el=>el.disabled=busy||s.enabled);$('iotEnabled').disabled=busy||(!s.enabled&&(!state.provider_ready||!state.connected||!s.mappings.some(x=>x.kind==='room')));$('iotConnect').inert=busy||s.enabled;$('iotDisconnect').disabled=busy||s.enabled||!state.connected;$('iotReload').disabled=busy||!state.connected;$('iotRefresh').disabled=busy;$('iotPropertyPicker').inert=busy;}
 function render(){const s=state.settings;rows=structuredClone(s.mappings);$('iotEnabled').checked=s.enabled;$('iotState').textContent=s.enabled?'ON · 자동발급 중':'OFF · 자동발급 중지';$('iotReady').textContent=!state.provider_ready?'운영센터에서 TTLock 앱 연결을 먼저 완료해주세요.':!state.connected?'아래에서 TTLock 계정을 연결해주세요.':!s.mappings.some(x=>x.kind==='room')?'객실 매칭을 저장한 뒤 사용을 켜주세요.':s.enabled?'매칭과 발급 조건은 OFF 상태에서 수정할 수 있습니다.':'OFF 상태에서는 신규 발급·변경·정리가 중지됩니다. 이미 등록된 번호는 설정한 종료 시각까지 유효합니다.';
  $('iotAccount').textContent=state.connected?`${s.username} · 도어락 ${s.locks.length}개 연결`:'아직 연결된 계정이 없습니다.';$('iotUsername').value=s.username||'';$('iotPassword').value='';$('iotStrategy').value=s.pin_strategy;$('iotStrategy2').value=s.pin_strategy_secondary??(s.pin_strategy==='phone'?'mobile':'none');$('iotDigits').value=s.pin_length;$('iotDigits2').value=s.pin_length_secondary??s.pin_length;$('iotDays').value=s.days_before;for(const [id,k] of [['iotCreateTime','create_time'],['iotStartTime','start_time'],['iotEndTime','end_time']])$(id).value=s[k].slice(0,5);
  dayHelp();$('iotTimeHelp').textContent=`숙소 시간대 ${state.timezone||'Asia/Seoul'} 기준 · 발급 예정 시각이 지난 예약은 다음 처리 주기에 생성합니다.`;$('iotMappingHelp').textContent=!state.inventory.length?'Beds24 기본정보에서 숙소·객실 정보를 먼저 불러와주세요.':!state.rooms.length?'Property 설정에 객실을 먼저 등록해주세요.':`${s.locks.length}개 도어락 · ${s.mappings.filter(x=>x.kind==='room').length}개 객실 연결`;
  mappings();$('iotJobs').innerHTML=state.jobs.map(j=>`<div class="iot-job"><div class="row between"><b>${esc(j.guest_name||'이름 미등록')} · ${esc(j.room_name||'객실 미정')}</b><span class="iot-badge ${esc(j.status)}">${({waiting:'대기',working:'처리 중',done:'등록 완료',failed:'실패',revoked:'사용 종료'})[j.status]}</span></div><p>예약 #${esc(j.booking_id)} · ${esc(j.arrival)} ~ ${esc(j.departure)}</p>${j.error||j.status==='failed'? `<div class="iot-job-feedback">${j.status==='failed'?`<button type="button" class="btn iot-retry" data-retry="${esc(j.id)}" ${!s.enabled?'disabled':''}>재시도</button>`:''}<p class="iot-error" title="${esc(j.error||'')}" tabindex="0">${esc(j.error?.startsWith('기존 Lock info가 있어')?'기존 Lock info를 삭제한 뒤 다시 시도해주세요.':j.error||'처리 결과를 확인해주세요.')}</p></div>`:''}</div>`).join('');$('iotJobs').querySelectorAll('[data-retry]').forEach(b=>b.onclick=()=>run('retry',{job_id:b.dataset.retry},'해당 예약을 다시 확인합니다.'));$('iotContent').hidden=false;controls();}
 async function run(action,data={},message='',keepGroup=null){if(busy)return;const draft=keepGroup&&dirtyGroups.has(keepGroup)?{rows:structuredClone(rows),pin:Object.fromEntries(Object.values(pinFields).map(id=>[id,$(id).value]))}:null;busy=true;controls();status('처리 중…');try{state=await request(action,data);dirty=false;dirtyGroups.clear();render();if(draft){if(keepGroup==='mapping'){rows=draft.rows;mappings();}else{for(const [id,value] of Object.entries(draft.pin))$(id).value=value;dayHelp();}markDirty(keepGroup);}status(message);}catch(e){status(e.message,true);}finally{busy=false;controls();$('iotPassword').value='';if(state)$('iotEnabled').checked=state.settings.enabled;}}
 $('iotConnect').onsubmit=e=>{e.preventDefault();run('connect',{username:$('iotUsername').value.trim(),password:$('iotPassword').value},'도어락을 불러왔습니다. 객실 매칭을 저장해주세요.');};$('iotReload').onclick=()=>run('reload',{},'도어락 목록을 갱신했습니다.');$('iotRefresh').onclick=()=>{if(dirty){status('변경한 설정을 먼저 저장해주세요.',true);return;}run('get');};$('iotDisconnect').onclick=()=>{if(confirm('TTLock 계정 연결을 해제할까요?'))run('disconnect',{},'연결을 해제했습니다.');};
 $('iotSettings').oninput=e=>markDirty(e.target.closest('#iotMappingSection')?'mapping':'pin');
 $('iotSettings').onkeydown=e=>{if(e.key==='Enter'&&!e.isComposing&&e.target.matches('input')){e.preventDefault();$('iotSettings').requestSubmit($(e.target.closest('#iotMappingSection')?'iotSaveMappings':'iotSavePin'));}};
 $('iotSettings').onsubmit=e=>{e.preventDefault();if(busy||state.settings.enabled)return;const group=e.submitter?.value||(document.activeElement.closest('#iotMappingSection')?'mapping':'pin'),section=$(group==='mapping'?'iotMappingSection':'iotPinSection');
  if(group==='mapping'&&!rows.some(m=>m.lock_id||m.room_name||m.room_id||m.unit_id)){status('저장할 연결정보가 없습니다.',true);alert('저장할 연결정보가 없습니다.');return;}
  // Validate only the section being saved; leave the other section's draft untouched.
  for(const input of section.querySelectorAll('input,select'))if(!input.reportValidity())return;
  const saved=state.settings,pin=group==='pin'?pinValues():Object.fromEntries(Object.keys(pinFields).map(k=>[k,saved[k]]));
  pin.pin_strategy_secondary??=saved.pin_strategy==='phone'?'mobile':'none';pin.pin_length_secondary??=saved.pin_length;
  run('save',{...pin,mappings:group==='mapping'?rows:saved.mappings},group==='mapping'?'객실 매칭 설정을 저장했습니다.':'비밀번호 발급 설정을 저장했습니다.',group==='mapping'?'pin':'mapping');
 };

 $('iotEnabled').onchange=e=>{if(!e.target.checked){run('toggle',{enabled:false},'자동발급을 중지했습니다.');return;}e.target.checked=false;if(dirty){status('매칭과 발급 설정을 먼저 저장해주세요.',true);return;}$('iotEnableError').textContent='';$('iotSensitive').value='';$('iotBedsOff').checked=false;$('iotEnableDialog').showModal();};$('iotEnableCancel').onclick=()=>$('iotEnableDialog').close();$('iotEnableDialog').addEventListener('close',()=>$('iotSensitive').value='');
 $('iotEnableForm').onsubmit=async e=>{e.preventDefault();if(busy)return;busy=true;controls();$('iotEnableSubmit').disabled=true;try{$('iotEnableError').textContent='예약정보를 갱신하고 자동발급을 시작합니다…';const fmt=new Intl.DateTimeFormat('en-CA',{timeZone:state.timezone||'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}),from=fmt.format(new Date()),to=fmt.format(new Date(Date.now()+31*86400000));const sync=await request('sync_bookings',{basis:'staying',from,to},'beds24');if((sync.warning&&sync.warning!=='최근 동기화 내역을 표시합니다.')||sync.warnings?.length)throw Error(sync.warning||sync.warnings.join(' '));state=await request('toggle',{enabled:true,beds24_disabled:$('iotBedsOff').checked,sensitive_password:$('iotSensitive').value});dirty=false;dirtyGroups.clear();render();$('iotEnableDialog').close();status('자동발급을 시작했습니다. 처리 결과는 아래 내역과 봇 알림에서 확인하세요.');}catch(err){$('iotEnableError').textContent=err.message;}finally{busy=false;$('iotEnableSubmit').disabled=false;$('iotSensitive').value='';controls();}};
 const logCache=new Map();let logSelection='',logLoading=false;
 const recordLabels={1:'앱 열림',4:'비밀번호 열림',7:'카드 열림',8:'지문 열림',55:'리모컨',[-4]:'QR 코드',[-5]:'얼굴 인식'};
 function logLocks(){return [...new Map((state?.settings.mappings||[]).map(m=>[Number(m.lock_id),{id:Number(m.lock_id),name:state.settings.locks.find(l=>Number(l.lockId)===Number(m.lock_id))?.lockAlias||m.room_name||'공용 출입문'}])).values()];}
 function showLogs(){
  const locks=logLocks(),selected=locks.filter(l=>!logSelection||String(l.id)===logSelection);
  $('iotLogTabs').innerHTML=[{id:'',name:'전체'},...locks].map(l=>`<button type="button" class="btn ${String(l.id)===logSelection?'primary':''}" aria-pressed="${String(l.id)===logSelection}" data-log-lock="${esc(l.id)}">${esc(l.name)}</button>`).join('');
  $('iotLogTabs').querySelectorAll('[data-log-lock]').forEach(b=>b.onclick=()=>{logSelection=b.dataset.logLock;showLogs();loadLogs();});
  const records=selected.flatMap(l=>(logCache.get(l.id)?.records||[]).map(r=>({...r,lock_name:l.name}))).sort((a,b)=>(b.at||0)-(a.at||0));
  const fmt=new Intl.DateTimeFormat('ko-KR',{timeZone:state?.timezone||'Asia/Seoul',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'});
  $('iotLogRows').innerHTML=records.map(r=>`<div class="iot-log-row"><strong title="${esc(r.lock_name)}">${esc(r.lock_name)}</strong><span>${esc(recordLabels[r.type]||'기록 '+r.type)}${r.success?'':' · 실패'}</span><time>${esc(r.at?fmt.format(new Date(r.at)):'시간 없음')}</time><small>${esc(r.passcode?'비밀번호 '+r.passcode:r.operator||'')}</small></div>`).join('')||'<p class="help">표시할 기록이 없습니다.</p>';
  $('iotLogMore').hidden=!selected.some(l=>logCache.get(l.id)?.more);
  $('iotLogMore').disabled=logLoading;$('iotLogRefresh').disabled=logLoading;
 }
 async function loadLogs(refresh=false,more=false){
  if(logLoading||!state)return;
  logLoading=true;showLogs();$('iotLogStatus').textContent='기록을 불러오는 중…';
  const locks=logLocks().filter(l=>(!logSelection||String(l.id)===logSelection)&&(refresh||!logCache.has(l.id)||more&&logCache.get(l.id).more));
  const errors=[];let index=0;
  const worker=async()=>{while(index<locks.length){const lock=locks[index++],old=logCache.get(lock.id),page=more?(old?.page||0)+1:1;try{
   const result=await request('records',{lock_id:lock.id,page});
   const entries=page===1?result.records:[...(old?.records||[]),...result.records];
   logCache.set(lock.id,{...result,records:[...new Map(entries.map(r=>[r.id,r])).values()]});
  }catch(e){errors.push(lock.name+' · '+e.message);}}};
  try{await Promise.all(Array.from({length:Math.min(3,locks.length)},worker));if(locks.length)$('iotLogUpdated').textContent='조회 '+new Date().toLocaleTimeString('ko-KR',{hour:'2-digit',minute:'2-digit',hourCycle:'h23'});$('iotLogStatus').textContent=errors.join(' / ');}
  finally{logLoading=false;showLogs();if(!errors.length&&logLocks().some(l=>(!logSelection||String(l.id)===logSelection)&&!logCache.has(l.id)))loadLogs();}
 }
 $('iotLogSection').addEventListener('toggle',()=>{if($('iotLogSection').open)loadLogs();});
 $('iotLogRefresh').onclick=()=>loadLogs(true);
 $('iotLogMore').onclick=()=>loadLogs(false,true);
 await run('get');
})().catch(e=>{document.getElementById('iotStatus').textContent=e.message;});
