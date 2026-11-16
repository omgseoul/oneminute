import assert from 'node:assert/strict';
import {createWebCheckin,similarity,matchingBookings,accessCode,assignedUnit,diagnostic,nameChoices,referenceScore} from '../../supabase/functions/beds24/web-checkin.mjs';
const day='2026-11-16',prop={id:263281,roomTypes:[{id:20,units:[{id:1,name:'201',name2:'7351#'}]}]},b={id:12345678,propertyId:263281,roomId:20,unitId:1,roomQty:1,firstName:'María',lastName:'Fernández',status:'confirmed',arrival:day,departure:'2026-11-19',apiReference:'ABC-123456',infoItems:[{code:'DOOR',text:'7351#',bookingId:12345678}]},input={slug:'00000000-0000-0000-0000-000000000001',name:'Maria Fernandez',check_in:day,check_out:'2026-11-19',reference:'ABC123456'};
assert.equal(similarity('María Fernández','MARIA FERNANDEZ'),1);assert(similarity('Alexander Montgomeryson','Alexander Montgomerysin')>=.95);assert(similarity('Kim','Lim')<.95);
assert.equal(matchingBookings([b],input,263281,day).length,1);assert.equal(matchingBookings([b],{...input,name:'Fernandez Maria'},263281,day).length,1);
for(const change of [{name:'Someone else'},{check_in:'2026-11-17'},{check_out:'2026-11-20'},{reference:'WRONG123'},{name:'Maria'},{check_in:'2026-02-30'}])assert.equal(matchingBookings([b],{...input,...change},263281,day).length,0);
for(const change of [{propertyId:999},{status:'cancelled'},{status:'request'},{roomQty:2}])assert.equal(matchingBookings([{...b,...change}],input,263281,day).length,0);
const unit=assignedUnit(b,prop);assert.equal(accessCode(b,unit,'info:DOOR'),'7351#');assert.equal(accessCode(b,unit,'unit:name2'),'7351#');assert.equal(accessCode(b,null,'info:DOOR'),null);assert.equal(accessCode({...b,infoItems:[...b.infoItems,{code:'DOOR',text:'9999'}]},unit,'info:DOOR'),null);
assert.equal(accessCode({...b,infoItems:[{code:'DOOR',text:'7351#',bookingId:999}]},unit,'info:DOOR'),null);
assert.equal(assignedUnit({...b,unitId:2},prop),null);assert.equal(assignedUnit(b,{...prop,id:999}),null);
const probe=diagnostic([b],prop,day);assert.equal(probe.sources.length,2);assert(!JSON.stringify(probe).includes('7351'));assert.equal(probe.reservations[0].name,'María Fernández');assert.equal(probe.reservations[0].reference,b.apiReference);
assert.equal(referenceScore('ABC 123456',b),1);assert(referenceScore('ABC1234567',{...b,apiReference:'ABC1234568'})>=.9);assert.equal(referenceScore('12345679',{...b,apiReference:null}),0);
for(const fixture of [b,{firstName:'김민수'},{firstName:'王小明'},{firstName:'Иван',lastName:'Петров'}]){const a=nameChoices(fixture),other=nameChoices(fixture);assert.equal(a.options.length,15);assert.equal(new Set(a.options.map(x=>x.label)).size,15);assert.equal(a.options.filter(x=>x.id===a.correct_id).length,1);assert.notDeepEqual(a.options,other.options);}
let rows=[b],fresh=b,enabled=true,release=true,credentialsCalls=0,adminAllowed=true,apiCalls=0;
const rpc=async(name,args)=>{
 if(name==='web_checkin_gate')return enabled?{ok:true,day,property_id:'internal-property',beds_property_id:263281,name:'Synthetic',source:'info:DOOR'}:{ok:false,code:'unavailable'};
 if(name==='web_checkin_release'){assert.equal(args.p_day,day);return release;}
 if(name==='web_checkin_identity'){if(args.p_name_matches)return {ok:true,verified:true};if(args.p_can_challenge&&args.p_options.length===15)return {ok:true,challenge:true,options:args.p_options,attempts_remaining:2};return {ok:false};}
 if(name==='web_checkin_admin'){if(!adminAllowed||args.p_token!=='owner')throw Error('관리자 로그인이 필요합니다.');return {ok:true,property_id:'internal-property',day};}
 throw Error('unexpected rpc');
};
const run=createWebCheckin({rpc,credentials:async p=>{assert.equal(p,'internal-property');credentialsCalls++;return {beds_property_id:263281,secret:{token:'test'}};},api:async path=>{apiCalls++;if(path.startsWith('/properties'))return{data:[prop]};return{data:path.includes('&id=')?[fresh]:rows};}});
const req=new Request('https://example.test',{headers:{'x-forwarded-for':'203.0.113.10'}});
assert.equal((await run('web_checkin',input,null,req)).access_code,'7351#');
assert(!(await run('web_checkin',{...input,name:'Different'},null,req)).ok);assert(!(await run('web_checkin',{...input,reference:'WRONG'},null,req)).ok);
const challenged=await run('web_checkin',{...input,name:'Different',verification_token:'00000000-0000-4000-8000-000000000001'},null,req);assert.equal(challenged.options.length,15);assert.equal(challenged.attempts_remaining,2);assert.equal(challenged.access_code,undefined);assert.equal(challenged.correct_id,undefined);
fresh={...b,status:'cancelled'};assert(!(await run('web_checkin',input,null,req)).ok);fresh=b;
rows=[b,{...b,id:98765432}];assert(!(await run('web_checkin',input,null,req)).ok);rows=[b];
release=false;assert(!(await run('web_checkin',input,null,req)).ok);release=true;
enabled=false;const before=credentialsCalls;assert(!(await run('web_checkin',input,null,req)).ok);assert.equal(credentialsCalls,before);enabled=true;
assert(!(await run('web_checkin',input,null,new Request('https://example.test'))).ok);
adminAllowed=false;const apiBefore=apiCalls;await assert.rejects(()=>run('web_checkin_diagnose',{},null,req),/관리자/);assert.equal(apiCalls,apiBefore);
adminAllowed=true;const liveProbe=await run('web_checkin_diagnose',{},'owner',req);assert.equal(liveProbe.bookings,1);assert(!JSON.stringify(liveProbe).includes('7351'));assert.equal(liveProbe.reservations[0].booking_id,String(b.id));
console.log('Web check-in edge: name/reference similarity, 15 synthetic choices, no pre-verification codes, cancellation/race checks and owner-only reservation diagnostics passed');
