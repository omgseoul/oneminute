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
export const nameScore=(name,b)=>Math.max(similarity(name,[b.firstName,b.lastName].filter(Boolean).join(' ')),similarity(name,[b.lastName,b.firstName].filter(Boolean).join(' ')));
export function referenceScore(value,b){
 const ref=reference(value),ota=reference(b.apiReference);
 // Sequential internal IDs are never fuzzy matched.
 if(ref===reference(b.id))return 1;
 if(!ota||ref.length<6)return 0;
 return similarity(ref,ota);
}
export function matchingBookings(rows,input,property,today,additional=false){
 const ref=reference(input.reference);
 if(!validDate(input.check_in)||!validDate(input.check_out)||input.check_in!==today||input.check_out<=input.check_in||Date.parse(input.check_out)-Date.parse(input.check_in)>93*86400000||typeof input.name!=='string'||input.name.length>100||norm(input.name).length<2||ref.length<5||ref.length>80)return [];
 return rows.filter(b=>Number(b.propertyId)===Number(property)&&['new','confirmed'].includes(b.status)&&b.arrival===input.check_in&&b.departure===input.check_out&&Number(b.roomQty||1)===1&&(additional?(referenceScore(ref,b)>=.9||(nameScore(input.name,b)>=.95&&referenceScore(ref,b)>=.7)):(referenceScore(ref,b)>=.9&&nameScore(input.name,b)>=.95)));
}
const randomInt=(max,c)=>{const n=new Uint32Array(1),limit=Math.floor(4294967296/max)*max;do{c.getRandomValues(n);}while(n[0]>=limit);return n[0]%max;};
export function shuffle(items,c=crypto){const out=[...items];for(let i=out.length-1;i>0;i--){const j=randomInt(i+1,c);[out[i],out[j]]=[out[j],out[i]];}return out;}
export function nameChoices(b,c=crypto){
 const raw=[b.firstName,b.lastName].filter(Boolean).join(' ').normalize('NFC').trim().replace(/\s+/g,' ');
 const label=/^[\p{Script=Latin}\p{M}\s.'’-]+$/u.test(raw)?raw.normalize('NFKD').replace(/\p{M}/gu,'').toUpperCase():raw;
 let generate;const pick=a=>a[randomInt(a.length,c)],latinFirst='ALEX MORGAN JAMIE TAYLOR ROBIN CHARLIE CAMERON JORDAN SAM RILEY DREW CASEY AVERY QUINN ROWAN JESSE'.split(' '),latinLast='MARTIN WILSON PARKER TURNER WALKER CLARK MILLER HALL ALLEN YOUNG KING SCOTT BROWN EVANS REED BELL'.split(' ');
 if(/^[A-Z\s.'’-]+$/.test(label)){const parts=label.split(' ');generate=()=>parts.map((_,i)=>pick(i===parts.length-1?latinLast:latinFirst)).join(' ');}
 else if(/^[\p{Script=Hangul}\s]+$/u.test(label))generate=()=>Array.from(label).map((x,i)=>x===' '?' ':pick(Array.from(i===0?'김이박최정강조윤장임한오서신권황':'서민지준현수연우정하은유영진다성'))).join('');
 else if(/^[\p{Script=Han}\s]+$/u.test(label))generate=()=>Array.from(label).map((x,i)=>x===' '?' ':pick(Array.from(i===0?'王李張劉陳楊黃趙周吳徐孫胡朱高林':'明華文麗英美俊秀傑芳雲宇涵浩怡安'))).join('');
 else if(/^[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\sー]+$/u.test(label))generate=()=>Array.from(label).map(x=>x===' '?' ':pick(Array.from(/\p{Script=Hiragana}/u.test(x)?'あいうえおかきくけこさしすせそたちつてとなにぬねのまみむめもやゆよりるれろ':/\p{Script=Katakana}/u.test(x)?'アイウエオカキクケコサシスセソタチツテトナニヌネノマミムメモヤユヨリルレロ':'山田中川村林木本井藤佐高小大松島原'))).join('');
 else if(/^[\p{Script=Cyrillic}\s]+$/u.test(label))generate=()=>label.split(' ').map((_,i)=>pick((i?'Иванов Петров Соколов Смирнов Волков Морозов Новиков Козлов':'Алексей Иван Дмитрий Сергей Андрей Максим Павел Виктор').split(' '))).join(' ');
 else return null;
 const labels=new Set([label]);for(let i=0;labels.size<15&&i<500;i++)labels.add(generate());if(labels.size!==15)return null;
 const options=[...labels].map(label=>({id:c.randomUUID(),label}));return {correct_id:options[0].id,options:shuffle(options,c)};
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
 return {day,bookings:active.length,assigned,sources:[...sources].map(([source,count])=>({source,count})).sort((a,b)=>a.source.localeCompare(b.source)),reservations:active.slice(0,100).map(b=>({booking_id:String(b.id),reference:String(b.apiReference||''),name:[b.firstName,b.lastName].filter(Boolean).join(' ').slice(0,100),check_in:b.arrival,check_out:b.departure})),truncated:active.length>100};
}
export function createWebCheckin({rpc,credentials,api,cryptoApi=crypto}){
 const failure=()=>({ok:false,code:'not_verified',message:'입력한 정보만으로 예약을 확정하지 못했습니다. 예약확인서를 다시 확인하거나 직원과의 채팅으로 추가 확인을 요청해주세요.'});
 async function inventory(c){const result=await api('/properties?id='+c.beds_property_id+'&includeAllRooms=true&includeUnitDetails=true',{token:c.secret.token});const props=(result.data||[]).filter(p=>Number(p.id)===Number(c.beds_property_id));if(props.length!==1)throw Error('객실 배정 정보를 확인하지 못했습니다. 직원에게 문의해주세요.');return props[0];}
 async function arrivals(c,day){const rows=[];for(let page=1;page<=3;page++){const result=await api('/bookings?propertyId='+c.beds_property_id+'&arrival='+day+'&includeInfoItems=true&page='+page,{token:c.secret.token});if(!Array.isArray(result.data)||result.data.some(b=>Number(b.propertyId)!==Number(c.beds_property_id)))throw Error('예약 정보를 확인하지 못했습니다.');rows.push(...result.data);if(!result.pages?.nextPageExists)return rows;}throw Error('직원에게 체크인 확인을 요청해주세요.');}
 return async(action,data,token,req)=>{
  if(action==='web_checkin_diagnose'){
   const gate=await rpc('web_checkin_admin',{p_token:token,p_action:'probe',p_data:{}}),c=await credentials(gate.property_id),rows=await arrivals(c,gate.day),property=await inventory(c),summary=diagnostic(rows,property,gate.day);
   const {reservations,truncated,...counts}=summary;await rpc('web_checkin_admin',{p_token:token,p_action:'record_probe',p_data:counts});return {ok:true,...summary};
  }
  if(action==='web_checkin_settings'||action==='web_checkin_save')return rpc('web_checkin_admin',{p_token:token,p_action:action==='web_checkin_save'?'save':'read',p_data:data});
  if(action!=='web_checkin')throw Error('지원하지 않는 요청입니다.');
  if(!UUID.test(data.slug||''))return failure();
  const addr=req.headers.get('x-forwarded-for')?.split(',')[0]?.trim();if(!addr)return failure();
  const bytes=await cryptoApi.subtle.digest('SHA-256',new TextEncoder().encode(addr));const ip=[...new Uint8Array(bytes)].map(x=>x.toString(16).padStart(2,'0')).join('');
  const gate=await rpc('web_checkin_gate',{p_slug:data.slug,p_ip_hash:ip});if(!gate.ok)return gate;
  // Input cannot control property scope, current day, release time or source field.
  if(!validDate(data.check_in)||!(gate.days||[gate.day]).includes(data.check_in)||!validDate(data.check_out)||typeof data.name!=='string'||data.name.length>100||typeof data.reference!=='string'||data.reference.length>80||data.choice_id&&!UUID.test(data.choice_id))return failure();
  const c=await credentials(gate.property_id);if(Number(c.beds_property_id)!==Number(gate.beds_property_id))return failure();
  const matches=matchingBookings(await arrivals(c,data.check_in),data,c.beds_property_id,data.check_in,true);if(matches.length!==1)return failure();
  const original=matches[0];
  const fresh=await api('/bookings?propertyId='+c.beds_property_id+'&id='+original.id+'&includeInfoItems=true',{token:c.secret.token});
  const current=matchingBookings(fresh.data||[],data,c.beds_property_id,data.check_in,true);if(current.length!==1||Number(current[0].id)!==Number(original.id))return failure();
  const booking=current[0],strong=nameScore(data.name,booking)>=.95&&referenceScore(data.reference,booking)>=.9;
  const canChallenge=reference(booking.apiReference).length>=6&&similarity(reference(data.reference),reference(booking.apiReference))>=.9;
  // A wholly incorrect number needs staff verification; guessing a public name cannot unlock a room.
  const challenge=!strong&&canChallenge&&UUID.test(data.verification_token||'')?nameChoices(booking,cryptoApi):null;
  const digest=await cryptoApi.subtle.digest('SHA-256',new TextEncoder().encode(JSON.stringify([gate.property_id,booking.id,booking.firstName,booking.lastName,booking.arrival,booking.departure,booking.apiReference])));
  const fingerprint=[...new Uint8Array(digest)].map(x=>x.toString(16).padStart(2,'0')).join('');
  const identity=await rpc('web_checkin_identity',{p_property:gate.property_id,p_booking:booking.id,p_token:UUID.test(data.verification_token||'')?data.verification_token:cryptoApi.randomUUID(),p_fingerprint:fingerprint,p_name_matches:strong,p_can_challenge:canChallenge,p_options:challenge?.options||[],p_correct_id:challenge?.correct_id||null,p_choice:data.choice_id||null});
  if(identity.challenge)return {ok:true,challenge:true,options:shuffle(identity.options,cryptoApi),attempts_remaining:identity.attempts_remaining,expires_at:identity.expires_at};
  if(!identity.ok||!identity.verified)return {ok:false,code:'staff_required',message:'추가 확인이 필요합니다. 직원과의 채팅으로 예약 확인을 요청해주세요.'};
  const property=await inventory(c);
  const assigned=assignedUnit(current[0],property),code=accessCode(current[0],assigned,gate.source);
  if(!code)return {ok:false,code:'staff_required',message:'직원이 객실 배정과 출입 정보를 확인해야 합니다. 직원과의 채팅으로 문의해주세요.'};
  // Recheck current enablement/time immediately before disclosing access details.
  const allowed=await rpc('web_checkin_release',{p_property:gate.property_id,p_source:gate.source,p_day:data.check_in});if(!allowed)return failure();
  return {ok:true,property:gate.name,room:String(assigned.unit.name).slice(0,80),access_code:code,check_in:current[0].arrival,check_out:current[0].departure};
 };
}
