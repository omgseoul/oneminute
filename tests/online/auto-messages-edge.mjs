import assert from 'node:assert/strict';
import {createAutoMessages,messageLanguage,renderAutoMessage} from '../../supabase/functions/beds24/auto-messages.mjs';
assert.equal(messageLanguage({country2:'JP'},{common:'Hi',ja:'こんにちは'}),'ja');
assert.equal(messageLanguage({country:'Japan'},{common:'Hi',ja:'こんにちは'}),'ja');
assert.equal(messageLanguage({firstName:'Yuki'},{common:'Hi',ja:'こんにちは'}),'common');
assert.equal(messageLanguage({country2:'JP'},{common:'Hi'}),'common');
assert.equal(renderAutoMessage('{{이름}} {{비밀번호}}',{'이름':'Han','비밀번호':'0658'}),'Han 0658');
assert.throws(()=>renderAutoMessage('{{비밀번호}}',{}),/정보가 없어/);
assert.throws(()=>renderAutoMessage('{{이름}}'.repeat(1000),{'이름':'Guest name'}),/4,000/);
const job={id:'id',lease:'lease',property_id:'property',booking_id:11,timezone:'Asia/Seoul',rule:{enabled:true,messages:{common:'Hi {{이름}} {{객실}} {{비밀번호}}',ja:'こんにちは {{이름}} {{객실}} {{비밀번호}}'}}};
let writes=[],finish=[],b={id:11,propertyId:100,roomId:200,unitId:1,status:'confirmed',country2:'JP',firstName:'1234 Han',lastName:'Mija',arrival:'2099-01-01',departure:'2099-01-02',infoItems:[{bookingId:11,code:'LOCK_PIN',text:'0658'}]},sendMode='ok',ready=true;
const worker=createAutoMessages({credentials:async()=>({beds_property_id:100,secret:{token:'test'}}),saveBookings:async()=>{},messages:async()=>{},
 rpc:async(name,args)=>{if(args.p_action==='prepare')return ready?{ok:true}:{skip:true};finish.push(args.p_data);return {ok:true};},
 api:async(path,headers,body)=>{if(body){writes.push(body);if(sendMode==='timeout')throw Error('timeout');return sendMode==='rejected'?[{success:false}]:[{success:true}];}if(path.startsWith('/bookings?'))return {data:[b]};return {data:[{id:100,roomTypes:[{id:200,units:[{id:1,name:'201'}]}]}]};}});
await worker.process(job);assert.equal(writes.length,1);assert.equal(writes[0][0].message,'こんにちは Han Mija 201 0658');assert.equal(finish.at(-1).status,'sent');
writes=[];b.infoItems=[];await worker.process(job);assert.equal(writes.length,0);assert.equal(finish.at(-1).status,'waiting');
b.infoItems=[{code:'LOCK_PIN',text:'0658'},{code:'LOCK_PIN',text:'9999'}];await worker.process(job);assert.equal(writes.length,0,'conflicting PINs never guessed');
b.status='cancelled';await worker.process(job);assert.equal(writes.length,0);assert.equal(finish.at(-1).status,'skipped');
b.status='confirmed';b.propertyId=999;await worker.process(job);assert.equal(writes.length,0,'cross-property data blocked');
b.propertyId=100;b.infoItems=[{code:'LOCK_PIN',text:'0658'}];ready=false;await worker.process(job);assert.equal(writes.length,0,'paused or revised rule cannot send');
ready=true;sendMode='timeout';await worker.process(job);assert.equal(finish.at(-1).status,'uncertain');
sendMode='rejected';await worker.process(job);assert.equal(finish.at(-1).status,'failed');
console.log('Auto messages: country fallback, token rendering, PIN leading zero/conflict, live cancellation, tenancy, final gate and ambiguous response passed');

// Several full-length CJK translations exceed the ordinary 30 KB request budget.
const {createBedsHandler}=await import('../../supabase/functions/beds24/handler.mjs');
let savedAction;const handler=createBedsHandler({env:()=> 'fixture',fetcher:async(url,options)=>{const data=JSON.parse(options.body);savedAction=data.p_action;return new Response(JSON.stringify({ok:true}));}});
const multilingual={common:'안'.repeat(4000),ja:'あ'.repeat(4000),'zh-CN':'好'.repeat(4000)};
const response=await handler(new Request('https://fixture.test/beds24',{method:'POST',body:JSON.stringify({action:'auto_message_save',access_token:'00000000-0000-0000-0000-000000000001',data:{messages:multilingual}})}));
assert.equal(response.status,200);assert.equal(savedAction,'save');
console.log('Multilingual request budget accepts full-length CJK versions');
