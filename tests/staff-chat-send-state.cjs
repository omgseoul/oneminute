const {JSDOM}=require('jsdom'),fs=require('fs'),assert=require('node:assert/strict');
const read=p=>fs.readFileSync(p,'utf8');
const dom=new JSDOM(read('staff-chat.html').replace(/<script[\s\S]*?<\/script>/g,''),{url:'https://omgworks24.com/staff-chat.html?peer=employee:11111111-1111-4111-8111-111111111111',runScripts:'outside-only',pretendToBeVisual:true}),w=dom.window,d=w.document;
require('./chat-realtime/jsdom-env.cjs')(w);
let release,fail=false,calls=[],saved=new Map();w.setTimeout=()=>0;w.clearTimeout=()=>{};
w.omgSession={require:async()=>({accessToken:'fixture'})};w.omgNotifications={send:async()=>{throw Error('Client must not dispatch push');}};w.GuestSupport={esc:s=>String(s??'')};
w.omgSupabase={rpc:async(name,args)=>{if(args?.p_action==='send'){calls.push(args.p_data);await new Promise(r=>release=r);const a=args.p_data;const message={id:a.client_id,client_id:a.client_id,mine:true,body:a.body,created_at:new Date().toISOString()};saved.set(a.client_id,message);if(fail)return {error:{message:'network'}};return {data:{ok:true,message_id:a.client_id,message}};}return {data:{ok:true,can_send:true,peer:{display_name:'직원'},profile:{display_name:'직원'},messages:[]}};}};
w.OMGPhoto={media:async()=>({type:'image/jpeg',size:1})};w.FileReader=class{readAsDataURL(){this.result='data:image/jpeg;base64,eA==';this.onload();}};
for(const file of ['staff-chat-client.js','photo-viewer-zoom.js','staff-chat.js'])w.eval(read(file));
const flush=()=>new Promise(setImmediate),until=async f=>{for(let i=0;i<100;i++){if(f())return;await flush();}assert(f(),'condition timed out');},send=d.getElementById('send'),input=d.getElementById('body');
const type=value=>{input.value=value;input.dispatchEvent(new w.Event('input',{bubbles:true}));};const submit=()=>d.getElementById('composer').dispatchEvent(new w.Event('submit',{cancelable:true}));
(async()=>{try{
 await until(()=>!input.disabled);for(let i=0;i<15;i++)await flush();assert(send.disabled);type(' \n ');assert(send.disabled);type('😀');assert(!send.disabled);type('');assert(send.disabled);
 const file=d.getElementById('photoInput');Object.defineProperty(file,'files',{configurable:true,value:[{type:'image/jpeg'}]});file.dispatchEvent(new w.Event('change'));await flush();assert(!send.disabled);d.querySelector('#photoPending button').click();assert(send.disabled);
 type('답장');submit();await until(()=>calls.length===1);await until(()=>input.value==='');assert(d.querySelector('[data-retry]'),'pending bubble visible before RPC reply');type('다음 초안');assert(!send.disabled,'next input enabled while prior send is in flight');release();await until(()=>!d.querySelector('[data-retry]'));assert.equal(input.value,'다음 초안');assert.equal(d.querySelectorAll('.mine').length,1);
 fail=true;type('보존');submit();await until(()=>calls.length===2);release();await until(()=>d.querySelector('[data-retry]')?.textContent.includes('실패'));const id=calls[1].client_id;fail=false;d.querySelector('[data-retry]').click();await until(()=>calls.length===3);assert.equal(calls[2].client_id,id);release();await until(()=>!d.querySelector('[data-retry]'));assert.equal(saved.size,2);assert.equal(d.querySelectorAll('.mine').length,2);assert.equal(input.value,'');
 console.log('PASS: durable immediate bubbles, concurrent draft, saved/failed states, ambiguous retry without duplicates, attachments, no client push');
}finally{w.dispatchEvent(new w.Event('pagehide'));w.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
