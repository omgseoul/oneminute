import {accessCode,assignedUnit} from './web-checkin.mjs';

// Nationality/country is explicit provider metadata; never guess from guest names.
export function messageLanguage(booking,messages){
 const country=String(booking.country2||booking.country||'').trim().toUpperCase();
 const groups={ja:['JP','JAPAN','日本','일본'],ko:['KR','KOREA','SOUTH KOREA','REPUBLIC OF KOREA','대한민국'],
  'zh-CN':['CN','CHINA'],'zh-TW':['TW','TAIWAN','HK','HONG KONG','MO','MACAO'],
  en:['US','USA','UNITED STATES','GB','UK','UNITED KINGDOM','AU','AUSTRALIA','CA','CANADA','NZ','NEW ZEALAND','IE','IRELAND'],
  fr:['FR','FRANCE'],de:['DE','GERMANY','AT','AUSTRIA'],es:['ES','SPAIN','MX','MEXICO','AR','ARGENTINA','CO','COLOMBIA','CL','CHILE','PE','PERU'],
  it:['IT','ITALY'],pt:['PT','PORTUGAL','BR','BRAZIL'],ru:['RU','RUSSIA'],th:['TH','THAILAND'],vi:['VN','VIETNAM'],id:['ID','INDONESIA']};
 const language=Object.entries(groups).find(([,countries])=>countries.includes(country))?.[0];
 return language&&messages[language]?.trim()?language:'common';
}
class MessageValidationError extends Error {}
// Beds24 channel messaging support: https://wiki.beds24.com/index.php/Messages
// Source IDs: https://wiki.beds24.com/index.php/API_V2.0_apisourceids
export function supportsAutoMessageChannel(booking){
 const sourceId=booking.apiSourceId;
 if(sourceId!==undefined&&sourceId!==null&&String(sourceId).trim()!=='')return [14,19,30,46].includes(Number(sourceId));
 const source=String(booking.apiSource||'').toLowerCase().replace(/[^a-z0-9]/g,'');
 return ['airbnb','airbnbxml','booking','bookingcom','expedia','vrbo','homeaway','homeawayxml','abritel','fewodirekt','stayz'].includes(source);
}
export function includesPin(body,pin){return !!pin&&new RegExp('(^|[^A-Za-z0-9*#-])'+pin.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'($|[^A-Za-z0-9*#-])').test(body.replace(/https?:\/\/\S+/gi,''));}
function templateVariables(template){
 if(typeof template!=='string'||!template.trim())throw new MessageValidationError('발송할 메시지 내용이 없습니다.');
 const keys=[...new Set([...template.matchAll(/\{\{([^{}]+)\}\}/g)].map(m=>m[1]))];
 if(keys.some(k=>!['이름','체크인','체크아웃','객실','비밀번호'].includes(k))||/\{\{|\}\}/.test(template.replace(/\{\{([^{}]+)\}\}/g,'')))
  throw new MessageValidationError('자동 입력 변수 형식이 잘못되었거나 지원하지 않는 변수입니다. 메시지 설정을 확인해주세요.');
 return keys;
}
export function renderAutoMessage(template,values){
 const missing=templateVariables(template).filter(key=>{
  const value=values[key];
  if(!Object.hasOwn(values,key)||!['string','number'].includes(typeof value)||!String(value).trim()||(typeof value==='number'&&!Number.isFinite(value)))return true;
  if(key==='체크인'||key==='체크아웃')return !/^\d{4}-\d{2}-\d{2}$/.test(value)||!Number.isFinite(Date.parse(value))||new Date(value).toISOString().slice(0,10)!==value;
  return false;
 });
 if(missing.length)throw new MessageValidationError('필수 정보가 없거나 확인되지 않았습니다: '+missing.join(', ')+'. 발송하지 않았습니다.');
 const text=template.replace(/\{\{([^{}]+)\}\}/g,(_,key)=>String(values[key]));
 if(!text.trim()||text.length>4000)throw new MessageValidationError('발송 내용은 1~4,000자여야 합니다.');
 return text;
}
export function createAutoMessages({rpc,credentials,api,saveBookings,messages,dispatchNotice=async()=>false}){
 const ctl=(action,data={})=>rpc('auto_message_internal',{p_action:action,p_data:data});
 async function process(job){
  const finish=(status,error)=>ctl('finish',{id:job.id,lease:job.lease,status:job.manual_retry&&status==='skipped'?'failed':status,error});
  let attempted=false,stage='Beds24 연결정보 확인';
  try{
   if(!job.rule?.enabled)return await finish('skipped','자동 발송 설정이 중지되었습니다.');
   const c=await credentials(job.property_id);
   stage='예약정보 조회';
   const v=await api('/bookings?id='+job.booking_id+'&propertyId='+c.beds_property_id+'&includeInfoItems=true',{token:c.secret.token});
   if(!Array.isArray(v.data)||v.data.length===0)throw new MessageValidationError('예약정보를 조회하지 못했습니다. 예약 연동 상태를 확인해주세요.');
   if(v.data.length!==1||Number(v.data[0].id)!==Number(job.booking_id)||Number(v.data[0].propertyId)!==Number(c.beds_property_id))throw new MessageValidationError('예약의 지점이 일치하지 않습니다.');
   const b=v.data[0];stage='예약정보 동기화';await saveBookings(job.property_id,c,[b]);
   if(!['new','confirmed'].includes(b.status))return await finish('skipped','확정·신규 예약이 아닙니다.');
   const today=new Intl.DateTimeFormat('en-CA',{timeZone:job.timezone||'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
   if(b.departure<today)return await finish('skipped','체크아웃한 예약입니다.');
   if(!supportsAutoMessageChannel(b))throw new MessageValidationError('Beds24 메시지 연동을 지원하지 않거나 확인할 수 없는 예약사이트입니다. 게스트에게 발송되지 않았습니다. 해당 예약사이트에서 수동으로 확인해주세요.');
   const language=messageLanguage(b,job.rule.messages||{}),template=job.rule.messages?.[language],keys=templateVariables(template);
   let room='',pin='';
   if(keys.includes('객실')||keys.includes('비밀번호')||job.rule.pin_notice){
    stage='객실·비밀번호 조회';
    const inventory=await api('/properties?id='+c.beds_property_id+'&includeAllRooms=true&includeUnitDetails=true',{token:c.secret.token});
    const property=Array.isArray(inventory.data)&&inventory.data.find(p=>Number(p.id)===Number(c.beds_property_id));
    if(!property)throw new MessageValidationError('객실·비밀번호 조회 실패: 숙소정보를 확인하지 못했습니다.');
    const assigned=property&&assignedUnit(b,property);
    room=assigned?.unit?.name||'';pin=accessCode(b,assigned,c.password_source||'info:LOCK_PIN')||'';
   }
   const body=renderAutoMessage(template,{'이름':[b.firstName,b.lastName].filter(v=>typeof v==='string').join(' ').replace(/[\d\uFF10-\uFF19]/g,'').replace(/\s+/g,' ').trim(),
    '체크인':b.arrival,'체크아웃':b.departure,'객실':room,'비밀번호':pin});
   stage='발송 조건 재확인';
   const ready=await ctl('prepare',{id:job.id,lease:job.lease,language,...((job.rule.pin_notice||keys.includes('비밀번호'))&&includesPin(body,pin)?{pin}:{})});if(ready?.skip)return;
   if(ready?.ok!==true)throw new MessageValidationError('최종 발송 조건을 확인하지 못해 발송하지 않았습니다.');
   attempted=true;
   const response=await api('/bookings/messages',{token:c.secret.token},[{bookingId:job.booking_id,message:body}]);
   const rows=Array.isArray(response)?response:response.data;
   if(rows?.length===1&&rows[0].success===true){
    await finish('sent');try{await messages(job.property_id,c,job.booking_id,false);}catch{}
   }else if(rows?.length&&rows.every(r=>r.success===false))await finish('failed','예약사이트에서 메시지 전송을 거절했습니다. Beds24 메시지 연동·쓰기 권한을 확인하고 해당 예약사이트에서 수동으로 확인해주세요.');
   else await finish('uncertain','발송 결과 확인 필요 · 게스트 대화를 확인해주세요.');
  }catch(e){
   // Provider errors may contain tokens, PINs or message bodies: record only controlled reasons.
   const denied=e.status>=400&&e.status<500;
   const reason=e.status===401||e.status===403?'연동 인증 또는 조회 권한을 확인해주세요.':e.status===429?'Beds24 요청 한도를 초과했습니다.':e.status>=400&&e.status<=599?'Beds24 HTTP '+e.status+' 오류입니다.':'연결이 끊겼거나 응답을 확인하지 못했습니다.';
   await finish(attempted?(denied?'failed':'uncertain'):'failed',attempted?(denied?'메시지 발송 거절: '+reason:'전송 중 응답이 끊겨 발송 성공 여부를 확인하지 못했습니다.'):(e instanceof MessageValidationError?e.message:stage+' 실패: '+reason));
  }
 }
 async function drain(){try{for(let i=0;i<4;i++){const job=await ctl('claim');if(job.empty)break;await process(job);}}finally{for(const notice of await ctl('pushes')){try{if(await dispatchNotice(notice.message_id))await ctl('pushed',{id:notice.id});}catch{/* Keep pending; push transport deduplicates by message and recipient. */}}}}
 return {drain,process};
}
