const {JSDOM}=require('jsdom'),{indexedDB}=require('fake-indexeddb'),fs=require('fs'),assert=require('node:assert/strict');
const wait=async f=>{for(let i=0;i<100;i++){if(f())return;await new Promise(r=>setTimeout(r,5));}assert(f());};
function windowFor(){const w=new JSDOM('',{url:'https://omgworks24.com',runScripts:'outside-only'}).window;w.indexedDB=indexedDB;w.eval(fs.readFileSync('chat-outbox.js','utf8'));return w;}
(async()=>{
 const a=windowFor();Object.defineProperty(a.navigator,'onLine',{value:false,configurable:true});let calls=[];
 const first=await a.OMSChatOutbox.open('account-a',async()=>{throw Error('offline')},()=>{});
 await first.enqueue({peer:'peer-a',body:'one'});await first.enqueue({peer:'peer-a',body:'two'});const ids=first.items('peer-a').map(x=>x.client_id);first.close();a.close();
 const b=windowFor(),reopened=await b.OMSChatOutbox.open('account-a',async item=>{calls.push(item.body);return {message_id:item.client_id,message:{id:item.client_id,client_id:item.client_id}}},()=>{});
 await wait(()=>calls.length===2);assert.deepEqual(calls,['one','two']);assert.deepEqual(Array.from(reopened.items('peer-a'),x=>x.client_id),Array.from(ids));
 const isolated=await b.OMSChatOutbox.open('account-b',async()=>{throw Error('wrong account')},()=>{});assert.equal(isolated.items('peer-a').length,0);
 await reopened.acknowledge(ids.map(id=>({id,client_id:id})));assert.equal(reopened.items('peer-a').length,0);reopened.close();isolated.close();b.close();
 console.log('PASS: offline disk persistence across page restart, ordered retry, same IDs, account isolation, reconciliation cleanup');
})().catch(e=>{console.error(e);process.exitCode=1;});
