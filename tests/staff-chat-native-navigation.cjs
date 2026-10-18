const {JSDOM}=require('jsdom'),fs=require('fs'),assert=require('node:assert/strict');
const read=f=>fs.readFileSync(f,'utf8');
const html='<main><div class="top"><div id="messageTopActions"><button id="refresh"></button></div></div><header class="head"></header><div class="mail-tabs"></div><div id="messageSearch" hidden><input id="messageSearchInput"></div><div id="list"></div><div id="detail" hidden></div><div id="composeOverlay" hidden></div><button id="searchToggle"></button><button id="composeToggle"></button></main>';
async function checkHub(native){
 const dom=new JSDOM(html,{runScripts:'outside-only',url:'https://omgworks24.com/messages.html',pretendToBeVisual:true}),w=dom.window,d=w.document;
 let launches=[],selected,details=[],reportVisible=false;
 w.setTimeout=()=>0;w.clearTimeout=()=>{};
 if(native)w.OMGNative={openStaffChat:(peer,properties)=>{launches.push({peer,properties:JSON.parse(properties)});return true;}};
 w.GuestSupport={esc:s=>String(s??'').replaceAll('<','&lt;'),call:async()=>({rooms:[],properties:[{id:'home',name:'본점'},{id:'remote',name:'타지점'}]})};
 const room={peer:'employee:11111111-1111-4111-8111-111111111111',name:'직원',preview:'확인했습니다',property_id:'remote',property_name:'타지점',updated_at:'2026-10-18T00:00:00Z',unread:1};
 const notice={message_id:'notice',property_id:'home',created_at:'2026-10-18T01:00:00Z',message:'공지 내용',message_type:'announcement',require_signature:false,require_understanding:false};
 w.omgSupabase={rpc:async(name)=>({data:{ok:true,rooms:[room],properties:[],bots:[{property_id:'home',display_name:'OMS 알림',property_name:'본점'}],messages:[notice],unread_by_property:{home:1}}})};
 w.omgPropertySelector={mountStatic:options=>{selected=options.onChange;}};
 w.ReportInbox={init(){},show(value){reportVisible=value;},setProperties(){},search(){},refreshCount(){},load(){}};
 w.eval(read('staff-chat-client.js'));w.eval(read('notification-bot.js'));w.eval(read('message-hub.js'));
 await w.MessageHub.init({propertyId:'home',accessToken:'fake'},{mailbox(){},clearSearch(){},render(){},compose(){},load(){},openDetail:item=>details.push(item)});
 const flush=async()=>{for(let i=0;i<12;i++)await Promise.resolve();};await flush();
 const tabs=d.querySelector('.hub-tabs'),property=d.getElementById('hubProperty');
 const click=tab=>d.querySelector('[data-hub='+tab+']').click();
 click('staff');await flush();
 assert.equal(launches.length,0,'staff tab must stay inside the shared hub even in the app');
 assert.equal(d.getElementById('staffPane').hidden,false);assert.equal(tabs,d.querySelector('.hub-tabs'));assert.equal(property,d.getElementById('hubProperty'));
 if(native){const event=new w.MouseEvent('click',{bubbles:true,cancelable:true,button:0});d.querySelector('.staff-room:not(.bot-room)').dispatchEvent(event);assert(event.defaultPrevented,'room link hands off without loading a web chat page');assert.equal(launches.length,1);launches=[];}
 assert(d.querySelector('.bot-room'),'the real notification bot must remain in the staff list');assert.match(d.querySelector('.staff-room-property').textContent,/타지점/);
 d.querySelector('.bot-room').click();assert.equal(d.getElementById('botConversation').hidden,false);assert.match(d.getElementById('botTimeline').textContent,/공지 내용/);
 d.querySelector('[data-bot-message]').click();assert.equal(details[0].message_id,'notice','bot actions retain the existing detail/acknowledgement flow');
 click('reports');assert.equal(reportVisible,true);click('approvals');assert.equal(d.getElementById('list').hidden,false);click('guest');assert.equal(d.getElementById('guestPane').hidden,false);click('staff');
 assert.equal(tabs,d.querySelector('.hub-tabs'),'all tabs retain the same navigation element');
 selected(['home']);await flush();assert.equal(d.querySelector('.staff-room:not(.bot-room)'),null,'branch filtering remains active');assert(d.querySelector('.bot-room'));
 assert.equal(w.StaffChat.nativeOpen(''),false,'empty peer must never open the removed native list');
 const opened=w.StaffChat.nativeOpen(room.peer,['remote']);assert.equal(opened,native);
 if(native){assert.deepEqual(launches,[{peer:room.peer,properties:['remote']}]);w.OMGNative.openStaffChat=()=>false;assert.equal(w.StaffChat.nativeOpen(room.peer),false,'failed bridge retains web fallback');}
 dom.window.close();
}
(async()=>{await checkHub(true);await checkHub(false);console.log('PASS: Android/browser share hub tabs, branch filter, actual bot list/detail actions; only individual rooms hand off to native');})().catch(error=>{console.error(error);process.exitCode=1;});
