const {JSDOM}=require('jsdom'),fs=require('fs'),assert=require('node:assert/strict');
const read=p=>fs.readFileSync(p,'utf8'),tick=()=>new Promise(setImmediate),html=read('staff-chat.html').replace(/<script[\s\S]*?<\/script>/g,'');
const dom=new JSDOM(html,{url:'https://omgworks24.com/staff-chat.html?peer=employee:11111111-1111-4111-8111-111111111111',runScripts:'outside-only',pretendToBeVisual:true}),w=dom.window,d=w.document;
let loads=0,nextLoad,reads=[];w.setTimeout=(fn,delay)=>{if(delay===2000)nextLoad=fn;return 0;};w.clearTimeout=()=>{};d.hasFocus=()=>true;
w.HTMLElement.prototype.getBoundingClientRect=function(){if(this.id==='timeline')return {top:0,bottom:500,height:500};return this.dataset.id==='hidden'?{top:-200,bottom:-100,height:100}:{top:100,bottom:200,height:100};};
w.GuestSupport={esc:v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))};w.omgSession={require:async()=>({accessToken:'test'})};w.omgNotifications={send:async()=>{}};
w.omgSupabase={rpc:async(name,args)=>{if(name==='staff_chat_peer_profile')return {data:{ok:true,profile:{display_name:'상대 직원',profile_image:'data:image/png;base64,AAAA'}}};if(args.p_action==='read'){reads.push(...args.p_data.ids);return{data:{ok:true}};}loads++;return{data:{ok:true,can_send:true,peer:{display_name:'직원'},messages:loads===1?[
 {id:'hidden',created_at:'2026-10-19T00:00:00Z',body:'안 보이는 이전 대화',mine:false,read_at:null},
 {id:'received',created_at:'2026-10-19T00:01:00Z',body:'[시바:ㅋㅋㅋ]',mine:false,read_at:null},
 {id:'sent',created_at:'2026-10-19T00:02:00Z',body:'[시바:청소 완료]',mine:true,read_at:null}
]:[],receipts:loads===1?[]:[{id:'sent',read_at:'2026-10-19T00:03:00Z'}]}};}};
for(const file of ['shiba-stickers.js','staff-chat-client.js','photo-viewer-zoom.js','staff-chat.js'])w.eval(read(file));
(async()=>{try{
 await tick();await tick();assert.equal(d.querySelectorAll('.message-avatar').length,2);assert.equal(d.querySelector('.mine .message-avatar'),null);assert.equal(d.querySelector('.mine .bubble-name'),null);assert.equal(d.querySelector('[data-id=received] .bubble-name').textContent,'상대 직원');assert.equal(d.querySelectorAll('.oms-sticker').length,2);assert.equal(d.querySelector('.message-unread').textContent,'1');assert.deepEqual(reads,['received']);
 d.querySelector('[data-id=received] .message-avatar').click();assert(d.getElementById('peerProfileDialog').hasAttribute('open'));d.getElementById('peerProfileClose').click();assert(!d.getElementById('peerProfileDialog').hasAttribute('open'));
 await nextLoad();await tick();assert.equal(d.querySelector('.message-unread'),null,'receipt-only incremental response removes 1');assert.equal(d.querySelectorAll('.bubble-row').length,3,'receipts preserve history');
 assert.equal(w.StaffChat.cleanText('[시바:방긋]'),'🐕 방긋');assert.match(w.StaffChat.contractBody('<img src=x onerror=alert(1)>[시바:방긋]'),/^&lt;img/);assert.equal(w.StaffChat.contractBody('[시바:없는 그림]'),'[시바:없는 그림]');
 console.log('PASS: received-only identity/avatar profile, local sticker rendering, visible-only reads, receipt-only update, preserved history, escaped text and unknown sticker fallback');
}finally{w.close();}})().catch(error=>{console.error(error);process.exitCode=1});
