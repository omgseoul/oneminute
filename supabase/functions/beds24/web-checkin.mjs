// Door codes stay in the provider response and are never persisted with ordinary bookings.
import {validDocumentImage} from './web-checkin-document.mjs';
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
export function nameChoices(b,c=crypto,count=10){
 const raw=[b.firstName,b.lastName].filter(Boolean).join(' ').normalize('NFC').trim().replace(/\s+/g,' ');
 const label=/^[\p{Script=Latin}\p{M}\s.'’-]+$/u.test(raw)?raw.normalize('NFKD').replace(/\p{M}/gu,'').toUpperCase():raw;
 let generate;const pick=a=>a[randomInt(a.length,c)],latinFirst='ALEX MORGAN JAMIE TAYLOR ROBIN CHARLIE CAMERON JORDAN SAM RILEY DREW CASEY AVERY QUINN ROWAN JESSE'.split(' '),latinLast='MARTIN WILSON PARKER TURNER WALKER CLARK MILLER HALL ALLEN YOUNG KING SCOTT BROWN EVANS REED BELL'.split(' ');
 if(/^[A-Z\s.'’-]+$/.test(label)){const parts=label.split(' ');generate=()=>parts.map((_,i)=>pick(i===parts.length-1?latinLast:latinFirst)).join(' ');}
 else if(/^[\p{Script=Hangul}\s]+$/u.test(label))generate=()=>Array.from(label).map((x,i)=>x===' '?' ':pick(Array.from(i===0?'김이박최정강조윤장임한오서신권황':'서민지준현수연우정하은유영진다성'))).join('');
 else if(/^[\p{Script=Han}\s]+$/u.test(label))generate=()=>Array.from(label).map((x,i)=>x===' '?' ':pick(Array.from(i===0?'王李張劉陳楊黃趙周吳徐孫胡朱高林':'明華文麗英美俊秀傑芳雲宇涵浩怡安'))).join('');
 else if(/^[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\sー]+$/u.test(label))generate=()=>Array.from(label).map(x=>x===' '?' ':pick(Array.from(/\p{Script=Hiragana}/u.test(x)?'あいうえおかきくけこさしすせそたちつてとなにぬねのまみむめもやゆよりるれろ':/\p{Script=Katakana}/u.test(x)?'アイウエオカキクケコサシスセソタチツテトナニヌネノマミムメモヤユヨリルレロ':'山田中川村林木本井藤佐高小大松島原'))).join('');
 else if(/^[\p{Script=Cyrillic}\s]+$/u.test(label))generate=()=>label.split(' ').map((_,i)=>pick((i?'Иванов Петров Соколов Смирнов Волков Морозов Новиков Козлов':'Алексей Иван Дмитрий Сергей Андрей Максим Павел Виктор').split(' '))).join(' ');
 else return null;
 const labels=new Set([label]);for(let i=0;labels.size<count&&i<500;i++)labels.add(generate());if(labels.size!==count)return null;
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
export function documentMatches(document,booking){return document?.readable===true&&validDate(document.check_in)&&validDate(document.check_out)&&document.check_in===booking.arrival&&document.check_out===booking.departure&&nameScore(document.guest_name,booking)>.9&&[booking.id,booking.apiReference].filter(x=>x!=null&&String(x).length>=5).some(x=>reference(x)===reference(document.booking_reference));}
export function createWebCheckin({rpc,credentials,api,readDocument=async()=>{throw Error('unavailable');},cryptoApi=crypto}){
 const failure=()=>({ok:false,code:'not_verified',message:'입력한 정보만으로 예약을 확정하지 못했습니다. 예약확인서를 다시 확인하거나 직원과의 채팅으로 추가 확인을 요청해주세요.'});
 async function inventory(c){const result=await api('/properties?id='+c.beds_property_id+'&includeAllRooms=true&includeUnitDetails=true',{token:c.secret.token});const props=(result.data||[]).filter(p=>Number(p.id)===Number(c.beds_property_id));if(props.length!==1)throw Error('객실 배정 정보를 확인하지 못했습니다. 직원에게 문의해주세요.');return props[0];}
 async function arrivals(c,day){const rows=[];for(let page=1;page<=3;page++){const result=await api('/bookings?propertyId='+c.beds_property_id+'&arrival='+day+'&includeInfoItems=true&page='+page,{token:c.secret.token});if(!Array.isArray(result.data)||result.data.some(b=>Number(b.propertyId)!==Number(c.beds_property_id)))throw Error('예약 정보를 확인하지 못했습니다.');rows.push(...result.data);if(!result.pages?.nextPageExists)return rows;}throw Error('직원에게 체크인 확인을 요청해주세요.');}
 return async(action,data,token,req)=>{
  if(action==='web_checkin_preview'){
   // Authenticate every request. The client cannot choose a property or reset live guards.
   const admin=await rpc('web_checkin_admin',{p_token:token,p_action:'read',p_data:{}});
   if(!admin.connected)throw Error('Beds24 연결을 먼저 설정해주세요.');
   if(!UUID.test(data.verification_token||'')||!UUID.test(data.device_id||''))return failure();
   const c=await credentials(admin.property_id);
   const bytes=await cryptoApi.subtle.digest('SHA-256',new TextEncoder().encode('preview:'+admin.property_id+':'+data.verification_token));
   const h=[...new Uint8Array(bytes)].map(x=>x.toString(16).padStart(2,'0')).join('');
   const scope=h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20,32);
   const isolatedRpc=async(name,args)=>{
    if(name==='web_checkin_gate')return {ok:true,property_id:admin.property_id,beds_property_id:c.beds_property_id,day:admin.day,source:admin.source};
    if(name==='web_checkin_flow')return rpc('web_checkin_preview_flow',{...args,p_property:scope});
    if(name==='web_checkin_release')return args.p_property===admin.property_id&&args.p_source===admin.source&&args.p_day===admin.day;
    throw Error('지원하지 않는 테스트 요청입니다.');
   };
   const run=createWebCheckin({rpc:isolatedRpc,credentials:async property=>{if(property!==admin.property_id)throw Error('권한이 없습니다.');return c;},api,readDocument,cryptoApi});
   const result=await run('web_checkin',{...data,slug:admin.property_id},null,req);
   return {...result,preview_day:admin.day};
  }
  if(action==='web_checkin_diagnose'){
   const gate=await rpc('web_checkin_admin',{p_token:token,p_action:'probe',p_data:{}}),c=await credentials(gate.property_id),rows=await arrivals(c,gate.day),property=await inventory(c),summary=diagnostic(rows,property,gate.day);
   const {reservations,truncated,...counts}=summary;await rpc('web_checkin_admin',{p_token:token,p_action:'record_probe',p_data:counts});return {ok:true,...summary};
  }
  if(action==='web_checkin_settings'||action==='web_checkin_save')return rpc('web_checkin_admin',{p_token:token,p_action:action==='web_checkin_save'?'save':'read',p_data:data});
  if(action!=='web_checkin')throw Error('지원하지 않는 요청입니다.');
  const staff=()=>({ok:false,code:'staff_required',message:'직원과의 채팅으로 예약을 확인하여 주십시오.'});
  if(!UUID.test(data.slug||'')||!UUID.test(data.verification_token||'')||!UUID.test(data.device_id||''))return {ok:false,code:'update_required',message:'화면을 새로고침한 뒤 다시 확인해주세요.'};
  const hash=async value=>[...new Uint8Array(await cryptoApi.subtle.digest('SHA-256',new TextEncoder().encode(value)))].map(x=>x.toString(16).padStart(2,'0')).join('');
  // A retry ID is bound to its submitted values, so reusing it for new guesses still counts.
  const attemptFor=async(kind,values)=>{const h=await hash(JSON.stringify([data.attempt_id,kind,values]));return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20,32);};
  const addr=req.headers.get('x-forwarded-for')?.split(',')[0]?.trim();if(!addr)return staff();
  const gate=await rpc('web_checkin_gate',{p_slug:data.slug,p_ip_hash:await hash(addr)});if(!gate.ok)return gate;
  const flow=(action,value={})=>rpc('web_checkin_flow',{p_property:gate.property_id,p_token:data.verification_token,p_device:data.device_id,p_action:action,p_data:value});
  const device=await flow('device');if(!device.ok)return device;
  const allowedDays=gate.days||[gate.day],active=b=>Number(b.propertyId)===Number(gate.beds_property_id)&&['new','confirmed'].includes(b.status)&&Number(b.roomQty||1)===1&&allowedDays.includes(b.arrival);
  const fingerprint=b=>hash(JSON.stringify([gate.property_id,b.id,b.firstName,b.lastName,b.arrival,b.departure,b.apiReference,b.roomId,b.unitId]));
  let c;const context=async()=>{if(!c){c=await credentials(gate.property_id);if(Number(c.beds_property_id)!==Number(gate.beds_property_id))throw Error('직원과의 채팅으로 예약을 확인하여 주십시오.');}return c;};
  const list=async()=>{await context();const all=[];for(const day of allowedDays)all.push(...await arrivals(c,day));return [...new Map(all.filter(active).map(b=>[String(b.id),b])).values()];};
  const fresh=async id=>{await context();const result=await api('/bookings?propertyId='+c.beds_property_id+'&id='+id+'&includeInfoItems=true',{token:c.secret.token});const rows=(result.data||[]).filter(b=>Number(b.id)===Number(id)&&active(b));return rows.length===1?rows[0]:null;};
  const publicState=s=>{if(!s.ok)return s;if(!['reference','fallback_dates','name','dates','choice','upload'].includes(s.stage))return staff();const result={ok:true,stage:s.stage,mode:s.mode,reference_remaining:s.reference_remaining,name_remaining:s.name_remaining,attempts_remaining:s.attempts_remaining,...(s.message?{message:s.message}:{})};if(s.stage==='choice'){result.options=shuffle(s.options||[],cryptoApi);result.rejected_ids=s.rejected_ids||[];}return result;};
  async function disclose(state){
  // Re-read both the reservation and server state immediately before disclosure.
  const booking=await fresh(state.booking_id);if(!booking||await fingerprint(booking)!==state.fingerprint)return staff();
  const property=await inventory(c),assigned=assignedUnit(booking,property),code=accessCode(booking,assigned,gate.source);
  if(!code)return staff();const finalState=await flow('read');if(!finalState.ok||finalState.stage!=='verified')return staff();
  if(!await rpc('web_checkin_release',{p_property:gate.property_id,p_source:gate.source,p_day:booking.arrival}))return staff();
  return {ok:true,stage:'complete',greeting:'안녕하세요. 예약이 확인되었습니다. 편안한 숙박 되세요!',property:gate.name||String(property.name||'숙소'),room:String(assigned.unit.name).slice(0,80),access_code:code,check_in:booking.arrival,check_out:booking.departure};
  }
  let state,booking;
  if(['reference','unknown','resume'].includes(data.step)){
   state=await flow('start');if(!state.ok)return state;
   if(state.stage==='reference'&&data.step!=='resume'){
    if(data.step==='unknown')state=await flow('reference',{unknown:true});
    else{
     if(typeof data.reference!=='string'||reference(data.reference).length<1||data.reference.length>80||!UUID.test(data.attempt_id||''))return failure();
     const rows=(await list()).filter(b=>referenceScore(data.reference,b)>=.9),match=rows.length===1?rows[0]:null;
     state=await flow('reference',{attempt_id:await attemptFor('reference',reference(data.reference)),...(match?{booking_id:match.id,fingerprint:await fingerprint(match)}:{})});
    }
   }
  }else{
   state=await flow('read');if(!state.ok)return state;if(state.stage==='verified')return disclose(state);
   let dateInput=data;
   if(state.stage==='fallback_dates'&&data.step==='dates'){
    if(!validDate(data.check_in)||!validDate(data.check_out)||data.check_out<=data.check_in||Date.parse(data.check_out)-Date.parse(data.check_in)>93*86400000)return {ok:true,stage:'fallback_dates',mode:'document',message:'체크인·체크아웃 날짜를 확인해주세요.'};
    return publicState(await flow('fallback_dates',{check_in:data.check_in,check_out:data.check_out}));
   }
   if(data.step==='name'){
    if(state.stage!=='name'||!validDate(state.selected_check_in)||!validDate(state.selected_check_out)||!UUID.test(data.attempt_id||''))return staff();
    const valid=typeof data.name==='string'&&data.name.trim().length>=2&&data.name.length<=100;
    dateInput={check_in:state.selected_check_in,check_out:state.selected_check_out};
    const rows=valid&&allowedDays.includes(state.selected_check_in)?(await arrivals(await context(),state.selected_check_in)).filter(b=>active(b)&&b.arrival===state.selected_check_in&&nameScore(data.name,b)>.9):[];
    state=await flow('name',{matched:rows.length>0,name:valid?data.name.trim():'',attempt_id:await attemptFor('name',data.name)});
    if(!state.ok||state.stage==='name')return publicState(state);
    const exact=rows.filter(b=>b.departure===dateInput.check_out),match=exact.length===1?exact[0]:rows.length===1?rows[0]:null;
    if(!match)return staff();
    state=await flow('bind',{booking_id:match.id,fingerprint:await fingerprint(match)});if(!state.ok)return state;
   }
   if(state.booking_id){booking=await fresh(state.booking_id);if(!booking||await fingerprint(booking)!==state.fingerprint)return staff();}
   if(data.step==='dates'||data.step==='name'){
    if(state.stage!=='dates'||!booking||!UUID.test(data.attempt_id||''))return staff();
    const matched=validDate(dateInput.check_in)&&validDate(dateInput.check_out)&&dateInput.check_in===booking.arrival&&dateInput.check_out===booking.departure;
    const choices=state.mode==='reference'?nameChoices(booking,cryptoApi):null;
    if(state.mode==='reference'&&!choices)return staff();
    state=await flow('dates',{matched,attempt_id:await attemptFor('dates',[dateInput.check_in,dateInput.check_out]),options:choices?.options||[],correct_id:choices?.correct_id||null});
   }else if(data.step==='choice'){
    if(state.stage!=='choice'||!booking||!UUID.test(data.choice_id||'')||!UUID.test(data.attempt_id||''))return staff();
    state=await flow('choice',{choice_id:data.choice_id,attempt_id:await attemptFor('choice',data.choice_id)});
   }else if(data.step==='upload'){
    if(state.stage!=='upload'||!booking)return staff();
    if(!validDocumentImage(data.image))return {ok:true,stage:'upload',mode:'document',message:'선명한 JPG·PNG·WebP 이미지를 선택해주세요. 전송 크기는 2MB 이하입니다.'};
    try{state=await flow('claim_image');}catch{return staff();}if(!state.ok)return state;
    let matched=false;try{const document=await readDocument(data.image);const current=await fresh(booking.id);matched=!!current&&await fingerprint(current)===state.fingerprint&&documentMatches(document,current);if(current)booking=current;}catch{/* Never return provider errors, document text or credentials. */}
    state=await flow('document',{matched});
   }else return staff();
  }
  if(!state.ok||state.stage!=='verified')return publicState(state);
  return disclose(state);
 };
}
