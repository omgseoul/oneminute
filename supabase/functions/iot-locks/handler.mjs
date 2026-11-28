import {createHash} from 'node:crypto';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TT='https://euapi.ttlock.com',BEDS='https://beds24.com/api/v2';
const positive=v=>{const n=Number(v);if(!Number.isSafeInteger(n)||n<1)throw Error('도어락·예약 식별자를 확인해주세요.');return n;};
export function localTime(date,time,zone){
 if(!/^\d{4}-\d{2}-\d{2}$/.test(date||'')||!/^\d{2}:\d{2}(:\d{2})?$/.test(time||''))throw Error('숙박 날짜와 사용 시간을 확인해주세요.');
 const target=Date.parse(date+'T'+time.slice(0,5)+':00Z');if(!Number.isFinite(target))throw Error('숙박 날짜를 확인해주세요.');
 const fmt=new Intl.DateTimeFormat('en-CA',{timeZone:zone||'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'});
 let t=target;for(let i=0;i<3;i++){const p=Object.fromEntries(fmt.formatToParts(new Date(t)).map(x=>[x.type,x.value]));const wall=Date.parse(`${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:${p.second}Z`);t+=target-wall;}return t;
}
export function bookingVersion(b){return JSON.stringify([b.id,b.propertyId,b.roomId,b.unitId,b.arrival,b.departure,b.status]);}
export function lockPinItems(b){return (b.infoItems||[]).filter(x=>x.code==='LOCK_PIN'&&(!x.bookingId||Number(x.bookingId)===Number(b.id)));}
const CONFLICT='기존 Lock info가 있어 비밀번호를 생성하지 못했습니다. 기존 Lock info를 삭제한 뒤 다시 시도해 주십시오.';
export function pinUpdate(b,pin){
 if(lockPinItems(b).length)throw Error(CONFLICT);
 return [{id:positive(b.id),infoItems:[{code:'LOCK_PIN',text:pin}]}];
}
export function choosePin(booking,blocked,settings={},random=()=>crypto.getRandomValues(new Uint32Array(1))[0]){
 const length=Number(settings.pin_length||4),strategy=settings.pin_strategy||'phone';
 // Keep the former phone -> mobile fallback when older settings have no second method.
 const secondary=settings.pin_strategy_secondary??(strategy==='phone'?'mobile':'none');
 const secondaryLength=Number(settings.pin_length_secondary??length);
 const allowed=['phone','mobile','random','booking','beds_booking','random_1_6'];
 if(!Number.isInteger(length)||length<4||length>9||!Number.isInteger(secondaryLength)||secondaryLength<4||secondaryLength>9||!allowed.includes(strategy)||!['none',...allowed].includes(secondary))throw Error('비밀번호 생성 방식을 확인해주세요.');
 let digits='0123456789',randomLength=length;
 for(const [method,methodLength] of [[strategy,length],[secondary,secondaryLength]]){
  if(method==='none')continue;
  if(method==='random'||method==='random_1_6'){digits=method==='random_1_6'?'123456':'0123456789';randomLength=methodLength;break;}
  const value=({phone:booking.phone,mobile:booking.mobile,booking:booking.apiReference,beds_booking:booking.id})[method];
  const n=String(value??'').replace(/\D/g,'');
  if(n.length<methodLength||/^(\d)\1+$/.test(n))continue;
  const candidate=n.slice(-methodLength);
  // An existing code on any mapped lock always forces a fresh random PIN.
  if(blocked.has(candidate))break;
  return candidate;
 }
 for(let i=0;i<1000;i++){let n='';for(let k=0;k<randomLength;k++)n+=digits[random()%digits.length];if(!blocked.has(n))return n;}
 throw Error('사용 가능한 비밀번호가 없습니다. 도어락 비밀번호 목록을 확인해주세요.');
}
function existingConflict(booking,state){
 const items=lockPinItems(booking);
 return items.length>0&&!(state.beds_write_intent===true&&items.length===1&&items[0].text===state.pin);
}
function safeLocks(rows){return rows.map(x=>({lockId:positive(x.lockId),lockAlias:String(x.lockAlias||x.lockName||x.lockId).slice(0,150),electricQuantity:Number(x.electricQuantity)||0,hasGateway:x.hasGateway===1,featureValue:String(x.featureValue||'')}));}
export function createIotService({rpc,fetcher=fetch,now=()=>Date.now()}){
 const ctl=(action,property=null,data={})=>rpc('iot_internal',{p_action:action,p_property:property,p_data:data});
 async function tt(path,property,params={},method='POST'){
  const app=await ctl('api_reserve',property),body=new URLSearchParams({...params,clientId:app.clientId,date:String(now())});
  if(path.startsWith('/oauth2/'))body.set('clientSecret',app.clientSecret);
  let r;try{r=await fetcher(TT+path+(method==='GET'?'?'+body:''),{method,headers:{'Content-Type':'application/x-www-form-urlencoded'},...(method==='POST'?{body}:{}),signal:AbortSignal.timeout(15000)});}catch{throw Error('TTLock 응답이 지연되었습니다. 등록 여부를 확인한 뒤 다시 시도합니다.');}
  const v=await r.json().catch(()=>null);if(!r.ok||!v||Number(v.errcode||0)!==0){const code=Number(v?.errcode);throw Error(({10007:'TTLock 아이디 또는 비밀번호를 확인해주세요.',10003:'TTLock 로그인이 만료되었습니다. 계정을 다시 연결해주세요.',30007:'TTLock 월 호출 한도가 소진되었습니다.',30006:'TTLock 요청이 많습니다. 잠시 후 재시도해주세요.',[-2018]:'TTLock 도어락 관리자 권한이 없습니다.',[-3009]:'도어락 비밀번호 저장 공간이 가득 찼습니다.'})[code]||'TTLock 요청에 실패했습니다. 계정·게이트웨이 연결 상태를 확인해주세요.');}return v;
 }
 async function list(path,p,token,args={}){const rows=[];for(let page=1;page<=50;page++){const v=await tt(path,p,{...args,accessToken:token,pageNo:page,pageSize:100},'GET');if(!Array.isArray(v.list))throw Error('TTLock 목록 응답을 확인하지 못했습니다.');rows.push(...v.list);if(page>=Number(v.pages||1))return rows;}throw Error('TTLock 목록이 너무 큽니다. 도어락을 확인해주세요.');}
 async function connect(p,d){
  if(typeof d.username!=='string'||!d.username.trim()||d.username.length>200||typeof d.password!=='string'||!d.password||d.password.length>256)throw Error('TTLock 아이디와 비밀번호를 입력해주세요.');
  const current=await ctl('credentials',p);if(current.settings?.enabled)throw Error('사용을 OFF로 바꾼 후 연결해주세요.');
  const v=await tt('/oauth2/token',p,{username:d.username.trim(),password:createHash('md5').update(d.password).digest('hex')});// TTLock's required wire format; the password/hash is never stored.
  if(!v.access_token||!v.refresh_token||!v.uid)throw Error('TTLock 계정 인증에 실패했습니다.');
  const secret={accessToken:v.access_token,refreshToken:v.refresh_token,expiresAt:now()+Number(v.expires_in||7776000)*1000,uid:v.uid};
  const locks=safeLocks(await list('/v3/lock/list',p,secret.accessToken));
  await ctl('connect',p,{secret,username:d.username.trim(),locks});
 }
 async function credentials(p){const c=await ctl('credentials',p);let s=c.secret;if(!s?.accessToken)throw Error('TTLock 계정을 먼저 연결해주세요.');
  if(s.expiresAt<now()+60000){const v=await tt('/oauth2/token',p,{grant_type:'refresh_token',refresh_token:s.refreshToken});if(!v.access_token||!v.refresh_token)throw Error('TTLock 계정을 다시 연결해주세요.');s={...s,accessToken:v.access_token,refreshToken:v.refresh_token,expiresAt:now()+Number(v.expires_in||7776000)*1000};await ctl('token',p,{secret:s});}return s;
 }
 async function reload(p){const s=await credentials(p);await ctl('locks',p,{locks:safeLocks(await list('/v3/lock/list',p,s.accessToken))});}
 async function records(p,d){
  const lockId=positive(d.lock_id),page=positive(d.page||1);
  const c=await ctl('credentials',p);
  if(!(c.settings?.mappings||[]).some(m=>Number(m.lock_id)===lockId))throw Error('이 지점에 연결된 도어락을 선택해주세요.');
  const token=await credentials(p);
  const value=await tt('/v3/lockRecord/list',p,{accessToken:token.accessToken,lockId,pageNo:page,pageSize:100},'GET');
  if(!Array.isArray(value.list))throw Error('도어락 기록 응답을 확인하지 못했습니다.');
  return {ok:true,lock_id:lockId,page,more:page<Number(value.pages||1),records:value.list.map(row=>({
   id:String(row.recordId??row.id??[row.lockDate,row.recordType,row.serverDate].join('-')),
   lock_id:lockId,type:Number(row.recordType),success:Number(row.success)===1,
   at:Number(row.lockDate)||Number(row.serverDate)||null,
   operator:String(row.username||'').slice(0,120),
   passcode:Number(row.recordType)===4?String(row.keyboardPwd||'').slice(0,20):''
  }))};
 }
 const bedsCtl=(action,p,data={})=>rpc('online_internal',{p_action:action,p_property:p,p_data:data});
 async function bedsRequest(p,path,token,body){
  const gate=await rpc('online_sync_control',{p_action:'check',p_property:p,p_data:{}});if(gate.skip)throw Error('Beds24 호출 제한으로 잠시 대기합니다.');
  let r;try{r=await fetcher(BEDS+path,{method:body?'POST':'GET',headers:{token,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(15000)});}catch{throw Error('Beds24 응답이 지연되었습니다. LOCK_PIN 반영 여부를 재확인합니다.');}
  if(r.status===429){await rpc('online_sync_control',{p_action:'cooldown',p_property:p,p_data:{seconds:Math.max(300,Number(r.headers.get('retry-after'))||0)}});throw Error('Beds24 호출 한도에 도달했습니다.');}
  const v=await r.json().catch(()=>null);if(!r.ok||!v)throw Error('Beds24 연결 또는 예약정보 쓰기 권한을 확인해주세요.');return v;
 }
 async function bedsCredentials(p){const c=await bedsCtl('credentials',p);if(!c.secret?.refreshToken||!c.beds_property_id)throw Error('Beds24 숙소 연결을 확인해주세요.');
  if(!c.secret.token||c.secret.expiresAt<now()+60000){const r=await fetcher(BEDS+'/authentication/token',{headers:{refreshToken:c.secret.refreshToken},signal:AbortSignal.timeout(15000)}),v=await r.json();if(!r.ok||!v.token)throw Error('Beds24 계정을 다시 연결해주세요.');c.secret={...c.secret,token:v.token,expiresAt:now()+Number(v.expiresIn||3600)*1000};await bedsCtl('token',p,{secret:c.secret});}return c;
 }
 async function getBooking(p,c,id){
  const path='/bookings?id='+positive(id)+'&propertyId='+positive(c.beds_property_id)+'&includeInfoItems=true';let v=await bedsRequest(p,path,c.secret.token);
  if(Array.isArray(v.data)&&!v.data.length)v=await bedsRequest(p,path+'&status=cancelled',c.secret.token);
  if(v.data?.length!==1||Number(v.data[0].id)!==Number(id)||Number(v.data[0].propertyId)!==Number(c.beds_property_id))throw Error('예약의 지점과 번호를 확인하지 못했습니다.');return v.data[0];
 }
 async function process(j){
  const p=j.property_id,s=j.settings;let state=structuredClone(j.state||{});state.grants||=[];
  const gate=()=>ctl('gate',p,{id:j.id,lease:j.lease});
  const checkpoint=async()=>ctl('checkpoint',p,{id:j.id,lease:j.lease,state,replaced:state.replaced===true});
  const finish=(status,error,next)=>ctl('finish',p,{id:j.id,lease:j.lease,status,error,...(next?{next_at:new Date(next).toISOString()}:{})});
  try{
   const bc=await bedsCredentials(p),b=await getBooking(p,bc,j.booking_id);
   await ctl('observe',p,{id:j.id,lease:j.lease,booking:b});
   // Check LOCK_PIN before ANY TTLock call, even an authentication refresh.
   if(existingConflict(b,state)){await finish('failed',CONFLICT);return;}
   const token=(await credentials(p)).accessToken;
   // Keep every attempted lock until it is reconciled, including a timed-out add before a room move.
   for(const lock of state.planned_locks||[])if(!state.grants.some(g=>Number(g.lock_id)===Number(lock)))state.grants.push({lock_id:lock});
   const name='OMS '+j.id,live=new Map();
   const codes=async lock=>{lock=positive(lock);if(!live.has(lock))live.set(lock,await list('/v3/lock/listKeyboardPwd',p,token,{lockId:lock}));return live.get(lock);};
   const remove=async(lock,item)=>{await gate();await tt('/v3/keyboardPwd/delete',p,{accessToken:token,lockId:lock,keyboardPwdId:positive(item.keyboardPwdId),deleteType:2});live.delete(Number(lock));};
   const start=localTime(b.arrival,s.start_time,j.timezone),end=localTime(b.departure,s.end_time,j.timezone);
   const removeGrants=async keep=>{for(const g of [...state.grants]){if(keep.has(Number(g.lock_id)))continue;const matches=(await codes(g.lock_id)).filter(x=>x.keyboardPwdName===name);for(const x of matches)await remove(g.lock_id,x);state.grants=state.grants.filter(x=>x.lock_id!==g.lock_id);await checkpoint();}};
   if(!['new','confirmed'].includes(b.status)||end<=now()){
    // Recover an add that succeeded remotely before its response/checkpoint was lost.
    for(const lock of state.planned_locks||[])if(!state.grants.some(g=>Number(g.lock_id)===Number(lock)))state.grants.push({lock_id:lock});
    await removeGrants(new Set());
    const own=lockPinItems(b).filter(x=>state.pin&&x.text===state.pin);if(own.length){await gate();await bedsRequest(p,'/bookings',bc.secret.token,[{id:positive(b.id),infoItems:own.map(x=>({id:positive(x.id)}))}]);const check=await getBooking(p,bc,b.id);if(lockPinItems(check).some(x=>x.text===state.pin))throw Error('사용 종료 후 Beds24 LOCK_PIN 정리를 확인하지 못했습니다.');}
    await finish('revoked');return;
   }
   if(end<=start)throw Error('비밀번호 사용 종료 시간이 시작 시간보다 빠릅니다.');
   const date=new Date(b.arrival+'T00:00:00Z');date.setUTCDate(date.getUTCDate()-s.days_before);const due=localTime(date.toISOString().slice(0,10),s.create_time,j.timezone);
   if(due>now()){
    for(const lock of state.planned_locks||[])if(!state.grants.some(g=>Number(g.lock_id)===Number(lock)))state.grants.push({lock_id:lock});
    await removeGrants(new Set());
    const own=lockPinItems(b);if(own.length&&state.beds_write_intent){await gate();await bedsRequest(p,'/bookings',bc.secret.token,[{id:positive(b.id),infoItems:own.map(x=>({id:positive(x.id)}))}]);if(lockPinItems(await getBooking(p,bc,b.id)).length)throw Error('일정 변경 후 OMS Lock info 정리를 확인하지 못했습니다.');}
    state.planned_locks=[];state.beds_write_intent=false;await checkpoint();await finish('waiting',null,due);return;
   }
   const mapping=s.mappings.filter(x=>x.kind==='room'&&Number(x.room_id)===Number(b.roomId)&&Number(x.unit_id)===Number(b.unitId));
   if(mapping.length!==1)throw Error('예약의 정확한 객실·유닛에 연결된 도어락이 없습니다. 객실 매칭을 확인해주세요.');
   const locks=[...new Set([mapping[0],...s.mappings.filter(x=>x.kind==='common')].map(x=>positive(x.lock_id)))];
   const all=[];for(const lock of locks)all.push(...await codes(lock));
   if(!state.pin){state.pin=choosePin(b,new Set(all.map(x=>String(x.keyboardPwd))),s);}
   // Detect collisions before touching any door. Never reuse another reservation's PIN.
   if(all.some(x=>String(x.keyboardPwd)===state.pin&&x.keyboardPwdName!==name))throw Error('같은 비밀번호가 다른 출입정보에 사용 중입니다. 수동 확인이 필요합니다.');
   state.planned_locks=locks;state.booking_version=bookingVersion(b);await checkpoint();
   for(const lock of locks){
    await gate();let own=(await codes(lock)).filter(x=>x.keyboardPwdName===name);if(own.length>1)throw Error('예약용 비밀번호가 중복되어 있습니다. 도어락을 확인해주세요.');
    if(!own.length){await tt('/v3/keyboardPwd/add',p,{accessToken:token,lockId:lock,keyboardPwd:state.pin,keyboardPwdName:name,keyboardPwdType:3,startDate:start,endDate:end,addType:2});live.delete(lock);}
    else if(String(own[0].keyboardPwd)!==state.pin||Number(own[0].startDate)!==start||Number(own[0].endDate)!==end){await tt('/v3/keyboardPwd/change',p,{accessToken:token,lockId:lock,keyboardPwdId:positive(own[0].keyboardPwdId),newKeyboardPwd:state.pin,keyboardPwdName:name,startDate:start,endDate:end,changeType:2});live.delete(lock);}
    own=(await codes(lock)).filter(x=>x.keyboardPwdName===name&&String(x.keyboardPwd)===state.pin&&Number(x.startDate)===start&&Number(x.endDate)===end);
    if(own.length!==1)throw Error('도어락의 비밀번호 등록 완료를 확인하지 못했습니다. 게스트 안내 전 확인이 필요합니다.');
    state.grants=state.grants.filter(x=>Number(x.lock_id)!==lock);state.grants.push({lock_id:lock,pwd_id:own[0].keyboardPwdId});await checkpoint();
   }
   const fresh=await getBooking(p,bc,b.id);if(bookingVersion(fresh)!==bookingVersion(b))throw Error('처리 중 예약이 변경되었습니다. 변경된 객실과 날짜로 다시 확인합니다.');
   if(existingConflict(fresh,state))throw Error(CONFLICT);
   const old=lockPinItems(fresh);
   if(!old.length){state.beds_write_intent=true;await checkpoint();await gate();const result=await bedsRequest(p,'/bookings',bc.secret.token,pinUpdate(fresh,state.pin));if(!Array.isArray(result)||result.length!==1||result[0].success!==true)throw Error('Beds24 LOCK_PIN 저장 결과를 확인하지 못했습니다. 예약정보 쓰기 권한을 확인해주세요.');}
   const verified=await getBooking(p,bc,b.id),items=lockPinItems(verified);
   if(bookingVersion(verified)!==bookingVersion(b)||items.length!==1||items[0].text!==state.pin)throw Error('Beds24 비밀번호가 다른 값으로 변경되었습니다. Beds24 TTLock 자동발급 중지 여부를 확인해주세요.');
   await removeGrants(new Set(locks));await checkpoint();await finish('done');
  }catch(e){const message=e.message||'도어락 처리에 실패했습니다.';await finish(message===CONFLICT||j.attempt>=3?'failed':'waiting',message).catch(()=>{});}
 }
 return {connect,reload,process,records,ctl};
}
export function createIotHandler({env,fetcher=fetch,waitUntil=p=>p.catch(()=>{})}){
 const rpc=async(name,args)=>{const key=env('SUPABASE_SERVICE_ROLE_KEY');const r=await fetcher(env('SUPABASE_URL')+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify(args),signal:AbortSignal.timeout(15000)});const v=await r.json();if(!r.ok)throw Error(v.code==='P0001'?v.message:'도어락 설정을 처리하지 못했습니다.');return v;};
 const service=createIotService({rpc,fetcher});
 async function drain(){const j=await service.ctl('claim');if(!j.empty)await service.process(j);for(const n of await service.ctl('pushes')){try{const r=await fetcher(env('SUPABASE_URL')+'/functions/v1/dispatch-briefing',{method:'POST',headers:{'Content-Type':'application/json','x-webhook-secret':env('PUSH_ADMIN_SECRET')||''},body:JSON.stringify({message_id:n.message_id}),signal:AbortSignal.timeout(20000)});if(r.ok&&(await r.json()).ok)await service.ctl('pushed',null,{id:n.id});}catch{}}}
 return async req=>{
  const origin=req.headers.get('origin'),allowed=['https://omgworks24.com','https://www.omgworks24.com','https://omgseoul.github.io'];const headers={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin',...(allowed.includes(origin)?{'Access-Control-Allow-Origin':origin}:{})};
  const reply=(v,status=200)=>new Response(JSON.stringify(v),{status,headers});
  if(origin&&!allowed.includes(origin))return reply({ok:false},403);
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers:{...headers,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'content-type,apikey,authorization'}});
  if(req.method!=='POST')return reply({ok:false},405);
  try{
   if(new URL(req.url).pathname.endsWith('/worker')){if(!await rpc('online_internal',{p_action:'worker_verify',p_property:null,p_data:{secret:req.headers.get('x-worker-secret')}}))return reply({ok:false},401);waitUntil(drain());return reply({ok:true},202);}
   const raw=await req.text();if(raw.length>60000)return reply({ok:false},413);const b=JSON.parse(raw),d=b.data||{};
   if(b.platform_token){const r=await fetcher(env('SUPABASE_URL')+'/auth/v1/user',{headers:{apikey:env('SUPABASE_SERVICE_ROLE_KEY'),Authorization:'Bearer '+b.platform_token},signal:AbortSignal.timeout(10000)}),u=await r.json();if(!r.ok||!u.id)return reply({ok:false,message:'운영센터에 다시 로그인해주세요.'},401);
    return reply(await rpc('iot_platform',{p_user:u.id,p_action:b.action,p_data:d}));}
   if(!UUID.test(b.access_token||''))return reply({ok:false,message:'관리자 로그인이 필요합니다.'},401);
   const auth=await rpc('iot_owner',{p_token:b.access_token,p_action:'auth',p_data:d}),p=auth.property_id;
   if(b.action==='records')return reply(await service.records(p,d));
   if(b.action==='connect'||b.action==='reload'){
    await rpc('iot_owner',{p_token:b.access_token,p_action:'get',p_data:{property_id:p}});
    if(b.action==='connect')await service.connect(p,d);else await service.reload(p);
    return reply(await rpc('iot_owner',{p_token:b.access_token,p_action:'get',p_data:{property_id:p}}));
   }
   if(b.action==='toggle'&&typeof d.enabled!=='boolean')throw Error('사용 여부를 확인해주세요.');
   if(b.action==='toggle'&&d.enabled===true){
    if(typeof d.sensitive_password!=='string'||!d.sensitive_password)throw Error('관리자 2차 비밀번호를 입력해주세요.');
    const verified=await rpc('verify_owner_sensitive_password',{p_access_token:b.access_token,p_password:d.sensitive_password});
    if(!verified?.ok)throw Error(verified?.message||'관리자 2차 비밀번호를 확인해주세요.');
   }
   delete d.sensitive_password;
   return reply(await rpc('iot_owner',{p_token:b.access_token,p_action:b.action,p_data:{...d,property_id:p}}));
  }catch(e){return reply({ok:false,message:e instanceof SyntaxError?'요청 형식을 확인해주세요.':e.message||'처리하지 못했습니다.'},400);}
 };
}
