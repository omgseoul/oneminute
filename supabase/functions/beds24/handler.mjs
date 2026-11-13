import {createTranslation} from './translation.mjs';
import {buildRequest,validateAnswer} from '../guest-ai/handler.mjs';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BASE='https://beds24.com/api/v2';
export function positive(v){const n=Number(v);if(!Number.isSafeInteger(n)||n<=0)throw Error('예약번호를 확인해주세요.');return n;}
export function dateRange(d){const valid=v=>/^\d{4}-\d{2}-\d{2}$/.test(v||'')&&new Date(v+'T00:00:00Z').toISOString().slice(0,10)===v;if(!valid(d.from)||!valid(d.to)||d.to<d.from||(Date.parse(d.to)-Date.parse(d.from))/86400000>92)throw Error('조회 기간은 최대 93일입니다.');if(!['arrival','booked','staying'].includes(d.basis))throw Error('조회 기준을 확인해주세요.');return d;}
export function selectBooking(b){return Object.fromEntries(['id','propertyId','roomId','roomName','unitId','firstName','lastName','arrival','departure','bookingTime','status','apiSource','referer','apiReference','numAdult','numChild','arrivalTime'].map(k=>[k,b[k]??null]));}
export function selectMessage(m){return Object.fromEntries(['id','bookingId','propertyId','source','message','time','attachmentName'].map(k=>[k,m[k]??null]));}
export function createBedsHandler({env,fetcher=fetch,waitUntil=p=>p.catch(()=>{})}){
 const url=()=>env('SUPABASE_URL'),key=()=>env('SUPABASE_SERVICE_ROLE_KEY');
 async function rpc(name,args){const r=await fetcher(url()+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:key(),Authorization:'Bearer '+key(),'Content-Type':'application/json'},body:JSON.stringify(args),signal:AbortSignal.timeout(15000)});const v=await r.json();if(!r.ok)throw Error(v.code==='P0001'?v.message:'서버 처리에 실패했습니다. 다시 시도해주세요.');return v;}
 const translation=createTranslation({rpc,fetcher});
 const internal=(action,property,data={})=>rpc('online_internal',{p_action:action,p_property:property,p_data:data});
 const tokenProperties=new Map();
 const control=(action,property,data={})=>rpc('online_sync_control',{p_action:action,p_property:property,p_data:data});
 const owner=(token,action,data={})=>rpc('online_owner',{p_token:token,p_action:action,p_data:data});
 async function api(path,headers={},body){
  const property=tokenProperties.get(headers.token||headers.refreshToken);
  if(property){const gate=await control('check',property);if(gate.skip){const e=Error('Beds24 요청 제한으로 동기화를 잠시 쉬고 있습니다.');e.status=429;throw e;}}
  const r=await fetcher(BASE+path,{method:body?'POST':'GET',headers:{accept:'application/json','Content-Type':'application/json',...headers},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(20000)});
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
 async function booking(property,c,id){let found=false;const path='/bookings?id='+positive(id)+'&propertyId='+positive(c.beds_property_id);const save=async rows=>{if(rows.some(b=>Number(b.propertyId)!==Number(c.beds_property_id)||Number(b.id)!==Number(id)))throw Error('숙소가 일치하지 않습니다.');if(rows.length){found=true;await internal('bookings',property,{items:rows.map(selectBooking)});}};await pages(path,{token:c.secret.token},save);if(!found)await pages(path+'&status=cancelled',{token:c.secret.token},save);if(!found)throw Error('해당 숙소에서 예약을 찾지 못했습니다.');}
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
     rows.forEach(b=>found.add(Number(b.id)));await internal('bookings',property,{items:rows.map(selectBooking)});
    };
    await pages('/bookings?'+query,{token:c.secret.token},save);
    const missing=batch.filter(n=>!found.has(n));if(missing.length){const cancelled=new URLSearchParams({propertyId:String(c.beds_property_id),status:'cancelled'});missing.forEach(n=>cancelled.append('id',String(n)));await pages('/bookings?'+cancelled,{token:c.secret.token},save);}
   }
  }
 }
 async function push(property){for(const id of await internal('push_pending',property)){try{await fetcher(url()+'/functions/v1/dispatch-notification/online',{method:'POST',headers:{'Content-Type':'application/json','x-webhook-secret':env('PUSH_ADMIN_SECRET')||''},body:JSON.stringify({message_id:id}),signal:AbortSignal.timeout(12000)});}catch{/* push attempts are idempotent */}}}
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
  await internal('draft_finish',property,result);return {ok:true};
 }
 async function handleJob(job){const p=job.property_id;try{const c=await credentials(p);await booking(p,c,job.booking_id);await messages(p,c,job.booking_id,true);await push(p);if(c.ai_mode==='approval')await draft(p,job.booking_id,'webhook');await internal('synced',p);await internal('ack',p,job);}catch(e){await internal('ack',p,{...job,error:e.message});}}
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
   if(u.pathname.endsWith('/worker')){if(!await internal('worker_verify',null,{secret:req.headers.get('x-worker-secret')}))return reply({ok:false},401);waitUntil(drain());return reply({ok:true},202);}
   const raw=await req.text();if(raw.length>30000)return reply({ok:false},413);const b=JSON.parse(raw),d=b.data||{};
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
   const a=await owner(b.access_token,'auth',{property_id:d.property_id}),p=a.property_id;
   const scoped=(action,data=d)=>owner(b.access_token,action,{...data,property_id:p});
   if(b.action==='settings'){const v=await scoped('settings'),t=await translation.ctl('status',p);return reply({...v,translation:t.usage,translation_connected:!!(t.usage?.platform_ready||t.usage?.personal_connected)});}
   if(['save_auto_translation','booking_data','booking_data_count','save_booking_alert','save_settings','save_translation_language','reuse_connection','bookings','inbox','unread','save_period','read_message','peek_thread','webhook_logs','thread','logs','reject'].includes(b.action))return reply(await scoped(b.action));
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
    const props=[];await pages('/properties?includeAllRooms=true',{token:t.token},async items=>props.push(...items.map(x=>({id:x.id,name:x.name,roomTypes:(x.roomTypes||[]).map(r=>({id:r.id,name:r.name,units:(r.units||[]).map(u=>({id:u.id,name:u.name}))}))}))));await internal('connect',p,{secret,properties:props,actor:a.actor});return reply(await scoped('settings'));
   }
   if(['sync_messages','sync_bookings','sync_booking_data'].includes(b.action)){
    const bookingData=b.action==='sync_booking_data',bookingsSync=b.action==='sync_bookings'||bookingData;if(bookingData)d.basis='booked';
    const id=b.action==='sync_messages'&&d.booking_id?positive(d.booking_id):null;
    if(bookingsSync)dateRange(d);
    const scope=bookingsSync?'bookings:'+d.basis+':'+d.from+':'+d.to:id?'thread:'+id:'inbox',read=bookingData?'booking_data':bookingsSync?'bookings':id?'thread':'inbox';
    const claim=await control('begin',p,{scope});
    if(claim.skip)return reply({...await scoped(read),cached:true,retry_at:claim.retry_at,warning:claim.limited?'Beds24 요청 제한 · 저장된 내역을 표시합니다.':'최근 동기화 내역을 표시합니다.'});
    let success=false,warning;
    try{const c=await credentials(p);if(!c.beds_property_id)throw Error('기본정보에서 연동할 숙소를 선택하고 저장해주세요.');
     if(bookingsSync){
      let q='propertyId='+c.beds_property_id;const before=new Date(Date.parse(d.from)-86400000).toISOString().slice(0,10),after=new Date(Date.parse(d.to)+86400000).toISOString().slice(0,10);
      if(d.basis==='booked')q+='&bookingTimeFrom='+before+'T00:00:00&bookingTimeTo='+after+'T23:59:59';else if(d.basis==='staying')q+='&arrivalTo='+after+'&departureFrom='+before;else q+='&arrivalFrom='+before+'&arrivalTo='+after;
      for(const suffix of ['', '&status=cancelled'])await pages('/bookings?'+q+suffix,{token:c.secret.token},rows=>internal('bookings',p,{items:rows.map(selectBooking)}));
     }else{if(id)await booking(p,c,id);const age=claim.last_success?Math.min(30,Math.max(2,Math.ceil((Date.now()-Date.parse(claim.last_success))/86400000)+1)):30;await messages(p,c,id,true,age);}
     await push(p);await internal('synced',p);success=true;
    }catch(e){warning=e.message+' · 저장된 내역을 표시합니다.';}
    finally{await control('finish',p,{scope,lease:claim.lease,success});}
    return reply({...await scoped(read),cached:!success,...(warning?{warning}:{})});
   }
   const c=await credentials(p);
   if(b.action==='properties'){const props=[];await pages('/properties?includeAllRooms=true',{token:c.secret.token},async items=>props.push(...items.map(x=>({id:x.id,name:x.name,roomTypes:(x.roomTypes||[]).map(r=>({id:r.id,name:r.name,units:(r.units||[]).map(u=>({id:u.id,name:u.name}))}))}))));await internal('connect',p,{secret:c.secret,properties:props,actor:a.actor});return reply(await scoped('settings'));}
   if(!c.beds_property_id)throw Error('기본정보에서 연동할 숙소를 선택하고 저장해주세요.');
   if(b.action==='draft'){const id=positive(d.booking_id);await booking(p,c,id);await messages(p,c,id,true);return reply(await draft(p,id,a.actor));}
   if(b.action==='send'){
    const id=positive(d.booking_id);if(!UUID.test(d.id||''))throw Error('발송 식별자가 올바르지 않습니다.');
    await booking(p,c,id);await messages(p,c,id,true);
    const prepared=await scoped('prepare_send');if(prepared.skip)return reply(prepared);
    let status='uncertain',error,result={};
    try{const v=await api('/bookings/messages',{token:c.secret.token},[{bookingId:id,message:d.body.trim()}]);const rows=Array.isArray(v)?v:Array.isArray(v.data)?v.data:[];
     if(rows.length===1&&rows[0].success===true){status='sent';result={remote:rows[0].new||{}};}
     else if(rows.length&&rows.every(x=>x.success===false)){status='failed';error='Beds24에서 발송을 거절했습니다. 채널 지원 여부와 쓰기 권한을 확인해주세요.';}
     else error='발송 결과를 확정하지 못했습니다. 대화내역을 확인해주세요.';
    }catch(e){error=e.message;if(e.status>=400&&e.status<500)status='failed';}
    await internal('finish_send',p,{id:d.id,status,error,result});if(status==='sent'){try{await messages(p,c,id,true);}catch{}}
    return reply({ok:true,status,error});
   }
   throw Error('지원하지 않는 요청입니다.');
  }catch(e){return reply({ok:false,message:e instanceof SyntaxError?'요청 형식을 확인해주세요.':e.message||'처리하지 못했습니다.'},400);}
 };
}
