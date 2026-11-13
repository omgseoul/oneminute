const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
(async()=>{
 const w=new JSDOM(fs.readFileSync('online.html','utf8').replace(/<script[\s\S]*?<\/script>/g,''),{url:'https://omgworks24.com/online.html#inbox',runScripts:'outside-only',pretendToBeVisual:true}).window;
 const calls=[];let poll;const rows=[{booking_id:10,message_id:20,guest_name:'Guest A',unread:3,replied:false,needs_reply:true,stay:'checkin'},{booking_id:11,message_id:21,guest_name:'Guest B',unread:0,replied:true,needs_reply:false,stay:'staying'},{booking_id:12,message_id:22,guest_name:'Guest C',unread:1,replied:false,needs_reply:true,stay:'checkout'}].map((x,i)=>({...x,status:'confirmed',source:'guest',channel:'Booking.com',preview:'Question '+i,sent_at:new Date(Date.now()-i*1000).toISOString()}));
 w.omgSession={require:async()=>({sessionKind:'owner',accessToken:'fixture',propertyId:'home'})};w.OMG_SUPABASE={url:'https://fixture.supabase.co',publishableKey:'public'};w.AbortSignal=AbortSignal;w.setInterval=f=>{poll=f;};
 w.fetch=async(u,o)=>{const {action,data}=JSON.parse(o.body);calls.push({action,data});let v={ok:true};
  if(action==='settings')v={ok:true,property_id:'home',property_name:'One Minute',timezone:'Asia/Seoul',branches:[{id:'home',name:'One Minute'}],properties:[],synced_at:new Date().toISOString()};
  if(action==='inbox')v={ok:true,synced_at:new Date().toISOString(),threads:rows.filter(r=>(!data.unread_only||r.unread>0)&&(!data.unreplied_only||r.needs_reply)&&(!data.stay_types||data.stay_types.includes(r.stay))).map(r=>({...r}))};
  if(action==='unread')v={ok:true,unread:rows.reduce((n,r)=>n+r.unread,0)};
  if(action==='read_message')rows.find(r=>r.message_id===data.message_id).unread=0;
  if(action==='send'){const r=rows.find(r=>r.booking_id===data.booking_id);r.replied=true;r.needs_reply=false;v={ok:true,status:'sent'};}
  return {ok:true,json:async()=>v};
 };
 for(const file of ['property-selector.js','select-picker.js','online.js'])w.eval(fs.readFileSync(file,'utf8'));
 const tick=()=>new Promise(r=>setTimeout(r,50));await tick();await tick();const $=q=>w.document.querySelector(q);
 assert($('#inboxCount').closest('.inbox-meta-row'));assert(!$('#inboxCount').closest('.inbox-toolbar'));
 assert.deepEqual([...w.document.querySelectorAll('[data-stay]')].map(e=>e.parentElement.textContent),['All','오늘체크인','숙박중','오늘체크아웃','그외 기간']);
 assert($('.inbox-item[data-booking="home:11"] .inbox-replied'),'replied incoming message has reply marker');
 $('#unreadOnlyButton').click();await tick();assert.equal(w.document.querySelectorAll('.inbox-item').length,2);assert(calls.filter(x=>x.action==='inbox').at(-1).data.unread_only);
 let card=$('.inbox-item[data-booking="home:10"]');card.open=true;await tick();await tick();card=$('.inbox-item[data-booking="home:10"]');assert(card?.open,'open reading remains visible after it no longer matches unread filter');assert(!card.querySelector('.badge'),'read count vanishes immediately');assert.equal(rows[0].unread,0);card.open=false;await tick();await tick();assert(!$('.inbox-item[data-booking="home:10"]'),'read item exits filter when collapsed');
 $('#unreadOnlyButton').click();await tick();$('#unrepliedOnlyButton').click();await tick();assert.equal(w.document.querySelectorAll('.inbox-item').length,2);
 card=$('.inbox-item[data-booking="home:10"]');card.open=true;await tick();const form=card.querySelector('form'),input=form.querySelector('textarea');input.value='Confirmed reply';input.dispatchEvent(new w.Event('input'));form.dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();await tick();card=$('.inbox-item[data-booking="home:10"]');assert(card?.open,'sending reply keeps the open composer visible');assert(card.querySelector('.inbox-replied'),'successful send immediately displays reply marker');card.open=false;await tick();await tick();assert(!$('.inbox-item[data-booking="home:10"]'),'replied item exits unanswered filter when collapsed');
 rows[0]={...rows[0],message_id:60,unread:1,replied:false,needs_reply:true,sent_at:new Date().toISOString()};await poll();card=$('.inbox-item[data-booking="home:10"]');assert(card&&!card.querySelector('.inbox-replied'),'new guest question removes reply marker');assert(card.querySelector('.badge'));
 $('#unreadOnlyButton').click();await tick();assert(calls.filter(x=>x.action==='inbox').at(-1).data.unread_only&&calls.filter(x=>x.action==='inbox').at(-1).data.unreplied_only,'toggles combine with AND');
 $('[data-stay=all]').click();await tick();assert.equal(w.document.querySelectorAll('.inbox-item').length,0);$('[data-stay=checkin]').click();await tick();$('[data-stay=checkout]').click();await tick();assert.deepEqual(calls.filter(x=>x.action==='inbox').at(-1).data.stay_types,['checkin','checkout']);
 assert.equal(calls.filter(x=>x.action==='sync_messages').length,0,'filters and reads use stored data only');w.close();console.log('Inbox follow-up UI: layout placement, combined filters, read counters, pinned reading, sent reply and new incoming reset passed');
})().catch(e=>{console.error(e);process.exit(1)});
