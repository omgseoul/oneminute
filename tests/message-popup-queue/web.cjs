const {JSDOM}=require('jsdom'),fs=require('fs'),assert=require('node:assert/strict');
const html=fs.readFileSync('app.html','utf8').replace(/<script[\s\S]*?<\/script>/g,'');
const w=new JSDOM(html,{url:'https://omgworks24.com/app.html',runScripts:'outside-only'}).window,calls=[];
w.omgSupabase={rpc:async(name,args)=>{calls.push({name,args});return{data:{ok:true}};}};
w.eval(fs.readFileSync('home-message-queue.js','utf8'));
const items=Array.from({length:4},(_,n)=>({message_id:'m'+n,message:'To do 알림\n지연: 점검 '+n,sender_label:n%2?'일정 알림':'To do 알림',message_type:'general',created_at:'2026-11-06T00:00:0'+n+'Z'}));
(async()=>{w.HomeMessageQueue.update(items,'staff-token',false);assert.equal(w.document.getElementById('messageArrivalBody').textContent,'지연: 점검 0');
w.HomeMessageQueue.update(items,'staff-token',true);assert.equal(w.document.querySelector('.message-arrival-count').textContent,'4건 대기');
await new Promise(r=>setTimeout(r,4300));assert.equal(w.document.getElementById('messageArrival').hidden,false,'no automatic timeout');
for(let i=0;i<4;i++){assert.equal(w.document.getElementById('messageArrivalBody').textContent,'지연: 점검 '+i);w.document.querySelector('.message-arrival-confirm').click();await new Promise(r=>setTimeout(r,210));}
assert.equal(w.document.getElementById('messageArrival').hidden,true);assert.deepEqual(calls.map(c=>c.args.p_message_id),['m0','m1','m2','m3']);
w.HomeMessageQueue.update(items,'staff-token',true);assert.equal(w.document.getElementById('messageArrival').hidden,true,'unread refresh cannot reopen confirmed IDs');
w.HomeMessageQueue.update([{...items[0],message_id:'new'}],'staff-token',true);assert.equal(w.document.getElementById('messageArrival').hidden,false);
const native=[];w.OMGNative={showMessageAlerts:json=>native.push(JSON.parse(json))};w.HomeMessageQueue.update(items,'other-token',false);assert.equal(w.document.getElementById('messageArrival').hidden,true,'account switch hides previous popup');assert.equal(native[0].length,4,'new APK receives every reminder, not just one');
console.log('PASS: four alerts FIFO, check-to-advance, no timeout, dedupe, mark only displayed message read, later arrival, native all-item bridge');w.close();})().catch(e=>{console.error(e);w.close();process.exitCode=1});
