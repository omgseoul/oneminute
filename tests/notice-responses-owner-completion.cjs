const fs=require('fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const read=f=>fs.readFileSync(f,'utf8'),tick=()=>new Promise(r=>setTimeout(r,0));
function create(file){const dom=new JSDOM(read(file),{url:'https://oms.test/'+file,runScripts:'outside-only'}),w=dom.window;w.omgSession={require:async()=>null};w.omgTransition={ready(){}};w.omgSelectPicker={mount(){}};return{dom,w,d:w.document};}
function inline(w){w.eval(read('worker-tasks.js'));for(const s of w.document.querySelectorAll('script:not([src])')){let tail='';if(s.textContent.includes('const selected=new Set()'))tail=';window.ntTest={setup(){session={accessToken:"owner",employeeName:"직원",propertyId:"p"};load=async()=>{};closeActiveLayer=()=>dismissLayers();},prepare(){recipientItems=[{recipient_key:"employee:e",employee_id:"e"}];selected.add("employee:e");}};';if(s.textContent.includes('let session=null,config=null,isOwner'))tail=';window.ntTest={setup(){session={accessToken:"owner",employeeName:"사장",employeeId:"e"};isOwner=true;loadMissions=async()=>{};},staff(){isOwner=false;session.employeeId="e";}};';w.eval(s.textContent+tail);}}
(async()=>{
 const {dom,w,d}=create('messages.html'),calls=[];
 w.StaffChat={cleanText:String,contractId:()=>null,contractBody:String};w.OMSAttendanceTime={range:()=>'-'};w.MessageHub={isStaff:()=>false,search(){},updateCounts(){}};w.omgNotifications={send:async()=>{}};
 w.omgSupabase={rpc:async(name,args)=>{calls.push({name,args});return{data:{ok:true,message_id:'m',employee_name:args?.p_employee_name,acknowledged_at:new Date().toISOString()}}}};
 w.eval(read('notice-composer.js'));w.eval(read('dialog-cards.js'));inline(w);await tick();w.ntTest.setup();
 assert.equal(d.querySelectorAll('.notice-response-options input[type="checkbox"]').length,2);assert(!d.querySelector('.notice-confirm-help'));assert.equal(d.getElementById('noticeRequireSignature').checked,false);
 for(const sig of [false,true])for(const understood of [false,true]){
  w.ntTest.prepare();
  d.getElementById('messageText').value='테스트 공지';d.getElementById('noticeRequireSignature').checked=sig;d.getElementById('noticeRequireUnderstanding').checked=understood;
  await d.getElementById('composer').onsubmit(new w.Event('submit',{cancelable:true}));const call=calls.at(-1);assert.equal(call.name,'send_configured_announcement');assert.equal(call.args.p_require_signature,sig);assert.equal(call.args.p_require_understanding,understood);
  const item={message_id:'notice',message_type:'announcement',sender_type:'owner',message:'공지',sender_label:'사장님',recipient_labels:['직원'],created_at:new Date().toISOString(),is_sender:false,require_signature:sig,require_understanding:understood};calls.length=0;
  await w.openDetail(item);
  assert.equal(d.getElementById('announcementConfirm').hidden,!(sig||understood));assert.equal(d.querySelector('.understood').hidden,!understood);assert.equal(d.getElementById('ackName').parentElement.hidden,!sig);assert.equal(d.getElementById('close').hidden,sig||understood);
  if(sig||understood){assert.equal(d.getElementById('ack').hidden,false);d.getElementById('ackName').value=sig?'직원':'';d.getElementById('understood').checked=understood;await d.getElementById('ack').onclick();assert.equal(calls[0].name,'acknowledge_announcement');assert.equal(calls[0].args.p_employee_name,sig?'직원':'');assert.equal(calls[0].args.p_understood,understood);}else{assert.equal(d.getElementById('ack').hidden,true);assert.equal(calls[0].name,'mark_property_message_read');}
 }
 // Older notices keep both confirmation controls.
 await w.openDetail({message_id:'legacy',message_type:'announcement',sender_type:'owner',message:'기존 공지',created_at:new Date().toISOString()});assert(!d.querySelector('.understood').hidden);assert(!d.getElementById('ackName').parentElement.hidden);dom.window.close();
 const todo=create('mission.html'),mw=todo.w,md=todo.d;let completeCalls=0;mw.confirm=()=>true;mw.omgSupabase={rpc:async(name,args)=>{if(name==='complete_mission'){completeCalls++;assert.equal(args.p_mission_id,'task');assert.equal(args.p_access_token,'owner');return {data:{ok:true}}}return {data:{ok:true}}}};inline(mw);await tick();mw.ntTest.setup();
 const task={id:'task',title:'줄넘기',timing:'today',priority:'normal',target_count:6,completed_count:2};mw.openDetails(task);assert.deepEqual([...md.querySelectorAll('#detailActions button')].map(x=>x.textContent),['수정','종료','완료']);await md.querySelector('.owner-complete').onclick();assert.equal(completeCalls,1);
 const done={...task,owner_completed_at:new Date().toISOString(),completions:[{employee_name:'관리자',completer_type:'owner',completed_at:new Date().toISOString()}]};assert.equal(mw.sectionKey(done),'completed');assert.equal(mw.completerNames(done),'관리자');mw.openDetails(done);assert.equal(md.querySelector('.owner-complete').disabled,true);assert(md.querySelector('#completionDetails').textContent.includes('관리자'));
 mw.ntTest.staff();mw.openDetails(done);assert.equal(md.querySelector('#detailActions'),null);assert.equal(mw.isComplete(done),true);todo.dom.window.close();
 console.log('PASS: 4 independent notice choices, send payloads, staff controls, acknowledgements/plain reads, legacy notice compatibility, 3 owner task actions, completion RPC, administrator attribution, disabled repeat, and staff completed state.');
})().catch(e=>{console.error(e);process.exit(1)});
