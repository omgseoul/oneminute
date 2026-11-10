const {JSDOM}=require('jsdom'),{indexedDB}=require('fake-indexeddb'),fs=require('fs'),assert=require('node:assert/strict');
const tick=()=>new Promise(resolve=>setTimeout(resolve,5));
async function until(condition){for(let n=0;n<200;n++){if(condition())return;await tick();}assert.fail('Timed out');}
(async()=>{
 const w=new JSDOM('',{url:'https://omgworks24.com',runScripts:'outside-only'}).window;
 w.indexedDB=indexedDB;w.eval(fs.readFileSync('chat-outbox.js','utf8'));
 let release,releaseText;const calls=[];
 const box=await w.OMSChatOutbox.open('queue-isolation',async item=>{
  calls.push({id:item.client_id,body:item.body});
  if(item.body==='stalled text')await new Promise(resolve=>releaseText=resolve);
  if(item.body==='stalled video'){await new Promise(resolve=>release=resolve);throw Error('timeout');}
  return {message_id:item.client_id};
 },()=>{});
 try{
  const video=await box.enqueue({peer:'a',body:'stalled video',photo:'data:video/mp4;base64,AAAA'});
  await until(()=>release);
  await box.enqueue({peer:'a',body:'text'});
  await box.enqueue({peer:'b',body:'other video',photo:'data:video/mp4;base64,AAAA'});
  await until(()=>calls.length===3);
  assert.deepEqual(calls.map(c=>c.body),['stalled video','text','other video']);
  box.retry(video.client_id);assert.equal(calls.length,3,'retry during send is ignored');
  release();await until(()=>video.status==='failed');
  for(let n=0;n<5;n++){box.pump();await tick();}assert.equal(calls.length,3,'no automatic failure retry');
  await box.retry(video.client_id);await until(()=>calls.length===4);assert.equal(calls[3].id,video.client_id);
  release();await until(()=>video.status==='failed');await box.cancel(video.client_id);
  assert(!box.items('a').some(item=>item.client_id===video.client_id));
  await box.enqueue({peer:'a',body:'stalled text'});await until(()=>releaseText);
  await box.enqueue({peer:'b',body:'other text'});
  await until(()=>calls.some(c=>c.body==='other text'));releaseText();
  console.log('PASS: stalled media isolation, same-room text, other-room media, manual retry with stable ID, cancellation');
 }finally{box.close();w.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
