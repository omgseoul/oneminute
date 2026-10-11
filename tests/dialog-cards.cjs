const {JSDOM}=require('jsdom'),fs=require('fs'),assert=require('node:assert/strict');
function page(name){return new JSDOM(fs.readFileSync(name,'utf8').replace(/<script[\s\S]*?<\/script>/g,''),{url:'https://omgworks24.com/'+name,runScripts:'outside-only'}).window;}
function helpers(w){w.eval(fs.readFileSync('attendance-time.js','utf8'));w.eval(fs.readFileSync('dialog-cards.js','utf8'));}
(async()=>{
 const w=page('messages.html');helpers(w);
 w.StaffChat={contractId:m=>m==='contract'?'id':null,contractBody:m=>String(m).replaceAll('<','&lt;')};
 Object.assign(w,{activateLayerHistory(){},isHoliday:i=>i.message_type==='holiday_approval',requiresAcknowledgement:i=>['announcement','attendance_warning'].includes(i.message_type),isApproval:i=>i.message_type.endsWith('_approval'),isAttendanceWarning:i=>i.message_type==='attendance_warning',avatarMarkup:()=>'<span class="detail-avatar">니</span>',esc:v=>v,fmt:()=> '10월 11일 오전 10:44',categoryIcon:()=>'',StaffConversations:{openMessage:async()=>{}}});
 const html=fs.readFileSync('messages.html','utf8');w.eval(html.split('\n').find(l=>l.startsWith('async function openDetail(')));
 const item={message_type:'attendance_approval',sender_label:'니완',message:'old duplicate content',work_date:'2026-10-10',original_clock_in_at:'2026-10-10T09:52Z',requested_clock_in_at:'2026-10-10T09:52Z',requested_clock_out_at:'2026-10-11T08:44Z',attendance_timezone:'Asia/Seoul',approval_status:'pending',read_at:'read'};
 await w.openDetail(item);
 assert(w.document.getElementById('detailBody').hidden);assert(!w.document.getElementById('detailTitle').classList.contains('sr-only'));
 assert.match(w.document.getElementById('requestedTime').textContent,/2026.10.11 · 퇴근17:44/);assert.match(w.document.getElementById('originalTime').textContent,/미기록/);
 assert.equal(w.document.getElementById('detailState').textContent,'미결재');assert(!w.document.getElementById('reject').hidden);
 await w.openDetail({...item,approval_status:'approved'});assert(w.document.getElementById('ack').disabled);assert.equal(w.document.getElementById('detailState').textContent,'결재완료');
 await w.openDetail({message_type:'announcement',message:'퇴근 전 확인해주세요.',sender_label:'사장님',read_at:'read'});
 assert(!w.document.getElementById('detailBody').hidden);assert(w.document.getElementById('attendance').hidden);assert(!w.document.getElementById('announcementConfirm').hidden);assert(w.document.getElementById('close').hidden);assert.equal(w.document.getElementById('ack').textContent,'이해했음 확인');
 await w.openDetail({message_type:'announcement',message:'contract',sender_label:'사장님',read_at:'read'});assert(!w.document.getElementById('detail').classList.contains('dc-dialog'));assert(w.document.getElementById('detailTitle').classList.contains('sr-only'));assert.equal(w.document.getElementById('detailKicker').textContent,'');
 const a=page('attendance.html');helpers(a);a.document.getElementById('editStart').value='18:52';a.document.getElementById('editEnd').value='17:44';a.OMSDialogs.edit({work_date:'2026-10-10',employee_name:'니완',clock_in_at:'2026-10-10T09:52Z'},false,'Asia/Seoul');
 assert.equal(a.document.getElementById('submitEdit').textContent,'수정 요청 보내기');assert.match(a.document.getElementById('editPreviewTime').textContent,/2026.10.11 · 퇴근/);assert(!a.document.getElementById('editDateNote').hidden);
 a.document.getElementById('editEnd').value='19:00';a.OMSDialogs.preview({work_date:'2026-10-10'},'Asia/Seoul');assert(a.document.getElementById('editDateNote').hidden);
 console.log('Approval, completed approval, employee notice, contract isolation and live attendance preview passed.');
})().catch(e=>{console.error(e);process.exitCode=1;});
