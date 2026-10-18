const {JSDOM}=require('jsdom'),fs=require('fs'),assert=require('node:assert/strict');
const read=p=>fs.readFileSync(p,'utf8');
const dom=new JSDOM(read('staff-chat.html').replace(/<script[\s\S]*?<\/script>/g,''),{url:'https://omgworks24.com/staff-chat.html?peer=employee:11111111-1111-4111-8111-111111111111',runScripts:'outside-only',pretendToBeVisual:true}),w=dom.window,d=w.document;
let release,fail=false;
w.setTimeout=()=>0;w.clearTimeout=()=>{};
w.omgSession={require:async()=>({accessToken:'fixture'})};w.omgNotifications={send:async()=>{}};w.GuestSupport={esc:s=>String(s??'')};
w.omgSupabase={rpc:async(name,args)=>{if(args?.p_action==='send'){await new Promise(r=>release=r);if(fail)return {error:{message:'network'}};return {data:{ok:true,message_id:'saved'}};}return {data:{ok:true,can_send:true,peer:{display_name:'직원'},profile:{display_name:'직원'},messages:[]}};}};
w.OMGPhoto={media:async()=>({type:'image/jpeg',size:1})};w.FileReader=class{readAsDataURL(){this.result='data:image/jpeg;base64,eA==';this.onload();}};
w.eval(read('staff-chat-client.js'));w.eval(read('photo-viewer-zoom.js'));w.eval(read('staff-chat.js'));
const flush=()=>new Promise(setImmediate),send=d.getElementById('send'),input=d.getElementById('body');
const type=value=>{input.value=value;input.dispatchEvent(new w.Event('input',{bubbles:true}));};
(async()=>{try{
 await flush();assert(send.disabled,'empty composer');type(' \n ');assert(send.disabled,'whitespace');type('😀');assert(!send.disabled,'emoji input');type('');assert(send.disabled,'cleared input');
 const file=d.getElementById('photoInput');Object.defineProperty(file,'files',{configurable:true,value:[{type:'image/jpeg'}]});file.dispatchEvent(new w.Event('change'));await flush();assert(!send.disabled,'attachment alone enables send');d.querySelector('#photoPending button').click();assert(send.disabled,'removing last attachment disables send');
 type('답장');d.getElementById('composer').dispatchEvent(new w.Event('submit',{cancelable:true}));assert(send.disabled,'sending is disabled');release();await flush();await flush();assert(send.disabled&&input.value==='','sent message clears and dims send');
 fail=true;type('보존');d.getElementById('composer').dispatchEvent(new w.Event('submit',{cancelable:true}));release();await flush();assert(!send.disabled&&input.value==='보존','failed draft stays enabled for retry');
 assert(/#send:disabled\{opacity:\.35/.test(read('staff-chat.css')),'disabled send is visibly dimmed');
 console.log('PASS: web send state tracks empty/whitespace/emoji/attachment/removal/sending/success/retry');
}finally{w.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
