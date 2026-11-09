const fs=require('fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom'),{parse}=require('../../reminder-popup.js');
const instant=new Date('2026-11-07T00:00Z');
for(const [body,heading,timing,title] of [
 ['To do 알림\n2일 지연: 냉장고 정리','지연된 업무','(2일 지연)','냉장고 정리'],
 ['To do 알림\n오늘: 청소','To do 알림','(오늘)','청소'],
 ['To do 알림\n3일 후: 정리','To do 알림','(3일 후)','정리'],
 ['일정 알림\n내일: 회의','일정 알림','(1일 후)','회의'],
 ['일정 알림\n등록: 회의\n일정: 2026-11-07 14:00\n시간대: Asia/Seoul','일정 알림','(오늘)','회의'],
 ['To do 알림\n내일: 청소\n마감: 2026-11-06 14:00\n시간대: Asia/Seoul','지연된 업무','(1일 지연)','청소'],
 ['To do 알림\n오늘: 청소\n마감: 2026-11-07 14:00\n시간대: America/New_York','To do 알림','(1일 후)','청소']]){const r=parse(body,'OMS 도우미',instant);assert.equal(r.heading,heading);assert.equal(r.timing,timing);assert.equal(r.title,title);}
assert.equal(parse('일반 메시지','직원'),null);assert.equal(parse('To do 알림\\n오늘: 청소').title,'청소');assert.equal(parse('To do 알림\n지연: 예전 업무').timing,'','legacy data must not invent days');
const html=fs.readFileSync('app.html','utf8').replace(/<script[\s\S]*?<\/script>/g,'');
const w=new JSDOM(html,{url:'https://omgworks24.com/app.html',runScripts:'outside-only'}).window;w.omgSupabase={rpc:async()=>({data:{ok:true}})};
for(const f of ['reminder-popup.js','home-message-queue.js','checkout-warning.js'])w.eval(fs.readFileSync(f,'utf8'));
(async()=>{
w.HomeMessageQueue.add([{message_id:'1',sender_label:'OMS 도우미',message:'To do 알림\n2일 지연: 냉장고 정리'},{message_id:'2',sender_label:'직원',message:'안녕하세요'}],'test');
assert.equal(w.document.querySelector('.reminder-banner').textContent,'지연된 업무(2일 지연)');assert(w.document.querySelector('#messageArrivalDog').src.endsWith('oms-dog-overdue-plain.webp'));assert.equal(w.document.querySelector('#messageArrivalBody').textContent,'냉장고 정리');w.document.querySelector('.message-arrival-confirm').click();assert(!w.document.querySelector('#messageArrival').classList.contains('is-reminder'),'ordinary message styling resets');assert(w.document.querySelector('.reminder-banner').hidden);assert(w.document.querySelector('#messageArrivalDog').src.endsWith('shiba-worker-logo.png'),'new-message bubble retained');
const calls=[],rpc=async(n,args)=>{calls.push(n);return{ok:true}};
let pending=w.OMSCheckoutWarning.confirm(rpc,'token',[{message:'경고',rule_id:'1',rule_updated_at:'now'}]);w.document.querySelector('[data-confirm]').click();await pending;assert.deepEqual(calls,['confirm_checkout_warning']);
pending=w.OMSCheckoutWarning.confirm(rpc,'token',[{message:'경고'}]);w.document.querySelector('[data-cancel]').click();await assert.rejects(pending,/취소/);assert.equal(calls.length,1,'cancel does not acknowledge');
console.log('PASS reminder parser, popup transitions and checkout acknowledgement/cancel');w.close();
})().catch(e=>{console.error(e);process.exitCode=1});
