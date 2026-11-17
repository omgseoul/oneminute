const {JSDOM}=require('jsdom'),fs=require('fs'),assert=require('node:assert/strict');
const html=fs.readFileSync('app.html','utf8').replace(/<script[\s\S]*?<\/script>/g,'');
const w=new JSDOM(html,{url:'https://omgworks24.com/app.html',runScripts:'outside-only'}).window;
let now=1000,next=0;const timers=new Map(),receipts=[];
w.Date.now=()=>now;w.setTimeout=(fn,delay)=>{timers.set(++next,{fn,at:now+delay});return next;};w.clearTimeout=id=>timers.delete(id);
function advance(ms){now+=ms;for(const [id,t] of [...timers])if(t.at<=now){timers.delete(id);t.fn();}}
w.omgSupabase={rpc:async(_,args)=>{receipts.push(args.p_message_id);return{data:{ok:true}};}};
w.eval(fs.readFileSync('home-message-queue.js','utf8'));
const popup=()=>w.document.getElementById('messageArrival');
const item=id=>({message_id:id,message:'Unread '+id});
(async()=>{
 w.HomeMessageQueue.add([item('a'),item('b')],'owner');advance(299999);assert.equal(popup().hidden,false);
 w.HomeMessageQueue.add([item('c'),item('a')],'owner');advance(1);assert.equal(popup().hidden,true,'incoming alerts cannot extend the five-minute budget');
 assert.deepEqual(receipts,[],'timeout must not mark any message read');
 w.HomeMessageQueue.add([item('a'),item('b'),item('c')],'owner');assert.equal(popup().hidden,true,'refresh and retry cannot reopen timed-out alerts');
 w.HomeMessageQueue.add([item('d')],'owner');advance(299999);assert.equal(popup().hidden,false);advance(1);assert.equal(popup().hidden,true,'new alert receives a fresh five-minute budget');
 w.HomeMessageQueue.add([item('e')],'owner');advance(1000);w.HomeMessageQueue.add([item('other')],'staff');advance(299000);assert.equal(popup().hidden,false,'old account timer is cancelled');advance(1000);assert.equal(popup().hidden,true);
 w.HomeMessageQueue.add([item('read')],'staff');w.document.querySelector('.message-arrival-confirm').click();await Promise.resolve();await Promise.resolve();assert.deepEqual(receipts,['read']);advance(300000);assert.equal(popup().hidden,true);
 w.HomeMessageQueue.add([item('sleep')],'staff');now+=300000;Object.defineProperty(w.document,'hidden',{value:false,configurable:true});w.document.dispatchEvent(new w.Event('visibilitychange'));assert.equal(popup().hidden,true,'resuming a throttled background tab expires overdue popup');
 console.log('PASS: five-minute expiry, batch dismissal, no timeout read receipts, duplicate suppression, fresh arrivals, account switch and background resume');w.close();
})().catch(e=>{console.error(e);w.close();process.exitCode=1;});
