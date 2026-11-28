import {createAutoMessages,includesPin} from './auto-messages.mjs';
import {createWebCheckin,accessCode,assignedUnit} from './web-checkin.mjs';
import {createDocumentReader} from './web-checkin-document.mjs';
import {createTranslation} from './translation.mjs';
import {buildRequest,validateAnswer} from '../guest-ai/handler.mjs';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BASE='https://beds24.com/api/v2';
export function positive(v){const n=Number(v);if(!Number.isSafeInteger(n)||n<=0)throw Error('예약번호를 확인해주세요.');return n;}
export function dateRange(d){const valid=v=>/^\d{4}-\d{2}-\d{2}$/.test(v||'')&&new Date(v+'T00:00:00Z').toISOString().slice(0,10)===v;if(!valid(d.from)||!valid(d.to)||d.to<d.from||(Date.parse(d.to)-Date.parse(d.from))/86400000>92)throw Error('조회 기간은 최대 93일입니다.');if(!['arrival','departure','booked','staying'].includes(d.basis))throw Error('조회 기준을 확인해주세요.');return d;}
export function revenueImportRange(d){if(typeof d.from!=='string'||typeof d.to!=='string'||!['staying','arrival','booked'].includes(d.basis)||d.from.slice(0,7)!==d.to.slice(0,7)||(Date.parse(d.to)-Date.parse(d.from))/86400000>30)throw Error('예약 불러오기는 한 지점의 같은 달 안에서 최대 31일만 가능합니다.');dateRange(d);return d;}
export function selectBooking(b){return {...Object.fromEntries(['id','propertyId','roomId','roomName','unitId','firstName','lastName','arrival','departure','bookingTime','status','apiSource','referer','apiReference','numAdult','numChild','arrivalTime'].map(k=>[k,b[k]??null])),price:typeof b.price==='number'&&Number.isFinite(b.price)&&b.price>=0?b.price:null};}
// Retain only inventory identifiers and display fields, never provider notes or credentials.
export function selectProperty(p){return {id:positive(p.id),name:String(p.name||''),roomTypes:(p.roomTypes||[]).map(r=>({id:positive(r.id),name:String(r.name||''),roomType:String(r.roomType||''),qty:Number.isInteger(r.qty)&&r.qty>=0?r.qty:null,units:(r.units||[]).map(u=>({id:positive(u.id),name:String(u.name||''),name2:String(u.name2||'')}))}))};}
export function selectMessage(m){return Object.fromEntries(['id','bookingId','propertyId','source','message','time','attachmentName'].map(k=>[k,m[k]??null]));}
export function createBedsHandler({env,fetcher=fetch,waitUntil=p=>p.catch(()=>{})}){
 const url=()=>env('SUPABASE_URL'),key=()=>env('SUPABASE_SERVICE_ROLE_KEY');
 async function rpc(name,args){const r=await fetcher(url()+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:key(),Authorization:'Bearer '+key(),'Content-Type':'application/json'},body:JSON.stringify(args),signal:AbortSignal.timeout(15000)});const v=await r.json();if(!r.ok)throw Error(v.code==='P0001'?v.message:'서버 처리에 실패했습니다. 다시 시도해주세요.');return v;}
 const translation=createTranslation({rpc,fetcher});
 const autoMessages=createAutoMessages({rpc,credentials,api,saveBookings,messages,dispatchNotice:async id=>{const r=await fetcher(url()+'/functions/v1/dispatch-briefing',{method:'POST',headers:{'Content-Type':'application/json','x-webhook-secret':env('PUSH_ADMIN_SECRET')||''},body:JSON.stringify({message_id:id}),signal:AbortSignal.timeout(20000)});return r.ok&&(await r.json()).ok===true;}});
 const webCheckin=createWebCheckin({rpc,credentials,api,readDocument:createDocumentReader({rpc,fetcher})});
 const internal=(action,property,data={})=>rpc('online_internal',{p_action:action,p_property:property,p_data:data});
 const pinCtl=(action,property,data={})=>rpc('pin_delivery_internal',{p_action:action,p_property:property,p_data:data});
 const tokenProperties=new Map();
 const control=(action,property,data={})=>rpc('online_sync_control',{p_action:action,p_property:property,p_data:data});
 const owner=(token,action,data={})=>rpc('online_owner',{p_token:token,p_action:action,p_data:data});
 async function api(path,headers={},body,{method=body?'POST':'GET',confirmation}={}){
  const ordinary=method==='GET'||(method==='POST'&&['/bookings/messages','/authentication/setup'].includes(path));
  if(!ordinary||confirmation){
   if(!UUID.test(confirmation?.accessToken||'')||typeof confirmation.password!=='string'||!confirmation.password)
    throw Error('관리자 2차 비밀번호를 입력해주세요.');
   const verified=await rpc('verify_owner_sensitive_password',{p_access_token:confirmation.accessToken,p_password:confirmation.password});
   if(!verified?.ok)throw Error(verified?.message||'관리자 2차 비밀번호를 확인해주세요.');
  }
  const property=tokenProperties.get(headers.token||headers.refreshToken);
  if(property){const gate=await control('check',property);if(gate.skip){const e=Error('Beds24 요청 제한으로 동기화를 잠시 쉬고 있습니다.');e.status=429;throw e;}}
  const r=await fetcher(BASE+path,{method,headers:{accept:'application/json','Content-Type':'application/json',...headers},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(20000)});
  if(property&&(r.status===429||(r.headers.get('x-five-min-limit-remaining')!==null&&Number(r.headers.get('x-five-min-limit-remaining'))<=0))){const reset=Number(r.headers.get('x-five-min-limit-resets-in'))||Number(r.headers.get('retry-after'))||300;await control('cooldown',property,{seconds:Math.ceil(reset)+2});}
  let v;try{v=await r.json();}catch{throw Error('Beds24 응답을 확인하지 못했습니다.');}
  if(!r.ok||v?.success===false){const e=Error(r.status===429?'Beds24 요청 한도에 도달했습니다. 잠시 후 다시 시도해주세요.':r.status===401||r.status===403?'Beds24 연결 또는 API 권한을 확인해주세요.':'Beds24 요청에 실패했습니다. 연결 설정과 권한을 확인해주세요.');e.status=r.status;throw e;}
  return v;
 }
 async function pages(path,headers,onPage){
  let page=1;while(page<=100){const v=await api(path+(path.includes('?')?'&':'?')+'page='+page,headers);if(!Array.isArray(v.data))throw Error('Beds24 목록 형식을 확인하지 못했습니다.');await onPage(v.data);
   if(v.pages?.nextPageExists!==true) return;page++;
  }throw Error('조회량이 많습니다. 기간을 줄여주세요.');
 }
 async function credentials(property){
  const c=await internal('credentials',property);if(!c.secret?.refreshToken)throw Error('기본정보에서 Beds24를 먼저 연결해주세요.');
  tokenProperties.set(c.secret.refreshToken,property);if(c.secret.token)tokenProperties.set(c.secret.token,property);
  if(!c.secret.token||c.secret.expiresAt<Date.now()+60000){const t=await api('/authentication/token',{refreshToken:c.secret.refreshToken});if(!t.token)throw Error('Beds24 연결을 다시 확인해주세요.');c.secret={...c.secret,token:t.token,expiresAt:Date.now()+Math.max(60,Number(t.expiresIn)||3600)*1000};await internal('token',property,{secret:c.secret});}tokenProperties.set(c.secret.token,property);return c;
 }
 async function saveBookings(property,c,rows){
  const items=rows.map(selectBooking);
  // Booking totals use the property's configured currency, not the guest's country.
  // A missing financial permission must never turn an unknown total into zero.
  if(items.some(b=>b.price!==null)&&!Object.hasOwn(c,'bookingCurrency')){
   c.bookingCurrency=null;
   try{await pages('/properties?id='+positive(c.beds_property_id),{token:c.secret.token},props=>{
    const prop=props.find(p=>Number(p.id)===Number(c.beds_property_id));
    if(typeof prop?.currency==='string'&&/^[A-Z]{3}$/.test(prop.currency))c.bookingCurrency=prop.currency;
   });}catch{/* Keep the booking available even when currency metadata is unavailable. */}
  }
  await internal('bookings',property,{items:items.map(b=>({...b,currency:b.price!==null?c.bookingCurrency||null:null}))});
  const pins=rows.filter(b=>Array.isArray(b.infoItems)&&(c.password_source||'info:LOCK_PIN').startsWith('info:')&&(!b.infoItems.some(x=>x.code===(c.password_source||'info:LOCK_PIN').slice(5))||accessCode(b,{unit:{}},c.password_source||'info:LOCK_PIN'))).map(b=>({booking_id:b.id,pin:accessCode(b,{unit:{}},c.password_source||'info:LOCK_PIN')||null}));
  if(pins.length)await pinCtl('observe_batch',property,{items:pins});
 }
 async function booking(property,c,id){let found=false;const path='/bookings?id='+positive(id)+'&propertyId='+positive(c.beds_property_id)+'&includeInfoItems=true';const save=async rows=>{if(rows.some(b=>Number(b.propertyId)!==Number(c.beds_property_id)||Number(b.id)!==Number(id)))throw Error('숙소가 일치하지 않습니다.');if(rows.length){found=true;await saveBookings(property,c,rows);}};await pages(path,{token:c.secret.token},save);if(!found)await pages(path+'&status=cancelled',{token:c.secret.token},save);if(!found)throw Error('해당 숙소에서 예약을 찾지 못했습니다.');}
 async function messages(property,c,id,notify=false,maxAge=30){
  const bookingIds=new Set();
  await pages('/bookings/messages?propertyId='+positive(c.beds_property_id)+(id?'&bookingId='+positive(id):'&maxAge='+maxAge),{token:c.secret.token},async rows=>{
   if(rows.some(m=>Number(m.propertyId)!==Number(c.beds_property_id)||(id&&Number(m.bookingId)!==Number(id))))throw Error('메시지 숙소가 일치하지 않습니다.');
   rows.forEach(m=>bookingIds.add(positive(m.bookingId)));
   await internal('messages',property,{items:rows.map(selectMessage),notify});
  });
  if(!id){
   // API V2 declares array query parameters with form/explode serialization.
   const ids=await control('metadata_needed',property,{ids:[...bookingIds]});for(let offset=0;offset<ids.length;offset+=50){const batch=ids.slice(offset,offset+50),allowedIds=new Set(batch),query=new URLSearchParams({propertyId:String(c.beds_property_id)});batch.forEach(n=>query.append('id',String(n)));
    const found=new Set(),save=async rows=>{
     if(rows.some(b=>Number(b.propertyId)!==Number(c.beds_property_id)||!allowedIds.has(Number(b.id))))throw Error('예약 숙소 또는 번호가 일치하지 않습니다.');
     rows.forEach(b=>found.add(Number(b.id)));await saveBookings(property,c,rows);
    };
    await pages('/bookings?'+query,{token:c.secret.token},save);
    const missing=batch.filter(n=>!found.has(n));if(missing.length){const cancelled=new URLSearchParams({propertyId:String(c.beds_property_id),status:'cancelled'});missing.forEach(n=>cancelled.append('id',String(n)));await pages('/bookings?'+cancelled,{token:c.secret.token},save);}
   }
  }
 }
 async function push(property){
  const deadline=Date.now()+4000;
  for(const id of await internal('push_pending',property)){
   // Translation may fill the existing cache later, but must not indefinitely delay the alert.
   const work=(async()=>{try{const notice=await rpc('online_notice_translation',{p_property:property,p_notice:id});if(notice?.message_id)await translation.translate(property,{message_id:notice.message_id,direction:'incoming',automatic:true});}catch{}})();
   waitUntil(work);let timer;try{await Promise.race([work,new Promise(resolve=>{timer=setTimeout(resolve,Math.max(0,deadline-Date.now()));})]);}finally{clearTimeout(timer);}
   try{await fetcher(url()+'/functions/v1/dispatch-notification/online',{method:'POST',headers:{'Content-Type':'application/json','x-webhook-secret':env('PUSH_ADMIN_SECRET')||''},body:JSON.stringify({message_id:id}),signal:AbortSignal.timeout(12000)});}catch{/* push attempts are idempotent */}
  }
 }

 async function deliverMessage(connection,bookingId,body){
  let status='uncertain',error,result={};
    try{const v=await api('/bookings/messages',{token:connection.secret.token},[{bookingId,message:body}]);const rows=Array.isArray(v)?v:Array.isArray(v.data)?v.data:[];
     if(rows.length===1&&rows[0].success===true){status='sent';result={remote:rows[0].new||{}};}
     else if(rows.length&&rows.every(x=>x.success===false)){status='failed';error='Beds24에서 발송을 거절했습니다. 채널 지원 여부와 쓰기 권한을 확인해주세요.';}
     else error='발송 결과를 확정하지 못했습니다. 대화내역을 확인해주세요.';
    }catch(e){error=e.message;if(e.status>=400&&e.status<500)status='failed';}
  return {status,error,result};
 }
 async function autoReply(property,connection,bookingId){
  const generated=await draft(property,bookingId,'ai:automatic');
  if(!generated.automaticDraft)return;
  // Check the upstream conversation again after inference, in case a host or guest replied.
  await messages(property,connection,bookingId,true);
  const id=generated.automaticDraft;
  const prepared=await internal('prepare_auto_reply',property,{booking_id:bookingId,id});
  if(prepared.skip)return;
  const outcome=await deliverMessage(connection,bookingId,prepared.body);
  await internal('finish_send',property,{id,...outcome});
  if(outcome.status==='sent'){try{await messages(property,connection,bookingId,true);}catch{/* delivery was already recorded */}}
 }

 async function draft(property,id,actor){
  const job=await internal('draft_claim',property,{booking_id:positive(id),actor});if(job.skip)return {ok:true,skip:true};let result={id:job.id},attempted=false,received=false;
  try{
   if(job.has_attachment)throw Error('첨부파일은 관리자가 직접 확인해주세요.');
   const provider=await rpc('guest_ai_credentials',{});if(!provider?.enabled||!provider.key)throw Error('운영센터의 AI 연결 상태를 확인해주세요.');
   attempted=true;const r=await fetcher('https://api.openai.com/v1/responses',{method:'POST',headers:{Authorization:'Bearer '+provider.key,'Content-Type':'application/json'},body:JSON.stringify(buildRequest(job)),signal:AbortSignal.timeout(40000)});received=true;
   if(!r.ok){result.estimated=r.status>=500;throw Error('AI 서비스가 응답하지 않았습니다.');}
   result.estimated=true;const output=await r.json();const u=output.usage;
   result={...result,input_tokens:u?.input_tokens||0,output_tokens:u?.output_tokens||0,cached_tokens:u?.input_tokens_details?.cached_tokens||0,cache_write_tokens:u?.input_tokens_details?.cache_write_tokens||0,response_id:output.id,estimated:![u?.input_tokens,u?.output_tokens].every(n=>Number.isSafeInteger(n)&&n>=0)};
   if(output.status!=='completed')throw Error('AI 답변 생성이 완료되지 않았습니다.');
   const t=output.output?.filter(i=>i.type==='message').flatMap(i=>i.content||[]).filter(i=>i.type==='output_text').map(i=>i.text).join('');
   const parsed=JSON.parse(t);result={...result,...validateAnswer(parsed,job),parts:parsed.parts,data_revision:job.data_revision,sources:job.data.map(x=>({id:x.id,title:x.title})),model:'gpt-6-luna'};
  }catch(e){result.error=attempted?'AI 초안 생성 또는 검증 실패 · 직접 답변해주세요.':e.message;if(attempted&&!received)result.estimated=true;}
  const finished=await internal('draft_finish',property,result);
  if(actor==='ai:automatic'&&!finished.skip&&result.disposition==='answer'&&result.alert_kind==='none'){
   return {ok:true,automaticDraft:job.id};
  }
  return {ok:true};
 }
 async function handleJob(job){const p=job.property_id;try{const c=await credentials(p);await booking(p,c,job.booking_id);await messages(p,c,job.booking_id,true);if(c.ai_mode==='approval')await draft(p,job.booking_id,'webhook');else if(c.ai_mode==='automatic')await autoReply(p,c,job.booking_id);await push(p);await internal('synced',p);await internal('ack',p,job);}catch(e){await internal('ack',p,{...job,error:e.message});}}
 async function drain(){let bookingProperties=[];try{const v=await internal('booking_push_properties',null);if(Array.isArray(v))bookingProperties=v;}catch{}for(const p of new Set([...await internal('maintenance',null),...bookingProperties])){try{await credentials(p);await push(p);}catch{}}for(let i=0;i<4;i++){const job=await internal('claim',null);if(job.empty)break;await handleJob(job);}}
 return async req=>{
  const origin=req.headers.get('origin'),allowed=['https://omgworks24.com','https://www.omgworks24.com','https://omgseoul.github.io'];
  const cors={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin'};if(allowed.includes(origin))cors['Access-Control-Allow-Origin']=origin;
  const reply=(v,status=200)=>new Response(JSON.stringify(v),{status,headers:cors});
  if(origin&&!allowed.includes(origin))return reply({ok:false,message:'허용되지 않은 접속입니다.'},403);
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers:{...cors,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'content-type, apikey, authorization'}});
  const u=new URL(req.url);
  try{
   if(u.pathname.endsWith('/webhook')){
    if(req.method!=='POST')return reply({ok:false},405);
    const p=u.searchParams.get('property'),secret=u.searchParams.get('key');if(!UUID.test(p||'')||!/^[a-f0-9]{64}$/.test(secret||''))return reply({ok:false},401);
    const raw=await req.text();if(raw.length>1000000)return reply({ok:false},413);const payload=JSON.parse(raw);
    await internal('webhook',p,{key:secret,booking_id:positive(payload.booking?.id),event_kind:payload.message||payload.messages?'message':'booking'});waitUntil(drain());return reply({ok:true});
   }
   if(req.method!=='POST')return reply({ok:false},405);
   if(u.pathname.endsWith('/worker')){if(!await internal('worker_verify',null,{secret:req.headers.get('x-worker-secret')}))return reply({ok:false},401);waitUntil(Promise.all([drain(),autoMessages.drain()]));return reply({ok:true},202);}
   const reader=req.body?.getReader();if(!reader)return reply({ok:false},400);let size=0;const chunks=[];
   while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>5700000){await reader.cancel();return reply({ok:false,message:'첨부 이미지가 너무 큽니다.'},413);}chunks.push(value);}
   const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.byteLength;}
   const raw=new TextDecoder().decode(bytes),b=JSON.parse(raw),d=b.data||{};
   if(size>30000&&!(b.action==='auto_message_save'&&size<=300000)&&!(['web_checkin','web_checkin_preview'].includes(b.action)&&d.step==='upload'))return reply({ok:false},413);
   if(['web_checkin','web_checkin_preview','web_checkin_settings','web_checkin_save','web_checkin_diagnose'].includes(b.action))return reply(await webCheckin(b.action,d,b.access_token||null,req));
   if(b.platform_token){
    const r=await fetcher(url()+'/auth/v1/user',{headers:{apikey:key(),Authorization:'Bearer '+b.platform_token},signal:AbortSignal.timeout(10000)});
    const user=await r.json();if(!r.ok||!user.id)return reply({ok:false,message:'운영센터에 다시 로그인해주세요.'},401);
    await translation.ctl('platform_status',null,{},user.id);
    if(b.action==='translation_save')return reply(await translation.save(null,d.key,user.id));
    if(b.action==='translation_check')return reply(await translation.check(null,user.id));
    if(b.action==='translation_enabled')return reply(await translation.ctl('platform_enabled',null,d,user.id));
    if(b.action==='translation_status')return reply(await translation.ctl('platform_status',null,{},user.id));
    throw Error('지원하지 않는 운영센터 요청입니다.');
   }
   if(!UUID.test(b.access_token||''))return reply({ok:false,message:'관리자 로그인이 필요합니다.'},401);
   if(['auto_message_list','auto_message_save','auto_message_toggle','auto_message_retry'].includes(b.action))return reply(await rpc('auto_message_owner',{p_token:b.access_token,p_action:b.action.slice(13),p_data:d}));
   const a=await owner(b.access_token,'auth',{property_id:d.property_id,request_action:b.action==='booking_detail'?'booking_data':b.action==='pin_external'?'send':b.action}),p=a.property_id;
   const scoped=(action,data=d)=>owner(b.access_token,action,{...data,property_id:p});
   const requestedAction=b.action;
   if(b.action==='booking_detail'||b.action==='pin_external'){
    const id=positive(d.booking_id),c=await credentials(p);
    const path='/bookings?id='+id+'&propertyId='+positive(c.beds_property_id)+'&includeInfoItems=true';
    let v=await api(path,{token:c.secret.token});
    if(Array.isArray(v.data)&&!v.data.length)v=await api(path+'&status=cancelled',{token:c.secret.token});
    if(!Array.isArray(v.data)||v.data.length!==1)throw Error('예약 상세정보를 찾지 못했습니다.');
    const b=v.data[0];if(Number(b.id)!==id||Number(b.propertyId)!==Number(c.beds_property_id))throw Error('예약의 지점 또는 번호가 일치하지 않습니다.');
    const detail={id};for(const [key,field] of [['reference','apiReference'],['phone','phone'],['mobile','mobile']]){if(typeof b[field]==='string'&&b[field].trim())detail[key]=b[field].trim();}
    // Expose the same provider country used by automatic-message language selection.
    // Keep this live, owner-authorized detail out of the shared booking cache.
    const country=b.country2||b.country;if(typeof country==='string'&&country.trim())detail.country=country.trim();
    // Reservation-level PINs do not depend on the optional room inventory API.
    const source=c.password_source||'info:LOCK_PIN';
    const sources=[...new Set([source,'info:LOCK_PIN'])];
    for(const candidate of sources){
     if(candidate.startsWith('info:')){
      const items=(b.infoItems||[]).filter(i=>i.code===candidate.slice(5)&&(!i.bookingId||Number(i.bookingId)===id));
      if(!items.length)continue;
      const values=[...new Set(items.map(i=>typeof i.text==='string'?i.text.trim():''))];
      if(values.length===1&&/^[A-Za-z0-9*#-]{4,32}$/.test(values[0]))detail.password=values[0];
      else detail.warning='비밀번호의 중복 값 또는 형식을 확인해주세요.';
      break;
     }
     if(/^unit:name[2-8]$/.test(candidate)){
      try{const inv=await api('/properties?id='+positive(c.beds_property_id)+'&includeAllRooms=true&includeUnitDetails=true',{token:c.secret.token});
       const prop=inv.data?.find(x=>Number(x.id)===Number(c.beds_property_id)),pin=accessCode(b,prop&&assignedUnit(b,prop),candidate);
       if(pin){detail.password=pin;break;}
      }catch{detail.warning='객실 비밀번호 정보를 불러오지 못했습니다. 다시 확인해주세요.';}
     }
    }
    // Refresh only the existing booking allowlist; PINs and contact fields never enter the cache.
    await saveBookings(p,c,[b]);
    detail.price=selectBooking(b).price;detail.currency=detail.price!==null?c.bookingCurrency||null:null;
    if(requestedAction==='pin_external'&&(!detail.password||detail.password!==d.expected_password))throw Error('비밀번호가 변경되었거나 확인되지 않았습니다. 새로고침 후 전달한 번호를 확인해주세요.');
    if(!detail.warning){
     const tracked=await pinCtl(requestedAction==='pin_external'?'external':'observe',p,{booking_id:id,pin:detail.password||null,id:d.id,actor:a.actor,title:'직접 전달 완료'});
     detail.pin_delivery=tracked.pin_delivery;
    }else detail.pin_delivery=(await pinCtl('state',p,{booking_id:id})).pin_delivery;
    if(requestedAction==='pin_external'&&detail.warning)throw Error('비밀번호를 확인한 뒤 직접 전달 완료로 기록해주세요.');
    return reply({ok:true,detail});
   }
   if(b.action==='guest_settings')return reply(await scoped('guest_settings'));
   if(b.action==='settings'){const v=await scoped('settings'),t=await translation.ctl('status',p);return reply({...v,translation:t.usage,translation_connected:!!(t.usage?.platform_ready||t.usage?.personal_connected)});}
   if(['save_message_alert','save_message_alert_draft','save_auto_translation','booking_data','booking_data_count','save_booking_alert','save_settings','save_translation_language','reuse_connection','bookings','inbox','unread','save_period','read_message','peek_thread','webhook_logs','thread','logs','reject'].includes(b.action))return reply(await scoped(b.action));
   if(b.action==='save_translation')return reply(await translation.save(p,d.key));
   if(b.action==='check_translation')return reply(await translation.check(p));
   if(b.action==='remove_translation')return reply(await translation.ctl('remove_key',p));
   if(b.action==='translation_status')return reply(await translation.ctl('status',p));
   if(b.action==='translate')return reply(await translation.translate(p,{message_id:positive(d.message_id),direction:'incoming',automatic:d.automatic===true,...(d.target?{target:d.target}:{})}));
   if(b.action==='translate_reply')return reply(await translation.outgoing(p,{...d,booking_id:positive(d.booking_id)}));
   if(b.action==='connect'){
    if(typeof d.code!=='string'||d.code.trim().length<8||d.code.length>2048)throw Error('Beds24 Invite code를 입력해주세요.');
    const t=await api('/authentication/setup',{code:d.code.trim(),deviceName:'OMS Online'});if(!t.token||!t.refreshToken)throw Error('초대코드가 만료되었거나 이미 사용되었습니다. 새 코드를 발급해주세요.');
    const secret={token:t.token,refreshToken:t.refreshToken,expiresAt:Date.now()+(Number(t.expiresIn)||3600)*1000};
    // Persist exchanged credentials before a later property request can fail.
    await internal('connect',p,{secret,actor:a.actor});
    const props=[];await pages('/properties?includeAllRooms=true&includeUnitDetails=true',{token:t.token},async items=>props.push(...items.map(selectProperty)));await internal('connect',p,{secret,properties:props,actor:a.actor});return reply(await scoped('settings'));
   }
   if(['sync_messages','sync_bookings','sync_booking_data','sync_revenue'].includes(b.action)){
    const revenueSync=b.action==='sync_revenue',bookingData=b.action==='sync_booking_data',bookingsSync=b.action==='sync_bookings'||bookingData||revenueSync;if(bookingData)d.basis='booked';
    const id=b.action==='sync_messages'&&d.booking_id?positive(d.booking_id):null;
    if(revenueSync){if(a.kind!=='owner')throw Error('관리자 로그인이 필요합니다.');revenueImportRange(d);}else if(bookingsSync)dateRange(d);
    const scope=bookingsSync?'bookings:'+d.basis+':'+d.from+':'+d.to:id?'thread:'+id:'inbox',read=bookingData?'booking_data':bookingsSync?'bookings':id?'thread':'inbox';
    const claim=await control('begin',p,{scope});
    if(claim.skip&&revenueSync)return reply({ok:true,complete:false,cached:true,retry_at:claim.retry_at,warning:claim.limited?'Beds24 요청 제한으로 대기 중입니다.':'최근 조회 또는 처리 중인 요청이 있어 저장된 자료를 표시합니다.'});
    if(claim.skip)return reply({...await scoped(read),cached:true,retry_at:claim.retry_at,warning:claim.limited?'Beds24 요청 제한 · 저장된 내역을 표시합니다.':'최근 동기화 내역을 표시합니다.'});
    let success=false,warning;
    try{const c=await credentials(p);if(!c.beds_property_id)throw Error('기본정보에서 연동할 숙소를 선택하고 저장해주세요.');
     if(bookingsSync){
      let q='propertyId='+c.beds_property_id;const before=new Date(Date.parse(d.from)-86400000).toISOString().slice(0,10),after=new Date(Date.parse(d.to)+86400000).toISOString().slice(0,10);
      if(d.basis==='booked')q+='&bookingTimeFrom='+before+'T00:00:00&bookingTimeTo='+after+'T23:59:59';else if(d.basis==='staying')q+='&arrivalTo='+after+'&departureFrom='+before;else if(d.basis==='departure')q+='&departureFrom='+before+'&departureTo='+after;else q+='&arrivalFrom='+before+'&arrivalTo='+after;
      for(const suffix of ['', '&status=cancelled'])await pages('/bookings?'+q+suffix+'&includeInfoItems=true',{token:c.secret.token},rows=>{if(revenueSync&&rows.some(row=>Number(row.propertyId)!==Number(c.beds_property_id)))throw Error('예약 숙소가 일치하지 않습니다.');return saveBookings(p,c,rows);});
     }else{if(id)await booking(p,c,id);const age=claim.last_success?Math.min(30,Math.max(2,Math.ceil((Date.now()-Date.parse(claim.last_success))/86400000)+1)):30;await messages(p,c,id,true,age);}
     await push(p);await internal('synced',p);success=true;
    }catch(e){warning=e.message+' · 저장된 내역을 표시합니다.';}
    finally{await control('finish',p,{scope,lease:claim.lease,success});}
    if(revenueSync){const gate=success?{}:await control('check',p);return reply({ok:true,complete:success,cached:!success,property_id:p,from:d.from,to:d.to,...(gate.retry_at?{retry_at:gate.retry_at}:{}),...(warning?{warning}:{})});}
    return reply({...await scoped(read),cached:!success,...(warning?{warning}:{})});
   }
   const c=await credentials(p);
   if(b.action==='properties'){const props=[];await pages('/properties?includeAllRooms=true&includeUnitDetails=true',{token:c.secret.token},async items=>props.push(...items.map(selectProperty)));await internal('inventory',p,{properties:props});return reply(await scoped('settings'));}
   if(!c.beds_property_id)throw Error('기본정보에서 연동할 숙소를 선택하고 저장해주세요.');
   if(b.action==='draft'){const id=positive(d.booking_id);await booking(p,c,id);await messages(p,c,id,true);return reply(await draft(p,id,a.actor));}
   if(b.action==='send'){
    const id=positive(d.booking_id);if(!UUID.test(d.id||''))throw Error('발송 식별자가 올바르지 않습니다.');
    await booking(p,c,id);await messages(p,c,id,true);
    let sentPin;
    if(d.pin_notice){
     const live=await api('/bookings?id='+id+'&propertyId='+c.beds_property_id+'&includeInfoItems=true',{token:c.secret.token});
     const lb=live.data?.length===1&&live.data[0];if(!lb||Number(lb.id)!==id||Number(lb.propertyId)!==Number(c.beds_property_id))throw Error('예약정보를 확인하지 못했습니다.');
     const inv=await api('/properties?id='+c.beds_property_id+'&includeAllRooms=true&includeUnitDetails=true',{token:c.secret.token});
     const prop=inv.data?.find(x=>Number(x.id)===Number(c.beds_property_id));
     sentPin=accessCode(lb,prop&&assignedUnit(lb,prop),c.password_source||'info:LOCK_PIN');
     if(!includesPin(d.body||'',sentPin))throw Error('현재 비밀번호와 메시지 내용이 다릅니다. 예약정보를 새로고침해주세요.');
     await saveBookings(p,c,[lb]);
    }
    const prepared=await scoped('prepare_send');if(prepared.skip)return reply(prepared);
    if(sentPin)await pinCtl('begin',p,{booking_id:id,id:d.id,pin:sentPin,actor:a.actor,title:'비밀번호 보내기'});
    const {status,error,result}=await deliverMessage(c,id,d.body.trim());
    if(sentPin)await pinCtl('finish',p,{booking_id:id,id:d.id,status,error:status==='sent'?null:'발송 결과를 확인해주세요.'});
    await internal('finish_send',p,{id:d.id,status,error,result});if(status==='sent'){try{await messages(p,c,id,true);}catch{}}
    return reply({ok:true,status,error});
   }
   throw Error('지원하지 않는 요청입니다.');
  }catch(e){return reply({ok:false,message:e instanceof SyntaxError?'요청 형식을 확인해주세요.':e.message||'처리하지 못했습니다.'},400);}
 };
}
