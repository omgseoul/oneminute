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
 assert.match(w.document.getElementById('requestedTime').textContent,/10월 11일 · 퇴근17:44/);assert.match(w.document.getElementById('originalTime').textContent,/미기록/);
 assert.equal(w.document.getElementById('detailState').textContent,'미결재');assert(!w.document.getElementById('reject').hidden);
 await w.openDetail({...item,approval_status:'approved'});assert(w.document.getElementById('ack').disabled);assert.equal(w.document.getElementById('detailState').textContent,'결재완료');
 const holiday={message_type:'holiday_approval',message:'결재완료 - 휴일신청\n날짜: 2026-10-04\n신청자: 변지훈\n대상: 변지훈\n휴일 신청 사유: 개인 사정\n<script>안전 확인</script>',sender_label:'변지훈',approval_status:'approved',read_at:'read'};
 await w.openDetail(holiday);
 const cards=w.document.getElementById('detailRequestCards');assert(!cards.hidden);assert(w.document.getElementById('detailBody').hidden);
 assert.match(cards.textContent,/신청일2026-10-04/);assert.match(cards.textContent,/신청자변지훈/);assert.match(cards.textContent,/개인 사정\n<script>안전 확인<\/script>/);assert.equal(cards.querySelector('script'),null);
 assert.equal(w.document.getElementById('detailKicker').textContent,'휴일 신청');assert.equal(w.document.getElementById('detailState').textContent,'결재완료');
 await w.openDetail({...holiday,approval_status:'rejected'});assert.equal(w.document.getElementById('detailState').textContent,'반려');assert(!cards.hidden);
 await w.openDetail({...holiday,approval_status:'pending',message:holiday.message.replaceAll('\n','\\n')});assert.equal(w.document.getElementById('detailState').textContent,'미결재');assert.match(cards.textContent,/개인 사정/);
 await w.openDetail({message_type:'property_share_approval',message:'공유 요청',sender_label:'사장님',share_source_name:'서울점',share_target_name:'홍대점',share_permissions:['work_status','attendance_records','missions'],approval_status:'pending',read_at:'read'});assert.match(cards.textContent,/서울점/);assert.match(cards.textContent,/근무상태 · 근무기록 · To do/);
 await w.openDetail({message_type:'announcement',message:'퇴근 전 확인해주세요.',sender_label:'사장님',read_at:'read'});
 assert(!w.document.getElementById('detailBody').hidden);assert(cards.hidden);assert.equal(cards.textContent,'');assert(w.document.getElementById('attendance').hidden);assert(!w.document.getElementById('announcementConfirm').hidden);assert(w.document.getElementById('close').hidden);assert.equal(w.document.getElementById('ack').textContent,'이해했음 확인');
 await w.openDetail({message_type:'announcement',message:'contract',sender_label:'사장님',read_at:'read'});assert(!w.document.getElementById('detail').classList.contains('dc-dialog'));assert(w.document.getElementById('detailTitle').classList.contains('sr-only'));assert.equal(w.document.getElementById('detailKicker').textContent,'');
 const a=page('attendance.html');helpers(a);a.document.getElementById('editStart').value='18:52';a.document.getElementById('editEnd').value='17:44';a.OMSDialogs.edit({work_date:'2026-10-10',employee_name:'니완',clock_in_at:'2026-10-10T09:52Z'},false,'Asia/Seoul');
 assert.equal(a.document.getElementById('submitEdit').textContent,'수정 요청 보내기');assert.match(a.document.getElementById('editPreviewTime').textContent,/10월 11일 · 퇴근/);assert(!a.document.getElementById('editDateNote').hidden);
 a.document.getElementById('editEnd').value='19:00';a.OMSDialogs.preview({work_date:'2026-10-10'},'Asia/Seoul');assert(a.document.getElementById('editDateNote').hidden);
 console.log('Attendance, holiday approval states, escaped multiline reasons, notice switching, contract isolation and live preview passed.');
})().catch(e=>{console.error(e);process.exitCode=1;});
