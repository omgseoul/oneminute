import assert from 'node:assert/strict';
import {createWebCheckin,similarity,matchingBookings,accessCode,assignedUnit,diagnostic,nameChoices,referenceScore,nameScore,cleanGuestName,documentMatches} from '../../supabase/functions/beds24/web-checkin.mjs';
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
for(const fixture of [b,{firstName:'김민수'},{firstName:'王小明'},{firstName:'Иван',lastName:'Петров'}]){const a=nameChoices(fixture),other=nameChoices(fixture);assert.equal(a.options.length,10);assert.equal(new Set(a.options.map(x=>x.label)).size,10);assert.equal(a.options.filter(x=>x.id===a.correct_id).length,1);assert.notDeepEqual(a.options,other.options);}
// Numeric annotations affect neither name verification nor guest-visible choices, in any property.
for(const propertyId of [263281,263294,329251,257061,999999]){
 for(const digits of ['6081','１２３４','١٢٣٤','²Ⅳ']){
  const numbered=Object.freeze({...b,propertyId,firstName:digits+' Ma'+digits+'ría',lastName:'Fernández '+digits});
  const original=JSON.stringify(numbered);
  assert.equal(nameScore('Maria Fernandez',numbered),1);
  assert.equal(nameScore('Fernandez '+digits+' Maria',numbered),1);
  assert.equal(matchingBookings([numbered],input,propertyId,day).length,1);
  assert(documentMatches({readable:true,guest_name:input.name,booking_reference:b.apiReference,check_in:day,check_out:b.departure},numbered));
  const choices=nameChoices(numbered);assert.equal(choices.options.find(x=>x.id===choices.correct_id).label,'MARIA FERNANDEZ');
  assert(choices.options.every(x=>!(/\p{N}/u.test(x.label))));
  assert.equal(JSON.stringify(numbered),original,'provider data must not be changed');
  assert.equal(diagnostic([numbered],{...prop,id:propertyId},day).reservations[0].name,numbered.firstName+' '+numbered.lastName,'owner diagnostic keeps the source name');
 }
}
assert.equal(cleanGuestName("  123 O’Neil  45 Smith-Jones ٦ "),"O’Neil Smith-Jones");
assert.equal(nameScore('6081',{firstName:'6081'}),0);assert.equal(nameChoices({firstName:'6081'}),null);
assert.equal(matchingBookings([b],{...input,name:'1234'},b.propertyId,day,true).length,0);
assert.equal(nameScore('Someone else',{...b,firstName:'6081 María'}),nameScore('Someone else',b));
assert.equal(referenceScore('ABC999999',b)<.9,true,'booking reference digits still matter');
assert.equal(documentMatches({readable:true,guest_name:'Maria Fernandez',booking_reference:'ABC999999',check_in:day,check_out:b.departure},b),true);
for(const fixture of [{firstName:'6081 김민수'},{firstName:'王123小明'},{firstName:'12 Иван',lastName:'Петров34'}]){
 const choices=nameChoices(fixture);assert(choices.options.every(x=>!(/\p{N}/u.test(x.label))));
 assert.equal(nameScore(cleanGuestName([fixture.firstName,fixture.lastName].filter(Boolean).join(' ')),fixture),1);
}
let allowed=true,apiCalls=0;
const run=createWebCheckin({rpc:async(name,args)=>{assert.equal(name,'web_checkin_admin');if(!allowed||args.p_token!=='owner')throw Error('관리자');assert.equal(args.p_data.property_id,'selected-branch');if(args.p_action==='record_probe')assert.equal(args.p_data.reservations,undefined);return {ok:true,property_id:'selected-branch',property_name:'Selected branch',day};},credentials:async property=>{assert.equal(property,'selected-branch');return{beds_property_id:263281,secret:{token:'test'}};},api:async path=>{apiCalls++;return{data:path.startsWith('/properties')?[prop]:[b]};}});
const req=new Request('https://fixture.test');assert.equal((await run('web_checkin',input,null,req)).code,'update_required');allowed=false;await assert.rejects(()=>run('web_checkin_diagnose',{},null,req),/관리자/);assert.equal(apiCalls,0);allowed=true;const summary=await run('web_checkin_diagnose',{property_id:'selected-branch'},'owner',req);assert.equal(summary.property_id,'selected-branch');assert.equal(summary.reservations[0].name,'María Fernández');assert(!JSON.stringify(summary).includes('7351'));
console.log('Web check-in matching, ten synthetic choices, source isolation, legacy bypass denial and owner diagnostic tests passed');

// Document identity is an OR, dates remain mandatory, and 90% is inclusive.
const identity={id:987654,firstName:'ABCDEFGHIJ',lastName:'',apiReference:'REF123456',arrival:day,departure:'2026-11-19'};
const proof={readable:true,guest_name:'ABCDEFGHIX',booking_reference:'',check_in:day,check_out:'2026-11-19'};
assert.equal(nameScore(proof.guest_name,identity),.9);assert(documentMatches(proof,identity));
assert(!documentMatches({...proof,guest_name:'ABCDEFGHXY'},identity));
assert(documentMatches({...proof,guest_name:'',booking_reference:'REF123456'},identity));
assert(documentMatches({...proof,guest_name:'Different Name',booking_reference:'987654'},identity));
assert(!documentMatches({...proof,check_out:'2026-11-20',booking_reference:'REF123456'},identity));
assert(!documentMatches({...proof,readable:false,booking_reference:'REF123456'},identity));
assert(!documentMatches({...proof,guest_name:'',booking_reference:''},identity));
