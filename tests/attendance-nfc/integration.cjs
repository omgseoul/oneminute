const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const wait=()=>new Promise(resolve=>setTimeout(resolve,20));
(async()=>{
 const html=fs.readFileSync('owner-settings.html','utf8'),dom=new JSDOM(html.replace(/<script[\s\S]*?<\/script>/g,''),{url:'https://omgworks24.com/owner-settings.html',runScripts:'outside-only'}),w=dom.window,d=w.document;
 let selected,writes=[];const state={own:{basis:'report',report_offset_minutes:-10,nfc_tags:[]},shared:{basis:'nfc',report_offset_minutes:0,nfc_tags:['04112233445566']}};
 w.omgSession={require:async()=>({accessToken:'test-token',sessionKind:'owner'})};w.omgTransition={ready(){}};
 for(const name of ['work-config.js','property-selector.js','select-picker.js','attendance-nfc.js','attendance-settings.js'])w.eval(fs.readFileSync(name,'utf8'));
 w.omgWorkConfig.load=async(token,property)=>({can_manage:true,property:{property_id:property||'own',name:'Fixture',business_type:'general',rooms:[],room_types:[],custom_report_fields:[]},employees:[]});
 w.HolidaySettings={load:async()=>{},save:async()=>{},validate(){}};w.omgReminderSettings={mount(){},save:async()=>{}};w.omgPropertySelector.mountPropertySingle=async options=>{selected=options.onChange;};
 w.omgSupabase={rpc:async(name,args)=>{if(name==='attendance_clock_in_settings'){if(args.p_action==='save'){writes.push(args);state[args.p_property_id]=args.p_settings;}return {data:{ok:true,...state[args.p_property_id]}};}return {data:{ok:true,info:{},properties:[],granted_properties:[]}};}};
 for(const match of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g))if(match[1].trim())w.eval(match[1]);
 await wait();assert.equal(w.OMSAttendanceSettings.value().report_offset_minutes,-10);
 d.getElementById('attendanceOffset').value='-15';d.querySelector('[data-save-scope="attendance"]').click();await wait();assert.equal(writes[0].p_settings.report_offset_minutes,-15);assert.equal(writes[0].p_property_id,'own');
 await selected('shared');assert.equal(w.OMSAttendanceSettings.value().basis,'nfc');d.querySelector('.attendance-nfc-value button').click();d.querySelector('[data-save-scope="attendance"]').click();await wait();assert.equal(writes.length,1,'cannot save empty NFC');
 d.querySelector('[name=clockInBasis][value=report]').click();d.getElementById('attendanceOffset').value='0';d.querySelector('[data-save-scope="attendance"]').click();await wait();assert.equal(writes[1].p_property_id,'shared');assert.equal(writes[1].p_settings.basis,'report');dom.window.close();
 // Worker flow: native UID goes only to the current server-authenticated session;
 // failed network calls never show an entry confirmation, and page exit stops reading.
 const worker=new JSDOM('<div id="host"></div>',{url:'https://omgworks24.com/app.html',runScripts:'outside-only'}),v=worker.window;
 const session={accessToken:'staff',sessionKind:'staff',timezone:'Asia/Seoul'};let request,calls=[],fail=true;
 v.omgSession={get:()=>session};v.OMGNative={startAttendanceNfc(id){request=id;},stopAttendanceNfc(){}};
 v.omgSupabase={rpc:async(name,args)=>{calls.push(args);return args.p_tag_uid?(fail?{error:{message:'offline'}}:{data:{ok:true,basis:'nfc',entry_at:'2026-10-24T00:00:00Z',status:'working'}}):{data:{ok:true,basis:'nfc',status:'working',entry_at:null}};}};
 v.eval(fs.readFileSync('attendance-nfc.js','utf8'));await v.OMSAttendanceNfc.mountWorker(session,v.document.getElementById('host'));
 v.dispatchEvent(new v.CustomEvent('omg:nfc-result',{detail:{request_id:request,uid:'04112233445566'}}));await wait();assert(!v.document.body.textContent.includes('입장 확인'));fail=false;v.document.querySelector('button').click();v.dispatchEvent(new v.CustomEvent('omg:nfc-result',{detail:{request_id:request,uid:'04112233445566'}}));await wait();assert(v.document.body.textContent.includes('입장 확인'));assert(v.document.querySelector('button').hidden);assert.equal(calls.at(-1).p_access_token,'staff');assert.deepEqual(Object.keys(calls.at(-1)).sort(),['p_access_token','p_tag_uid']);worker.window.close();
 const done=new JSDOM('<div id="host"></div>',{url:'https://omgworks24.com/app.html',runScripts:'outside-only'}),z=done.window;let readAgain=false;
 z.omgSession={get:()=>session};z.OMGNative={startAttendanceNfc(){readAgain=true;},stopAttendanceNfc(){}};z.omgSupabase={rpc:async()=>({data:{ok:true,basis:'nfc',entry_at:null,checkin_report_at:'2026-10-24T00:00:00Z',status:'working'}})};
 z.eval(fs.readFileSync('attendance-nfc.js','utf8'));await z.OMSAttendanceNfc.mountWorker(session,z.document.getElementById('host'));assert(!readAgain,'already reported shifts do not request a new tag after settings change');assert(z.document.querySelector('.attendance-nfc-worker').hidden);done.window.close();
 console.log('PASS: real owner-page load/save and branch selection, worker server confirmation, offline retry, no device timestamp sent');
})().catch(error=>{console.error(error);process.exitCode=1;});
