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
export function renderAutoMessage(template,values){
 const text=String(template).replace(/\{\{([^{}]+)\}\}/g,(_,key)=>{
  if(!Object.hasOwn(values,key)||!String(values[key]??'').trim())throw Error(key+' 정보가 없어 발송을 대기합니다.');
  return String(values[key]);
 });
 if(!text.trim()||text.length>4000)throw Error('발송 내용은 1~4,000자여야 합니다.');
 return text;
}
export function createAutoMessages({rpc,credentials,api,saveBookings,messages}){
 const ctl=(action,data={})=>rpc('auto_message_internal',{p_action:action,p_data:data});
 async function process(job){
  const finish=(status,error)=>ctl('finish',{id:job.id,lease:job.lease,status,error});
  let attempted=false;
  try{
   if(!job.rule?.enabled)return await finish('skipped','설정이 중지되었습니다.');
   const c=await credentials(job.property_id);
   const v=await api('/bookings?id='+job.booking_id+'&propertyId='+c.beds_property_id+'&includeInfoItems=true',{token:c.secret.token});
   if(!Array.isArray(v.data))throw Error('예약정보를 확인하지 못했습니다.');
   if(v.data.length===0)return await finish('skipped','예약이 없거나 취소되었습니다.');
   if(v.data.length!==1||Number(v.data[0].id)!==Number(job.booking_id)||Number(v.data[0].propertyId)!==Number(c.beds_property_id))throw Error('예약의 지점이 일치하지 않습니다.');
   const b=v.data[0];await saveBookings(job.property_id,c,[b]);
   if(!['new','confirmed'].includes(b.status))return await finish('skipped','확정·신규 예약이 아닙니다.');
   const today=new Intl.DateTimeFormat('en-CA',{timeZone:job.timezone||'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
   if(b.departure<today)return await finish('skipped','체크아웃한 예약입니다.');
   const language=messageLanguage(b,job.rule.messages),template=job.rule.messages[language];
   let room='',pin='';
   if(template.includes('{{객실}}')||template.includes('{{비밀번호}}')){
    const inventory=await api('/properties?id='+c.beds_property_id+'&includeAllRooms=true&includeUnitDetails=true',{token:c.secret.token});
    const property=inventory.data?.find(p=>Number(p.id)===Number(c.beds_property_id));
    const assigned=property&&assignedUnit(b,property);
    room=assigned?.unit?.name||'';pin=accessCode(b,assigned,'info:LOCK_PIN')||'';
   }
   const body=renderAutoMessage(template,{'이름':((b.firstName||'')+' '+(b.lastName||'')).replace(/[\d\uFF10-\uFF19]/g,'').replace(/\s+/g,' ').trim(),
    '체크인':b.arrival,'체크아웃':b.departure,'객실':room,'비밀번호':pin});
   const ready=await ctl('prepare',{id:job.id,lease:job.lease,language});if(ready.skip)return;
   attempted=true;
   const response=await api('/bookings/messages',{token:c.secret.token},[{bookingId:job.booking_id,message:body}]);
   const rows=Array.isArray(response)?response:response.data;
   if(rows?.length===1&&rows[0].success===true){
    await finish('sent');try{await messages(job.property_id,c,job.booking_id,false);}catch{}
   }else if(rows?.length&&rows.every(r=>r.success===false))await finish('failed','예약 채널에서 발송을 거절했습니다. 채널 지원·쓰기 권한을 확인해주세요.');
   else await finish('uncertain','발송 결과 확인 필요 · 게스트 대화를 확인해주세요.');
  }catch(e){
   await finish(attempted?(e.status>=400&&e.status<500?'failed':'uncertain'):'waiting',attempted?'발송 결과를 게스트 대화에서 확인해주세요.':e.message);
  }
 }
 async function drain(){for(let i=0;i<4;i++){const job=await ctl('claim');if(job.empty)break;await process(job);}}
 return {drain,process};
}
