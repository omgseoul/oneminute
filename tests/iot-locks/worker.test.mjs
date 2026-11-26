import test from 'node:test';import assert from 'node:assert/strict';
import {createIotService,createIotHandler,choosePin,pinUpdate,localTime} from '../../supabase/functions/iot-locks/handler.mjs';
const id='00000000-0000-0000-0000-000000000001',now=Date.parse('2026-11-26T03:00Z');
function fixture({info=[],state={},booking={},failAdd=false,failBeds=false,conflictAfterAdd=false,failVerify=false}={}){
 let book={id:12345,propertyId:10,roomId:20,unitId:1,arrival:'2026-11-26',departure:'2026-11-28',status:'confirmed',firstName:'Guest',phone:'010-2345-6789',infoItems:info,...booking};
 const locks=new Map([[7,[]],[8,[]]]),calls=[],finishes=[];let current=structuredClone(state),addLost=failAdd,bedsLost=failBeds;
 const settings={enabled:true,days_before:1,create_time:'09:00',start_time:'15:00',end_time:'11:00',pin_strategy:'phone',pin_length:4,mappings:[{kind:'room',room_id:20,unit_id:1,lock_id:7},{kind:'common',lock_id:8}]};
 const rpc=async(name,a)=>{calls.push([name,a]);if(name==='online_sync_control')return{};if(name==='online_internal')return {beds_property_id:10,secret:{token:'beds',refreshToken:'r',expiresAt:now+3600000}};
  if(a.p_action==='api_reserve')return {clientId:'app',clientSecret:'secret'};if(a.p_action==='credentials')return {secret:{accessToken:'tt',expiresAt:now+3600000},settings};if(a.p_action==='checkpoint')current=structuredClone(a.p_data.state);if(a.p_action==='finish')finishes.push(a.p_data);return{ok:true};};
 const fetcher=async(url,opt={})=>{const u=new URL(url);calls.push([u.hostname+u.pathname,opt.method||'GET']);if(u.hostname==='beds24.com'){
  if(opt.method==='POST'){const changes=JSON.parse(opt.body)[0].infoItems;for(const i of changes){if(i.id)book.infoItems=book.infoItems.filter(x=>x.id!==i.id);else book.infoItems.push({...i,id:100});}if(bedsLost){bedsLost=false;throw Error('lost response');}return Response.json([{success:true}]);}return Response.json({data:[structuredClone(book)]});}
  const p=new URLSearchParams(opt.body||u.search),lock=Number(p.get('lockId')),rows=locks.get(lock);
  if(u.pathname.endsWith('listKeyboardPwd'))return Response.json({list:structuredClone(rows),pages:1});
  if(u.pathname.endsWith('/add')){rows.push({keyboardPwdId:lock*10,keyboardPwd:p.get('keyboardPwd'),keyboardPwdName:p.get('keyboardPwdName'),startDate:Number(p.get('startDate')),endDate:Number(p.get('endDate'))});if(conflictAfterAdd)book.infoItems=[{id:444,code:'LOCK_PIN',text:'external'}];if(addLost){addLost=false;throw Error('lost response');}if(failVerify)rows[0].endDate=0;return Response.json({errcode:0});}
  if(u.pathname.endsWith('/change')){Object.assign(rows.find(x=>x.keyboardPwdId===Number(p.get('keyboardPwdId'))),{keyboardPwd:p.get('newKeyboardPwd'),startDate:Number(p.get('startDate')),endDate:Number(p.get('endDate'))});return Response.json({errcode:0});}
  if(u.pathname.endsWith('/delete')){locks.set(lock,rows.filter(x=>x.keyboardPwdId!==Number(p.get('keyboardPwdId'))));return Response.json({errcode:0});}
  throw Error('unexpected '+url);
 };
 const svc=createIotService({rpc,fetcher,now:()=>now});const run=async(attempt=1)=>svc.process({id,property_id:id,booking_id:12345,settings,timezone:'Asia/Seoul',state:current,lease:id,attempt});
 return {run,calls,finishes,locks,book,settings,get state(){return current;}};
}
test('Korean local schedule uses exact time and PIN strategies preserve zeros',()=>{
 assert.equal(localTime('2026-11-26','09:00','Asia/Seoul'),Date.parse('2026-11-26T00:00Z'));
 assert.equal(choosePin({phone:'010-1234-0056'},new Set()),'0056');assert.equal(choosePin({apiReference:'OTA-123456'},new Set(),{pin_strategy:'booking'}),'3456');assert.equal(choosePin({id:987654},new Set(),{pin_strategy:'beds_booking'}),'7654');assert.equal(choosePin({},new Set(),{pin_strategy:'random_1_6'},()=>5),'6666');assert.equal(choosePin({phone:'000000000',mobile:'010-7654-9876'},new Set()),'9876');assert.equal(choosePin({phone:'010-1234-6789'},new Set(['6789']),{},()=>2),'2222');
});
for(const info of [[{code:'LOCK_PIN',text:'2468'}],[{code:'LOCK_PIN',text:''}],[{code:'LOCK_PIN',text:'1'},{code:'LOCK_PIN',text:'2'}]])test('any existing Lock info stops before TTLock and preserves values: '+JSON.stringify(info),async()=>{const f=fixture({info});await f.run();assert.equal(f.finishes[0].status,'failed');assert.match(f.finishes[0].error,/기존 Lock info.*삭제한 뒤/);assert(!f.calls.some(x=>x[0].startsWith('euapi.')));assert(!f.calls.some(x=>x[1]?.p_action==='api_reserve'));assert.deepEqual(f.book.infoItems,info);assert.throws(()=>pinUpdate(f.book,'1234'),/기존 Lock info/);});
test('creates room and common door then writes exactly one LOCK_PIN',async()=>{const f=fixture();await f.run();assert.equal(f.finishes.at(-1).status,'done');assert.equal(f.book.infoItems[0].text,'6789');assert.equal(f.locks.get(7).length,1);assert.equal(f.locks.get(8).length,1);assert(f.state.beds_write_intent);});
test('remote add response lost: retry reconciles names, does not duplicate',async()=>{const f=fixture({failAdd:true});await f.run();assert.equal(f.finishes.at(-1).status,'waiting');await f.run(2);assert.equal(f.finishes.at(-1).status,'done');assert.equal(f.locks.get(7).length,1);assert.equal(f.calls.filter(x=>x[0]==='euapi.ttlock.com/v3/keyboardPwd/add').length,2);});
test('Beds response lost: own checkpoint allows safe readback without duplicate writes',async()=>{const f=fixture({failBeds:true});await f.run();assert.equal(f.finishes.at(-1).status,'waiting');await f.run(2);assert.equal(f.finishes.at(-1).status,'done');assert.equal(f.book.infoItems.length,1);assert.equal(f.calls.filter(x=>x[0]==='beds24.com/api/v2/bookings'&&x[1]==='POST').length,1);});
test('concurrent external Lock info is never overwritten or deleted',async()=>{const f=fixture({conflictAfterAdd:true});await f.run();assert.equal(f.finishes.at(-1).status,'failed');assert.equal(f.book.infoItems[0].text,'external');assert(!f.calls.some(x=>x[0]==='beds24.com/api/v2/bookings'&&x[1]==='POST'));});
test('unverified lock registration never writes guest Lock info',async()=>{const f=fixture({failVerify:true});await f.run(3);assert.equal(f.finishes.at(-1).status,'failed');assert.equal(f.book.infoItems.length,0);});
test('room unit mismatch cannot write to another room',async()=>{const f=fixture({booking:{unitId:2}});await f.run(3);assert.equal(f.finishes.at(-1).status,'failed');assert(!f.calls.some(x=>x[0].includes('/add')));});
test('future bookings wait; cancellation and postponement remove only own grants',async()=>{
 const future=fixture({booking:{arrival:'2026-12-10',departure:'2026-12-12'}});await future.run();assert.equal(future.finishes[0].status,'waiting');assert(!future.calls.some(x=>x[0].includes('/add')));
 for(const change of [{status:'cancelled'},{arrival:'2026-12-10',departure:'2026-12-12'}]){const f=fixture();await f.run();f.locks.get(7).push({keyboardPwdId:99,keyboardPwdName:'Other reservation',keyboardPwd:'2222'});Object.assign(f.book,change);await f.run();assert.equal(f.book.infoItems.length,0);assert.equal(f.locks.get(7).length,1);assert.equal(f.locks.get(7)[0].keyboardPwdId,99);assert.equal(f.finishes.at(-1).status,change.status?'revoked':'waiting');}
});
test('ON requires owner authorization, boolean flag and secondary password',async()=>{
 let verified=false;const actions=[];
 const handler=createIotHandler({env:k=>({SUPABASE_URL:'https://db.test',SUPABASE_SERVICE_ROLE_KEY:'service'})[k],fetcher:async(url,opt)=>{const b=JSON.parse(opt.body);actions.push(b);if(url.endsWith('/verify_owner_sensitive_password'))return Response.json({ok:verified});return Response.json({ok:true,property_id:id});}});
 const send=data=>handler(new Request('https://edge.test/iot-locks',{method:'POST',body:JSON.stringify({access_token:id,action:'toggle',data})}));
 assert.equal((await send({enabled:'true'})).status,400);assert.equal((await send({enabled:true})).status,400);assert.equal((await send({enabled:true,sensitive_password:'wrong'})).status,400);verified=true;assert.equal((await send({enabled:true,sensitive_password:'valid'})).status,200);assert(!actions.at(-1).p_data.sensitive_password);
});

test('ordered PIN methods use one length, separate mobile and force random on collision',()=>{
 const settings={pin_strategy:'mobile',pin_strategy_secondary:'booking',pin_length:6};
 assert.equal(choosePin({phone:'01011112222',mobile:'01034560056',apiReference:'R-8888123456'},new Set(),settings),'560056');
 assert.equal(choosePin({mobile:'12',apiReference:'R-8888123456'},new Set(),settings),'123456');
 assert.equal(choosePin({mobile:'000000',apiReference:'12'},new Set(),settings,()=>7),'777777');
 assert.equal(choosePin({mobile:'01034560056',apiReference:'R-8888123456'},new Set(['560056']),settings,()=>7),'777777');
 assert.equal(choosePin({mobile:'12',apiReference:'R-8888123456'},new Set(['123456']),settings,()=>7),'777777');
 assert.equal(choosePin({phone:'',mobile:'01012345678'},new Set(),{pin_strategy:'phone',pin_strategy_secondary:'none'},()=>3),'3333');
 assert.equal(choosePin({},new Set(),{...settings,pin_strategy_secondary:'random_1_6'},()=>4),'555555');
 let n=0;assert.equal(choosePin({},new Set(['0000']),{pin_strategy:'random'},()=>n++<4?0:1),'1111');
 assert.throws(()=>choosePin({},new Set(['0000']),{pin_strategy:'random'},()=>0),/사용 가능한 비밀번호/);
 assert.throws(()=>choosePin({},new Set(),{pin_strategy:'mobile',pin_strategy_secondary:'unknown'}),/생성 방식/);
});
test('worker registers the secondary six-digit code on both locks and Beds24',async()=>{
 const f=fixture({booking:{mobile:'12',apiReference:'REF-987654'}});Object.assign(f.settings,{pin_strategy:'mobile',pin_strategy_secondary:'booking',pin_length:6});await f.run();
 assert.equal(f.book.infoItems.find(x=>x.code==='LOCK_PIN').text,'987654');for(const rows of f.locks.values())assert.equal(rows[0].keyboardPwd,'987654');
});

test('two-day schedule still issues for same-day and next-day arrivals',async()=>{
 for(const arrival of ['2026-11-26','2026-11-27']){const f=fixture({booking:{arrival}});f.settings.days_before=2;await f.run();assert.equal(f.finishes.at(-1).status,'done');assert.equal(f.book.infoItems.filter(x=>x.code==='LOCK_PIN').length,1);}
});
