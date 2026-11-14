const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const html=fs.readFileSync('app.html','utf8'),start=html.indexOf('async function loadMessageSummary('),end=html.indexOf('\nasync function loadMissionSummary',start);
(async()=>{
 const w=new JSDOM('<span id="messageCounter"></span><span id="guestMessageCounter"></span>',{url:'https://omgworks24.com/app.html',runScripts:'outside-only',pretendToBeVisual:true}).window;
 const session={ownerId:'owner',propertyId:'home',accessToken:'fixture',timezone:'Asia/Seoul'};let guest=31,staff=12,reports=4,owner=true,fail=false,query;
 w.OMGNative={setMessageBadge:(token,count)=>{assert.equal(token,'fixture');w.badge=count;},setMessageBadgeQuery:(token,data)=>{query=JSON.parse(data);}};
 w.omgSession={get:()=>session};w.OMSHomeSnapshot={write(){}};w.HomeMessageQueue={update(){}};
 w.omgSupabase={rpc:async(name,args)=>{
  if(name==='guest_message_summary')return {data:{ok:true,unread:guest,messenger_unread:staff,total_unread:830}};
  if(name==='list_property_messages')return {data:{ok:true,can_manage:owner,messages:[],unread_count:846}};
  if(name==='work_report_inbox')return fail?{error:{message:'offline'}}:{data:{ok:true,unread_count:reports,reports:[]}};
  throw Error(name);
 }};
 w.eval(fs.readFileSync('home-guest-count.js','utf8'));
 w.eval('let messageSummaryVersion=0,lastUnreadCount,lastReportCount;'+html.slice(start,end));
 const refresh=()=>w.loadMessageSummary('fixture',false,()=>true,session);
 await refresh();assert.equal(w.badge,47);assert.equal(w.document.querySelector('#messageCounter').textContent,'16');assert.equal(w.document.querySelector('#guestMessageCounter').textContent,'31');assert.equal(query.period.days,7);
 guest=0;await refresh();assert.equal(w.badge,16,'zero filtered guests must never fall back to 830 unfiltered guests');
 owner=false;guest=3;await refresh();assert.equal(w.badge,15,'staff total has no owner report count');
 w.localStorage.setItem('oms-online-inbox-filters:owner',JSON.stringify({version:1,qrVersion:1,statuses:['qr'],properties:['branch'],direction:'guest',stayTypes:['staying'],unreadOnly:true}));
 w.localStorage.setItem('oms-online-period:owner',JSON.stringify({days:3,from:'',to:''}));await refresh();assert.deepEqual(query.filters.statuses,['qr']);assert.deepEqual(query.filters.properties,['branch']);assert.equal(query.filters.direction,'guest');assert.equal(query.period.days,3,'rolling range must remain rolling for native midnight refresh');
 w.localStorage.setItem('oms-online-period:owner',JSON.stringify({days:0,from:'2026-11-01',to:'2026-11-03'}));await refresh();assert.deepEqual(query.period,{days:0,from:'2026-11-01',to:'2026-11-03'});
 owner=true;fail=true;guest=100;await refresh();assert.equal(w.badge,15,'partial network failures preserve last complete sum');
 fail=false;staff=0;reports=0;guest=0;await refresh();assert.equal(w.badge,0,'all read clears badge');w.close();
 console.log('PASS badge equals guest + staff menu counters, excludes historical/double counts, preserves filters and complete snapshots');
})().catch(e=>{console.error(e);process.exitCode=1;});
