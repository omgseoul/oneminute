const {JSDOM}=require('jsdom'),{indexedDB}=require('fake-indexeddb'),fs=require('fs'),assert=require('node:assert/strict');
const sleep=()=>new Promise(r=>setTimeout(r,5));async function until(f){for(let i=0;i<200;i++){if(f())return;await sleep();}assert.fail('timeout');}
(async()=>{const w=new JSDOM('',{url:'https://omgworks24.com',runScripts:'outside-only'}).window;w.indexedDB=indexedDB;w.eval(fs.readFileSync('chat-outbox.js','utf8'));let calls=0,aborts=0,finish;
 const box=await w.OMSChatOutbox.open('active-controls',async(item,transfer)=>{calls++;transfer.onProgress(7);return new Promise((resolve,reject)=>{finish=()=>resolve({message_id:item.client_id});transfer.signal.addEventListener('abort',()=>{aborts++;reject(Error('aborted'));},{once:true});});},()=>{});
 try{const item=await box.enqueue({peer:'a',body:'video',photo:'data:video/mp4;base64,AAAA'});await until(()=>calls===1);assert.equal(item.upload_percent,7);
 await box.pause(item.client_id);await until(()=>aborts===1);assert.equal(item.status,'paused');for(let i=0;i<4;i++)box.pump();await sleep();assert.equal(calls,1);
 await box.retry(item.client_id);await until(()=>calls===2);assert.equal(item.status,'sending');await box.cancel(item.client_id);await until(()=>aborts===2);assert.equal(box.items('a').length,0);
 const next=await box.enqueue({peer:'a',body:'new'});await until(()=>calls===3);finish();await until(()=>next.status==='sent');
 // Cancellation must propagate into the actual Supabase request signal.
 w.eval(fs.readFileSync('staff-chat-client.js','utf8'));let signal;w.omgSupabase={rpc:()=>({abortSignal(s){signal=s;return new Promise((resolve,reject)=>s.addEventListener('abort',()=>reject(Error('aborted')),{once:true}));}})};
 const controller=new w.AbortController(),request=w.StaffChat.rpc('fixture',{},controller.signal);controller.abort();await assert.rejects(request);assert(signal.aborted);
 console.log('PASS: pause/cancel active request, no automatic resume, same ID resume, next send unblocked, RPC abort propagation');
 }finally{box.close();w.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
