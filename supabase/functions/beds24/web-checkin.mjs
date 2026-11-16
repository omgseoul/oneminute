// Door codes stay in the provider response and are never persisted with ordinary bookings.
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const validDate=v=>typeof v==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(v)&&Number.isFinite(Date.parse(v+'T00:00:00Z'))&&new Date(v+'T00:00:00Z').toISOString().slice(0,10)===v;
const norm=v=>String(v??'').normalize('NFKD').replace(/\p{M}/gu,'').toLocaleLowerCase('en').replace(/[^\p{L}\p{N}]/gu,'');
const reference=v=>String(v??'').normalize('NFKC').trim().toUpperCase().replace(/[\s-]/g,'');
export function similarity(a,b){
 const x=Array.from(norm(a)),y=Array.from(norm(b));if(x.length<2||y.length<2)return 0;
 let row=Array.from({length:y.length+1},(_,i)=>i);
 for(let i=0;i<x.length;i++){const next=[i+1];for(let j=0;j<y.length;j++)next.push(Math.min(next[j]+1,row[j+1]+1,row[j]+(x[i]===y[j]?0:1)));row=next;}
 return 1-row[y.length]/Math.max(x.length,y.length);
}
export function matchingBookings(rows,input,property,today){
 const ref=reference(input.reference);
 if(!validDate(input.check_in)||!validDate(input.check_out)||input.check_in!==today||input.check_out<=input.check_in||Date.parse(input.check_out)-Date.parse(input.check_in)>93*86400000||typeof input.name!=='string'||input.name.length>100||norm(input.name).length<2||ref.length<5||ref.length>80)return [];
 return rows.filter(b=>Number(b.propertyId)===Number(property)&&['new','confirmed'].includes(b.status)&&b.arrival===input.check_in&&b.departure===input.check_out&&Number(b.roomQty||1)===1&&[b.id,b.apiReference].some(x=>x!=null&&reference(x)===ref)&&Math.max(similarity(input.name,[b.firstName,b.lastName].filter(Boolean).join(' ')),similarity(input.name,[b.lastName,b.firstName].filter(Boolean).join(' ')))>=.95);
}
export function assignedUnit(booking,property){
 if(Number(booking.propertyId)!==Number(property.id))return null;
 const rooms=(property.roomTypes||[]).filter(r=>Number(r.id)===Number(booking.roomId));if(rooms.length!==1)return null;
 const units=(rooms[0].units||[]).filter(u=>Number(u.id)===Number(booking.unitId));if(units.length!==1||!String(units[0].name||'').trim())return null;
 return {room:rooms[0],unit:units[0]};
}
const cleanCode=value=>typeof value==='string'&&/^[A-Za-z0-9*#-]{4,32}$/.test(value.trim())?value.trim():null;
export function accessCode(booking,assigned,source){
 if(!assigned)return null;
 if(/^unit:name[2-8]$/.test(source||''))return cleanCode(assigned.unit[source.slice(5)]);
 if(/^info:[A-Za-z0-9_-]{1,60}$/.test(source||'')){
  const entries=(booking.infoItems||[]).filter(x=>x.code===source.slice(5)&&(!x.bookingId||Number(x.bookingId)===Number(booking.id)));
  // Conflicting historical items must be reviewed, not guessed.
  const codes=[...new Set(entries.map(x=>cleanCode(x.text)))];return codes.length===1?codes[0]:null;
 }
 return null;
}
export function diagnostic(rows,property,day){
 const active=rows.filter(b=>Number(b.propertyId)===Number(property.id)&&b.arrival===day&&['new','confirmed'].includes(b.status)),sources=new Map();let assigned=0;
 for(const b of active){const unit=assignedUnit(b,property);if(unit)assigned++;
  const keys=new Set((b.infoItems||[]).filter(x=>/^[A-Za-z0-9_-]{1,60}$/.test(x.code||'')).map(x=>'info:'+x.code));for(let i=2;i<=8;i++)keys.add('unit:name'+i);
  for(const source of keys)if(accessCode(b,unit,source))sources.set(source,(sources.get(source)||0)+1);
 }
 return {day,bookings:active.length,assigned,sources:[...sources].map(([source,count])=>({source,count})).sort((a,b)=>a.source.localeCompare(b.source))};
}
export function createWebCheckin({rpc,credentials,api,cryptoApi=crypto}){
 const failure=()=>({ok:false,code:'not_verified',message:'예약 정보를 확인하지 못했습니다. 예약확인서의 이름·날짜·예약번호를 확인하거나 직원에게 문의해주세요.'});
 async function inventory(c){const result=await api('/properties?id='+c.beds_property_id+'&includeAllRooms=true&includeUnitDetails=true',{token:c.secret.token});const props=(result.data||[]).filter(p=>Number(p.id)===Number(c.beds_property_id));if(props.length!==1)throw Error('객실 배정 정보를 확인하지 못했습니다. 직원에게 문의해주세요.');return props[0];}
 async function arrivals(c,day){const rows=[];for(let page=1;page<=3;page++){const result=await api('/bookings?propertyId='+c.beds_property_id+'&arrival='+day+'&includeInfoItems=true&page='+page,{token:c.secret.token});if(!Array.isArray(result.data)||result.data.some(b=>Number(b.propertyId)!==Number(c.beds_property_id)))throw Error('예약 정보를 확인하지 못했습니다.');rows.push(...result.data);if(!result.pages?.nextPageExists)return rows;}throw Error('직원에게 체크인 확인을 요청해주세요.');}
 return async(action,data,token,req)=>{
  if(action==='web_checkin_diagnose'){
   const gate=await rpc('web_checkin_admin',{p_token:token,p_action:'probe',p_data:{}}),c=await credentials(gate.property_id),rows=await arrivals(c,gate.day),property=await inventory(c),summary=diagnostic(rows,property,gate.day);
   await rpc('web_checkin_admin',{p_token:token,p_action:'record_probe',p_data:summary});return {ok:true,...summary};
  }
  if(action==='web_checkin_settings'||action==='web_checkin_save')return rpc('web_checkin_admin',{p_token:token,p_action:action==='web_checkin_save'?'save':'read',p_data:data});
  if(action!=='web_checkin')throw Error('지원하지 않는 요청입니다.');
  if(!UUID.test(data.slug||''))return failure();
  const addr=req.headers.get('x-forwarded-for')?.split(',')[0]?.trim();if(!addr)return failure();
  const bytes=await cryptoApi.subtle.digest('SHA-256',new TextEncoder().encode(addr));const ip=[...new Uint8Array(bytes)].map(x=>x.toString(16).padStart(2,'0')).join('');
  const gate=await rpc('web_checkin_gate',{p_slug:data.slug,p_ip_hash:ip});if(!gate.ok)return gate;
  // Input cannot control property scope, current day, release time or source field.
  if(!validDate(data.check_in)||data.check_in!==gate.day||!validDate(data.check_out)||typeof data.name!=='string'||data.name.length>100||typeof data.reference!=='string'||data.reference.length>80)return failure();
  const c=await credentials(gate.property_id);if(Number(c.beds_property_id)!==Number(gate.beds_property_id))return failure();
  const matches=matchingBookings(await arrivals(c,gate.day),data,c.beds_property_id,gate.day);if(matches.length!==1)return failure();
  const property=await inventory(c),original=matches[0];
  const fresh=await api('/bookings?propertyId='+c.beds_property_id+'&id='+original.id+'&includeInfoItems=true',{token:c.secret.token});
  const current=matchingBookings(fresh.data||[],data,c.beds_property_id,gate.day);if(current.length!==1||Number(current[0].id)!==Number(original.id))return failure();
  const assigned=assignedUnit(current[0],property),code=accessCode(current[0],assigned,gate.source);
  if(!code)return {ok:false,code:'staff_required',message:'직원이 객실 배정과 출입 정보를 확인해야 합니다. 직원과의 채팅으로 문의해주세요.'};
  // Recheck current enablement/time immediately before disclosing access details.
  const allowed=await rpc('web_checkin_release',{p_property:gate.property_id,p_source:gate.source,p_day:gate.day});if(!allowed)return failure();
  return {ok:true,property:gate.name,room:String(assigned.unit.name).slice(0,80),access_code:code,check_in:current[0].arrival,check_out:current[0].departure};
 };
}
