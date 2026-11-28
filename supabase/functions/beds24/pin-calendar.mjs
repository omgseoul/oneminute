// Calendar evidence is independent from guest delivery. Retrying this outbox never
// posts a guest message and never removes another system's booking info items.
import {accessCode,assignedUnit} from './web-checkin.mjs';
export function isPinSentWrite(path,body){
 return path==='/bookings'&&Array.isArray(body)&&body.length===1&&Object.keys(body[0]).sort().join(',')==='id,infoItems'
  &&Number.isSafeInteger(body[0].id)&&body[0].id>0&&Array.isArray(body[0].infoItems)&&body[0].infoItems.length===1
  &&Object.keys(body[0].infoItems[0]).sort().join(',')==='code,text'&&body[0].infoItems[0].code==='PINSENT'&&body[0].infoItems[0].text==='OMS 비밀번호 발송 완료';
}
export function createPinCalendar({rpc,credentials,api,saveBookings}){
 const ctl=(action,data={})=>rpc('pin_calendar_internal',{p_action:action,p_data:data});
 async function process(job){
  try{
   const c=await credentials(job.property_id),path='/bookings?id='+job.booking_id+'&propertyId='+c.beds_property_id+'&includeInfoItems=true';
   const read=async()=>{const v=await api(path,{token:c.secret.token}),b=v.data?.length===1&&v.data[0];if(!b||Number(b.id)!==Number(job.booking_id)||Number(b.propertyId)!==Number(c.beds_property_id))throw Error('예약 확인 실패');return b;};
   const b=await read();await saveBookings(job.property_id,c,[b]);
   const source=c.password_source||'info:LOCK_PIN';let assigned={unit:{}};
   if(!source.startsWith('info:')){
    const inv=await api('/properties?id='+c.beds_property_id+'&includeAllRooms=true&includeUnitDetails=true',{token:c.secret.token});
    const property=inv.data?.find(p=>Number(p.id)===Number(c.beds_property_id));
    if(!property)throw Error('객실 확인 실패');assigned=assignedUnit(b,property);
   }
   const pin=accessCode(b,assigned,source);if(!pin)throw Error('현재 비밀번호 확인 실패');
   await rpc('pin_delivery_internal',{p_action:'observe',p_property:job.property_id,p_data:{booking_id:job.booking_id,pin}});
   const valid=await ctl('verify',job);if(valid?.ok!==true)return;
   const marked=b=>(b.infoItems||[]).some(x=>x.code==='PINSENT'&&(!x.bookingId||Number(x.bookingId)===Number(job.booking_id)));
   if(!marked(b)){
    await api('/bookings',{token:c.secret.token},[{id:Number(job.booking_id),infoItems:[{code:'PINSENT',text:'OMS 비밀번호 발송 완료'}]}],{pinSent:true});
    if(!marked(await read()))throw Error('캘린더 표시 확인 실패');
   }
   await ctl('finish',{...job,status:'done'});
  }catch{await ctl('finish',{...job,status:'pending'});}
 }
 async function drain(){for(let i=0;i<4;i++){const job=await ctl('claim');if(job?.empty||!job?.booking_id)return;await process(job);}}
 return {drain,process};
}
