/* Shared presentation for notices, attendance requests and approval sheets. */
window.OMSDialogs=(()=>{
 const $=id=>document.getElementById(id),escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 function dateLabel(date){return date?date.replace(/-/g,'.'):'-';}
 function shortDate(date,full=false){if(!date)return '-';const[y,m,d]=date.split('-');return `${full?y+'년 ':''}${Number(m)}월 ${Number(d)}일`;}
 function range(start,end,timezone='Asia/Seoul'){
  const a=OMSAttendanceTime.parts(start,timezone),b=OMSAttendanceTime.parts(end,timezone),full=!!(a&&b&&a.date.slice(0,4)!==b.date.slice(0,4));
  return `<div class="dc-range"><span><small>${a?escape(shortDate(a.date,full))+' · 출근':'출근'}</small><strong>${a?escape(a.time):'미기록'}</strong></span><i aria-hidden="true">→</i><span><small>${b?escape(shortDate(b.date,full))+' · 퇴근':'퇴근'}</small><strong>${b?escape(b.time):'미기록'}</strong></span></div>`;
 }
 function requestCards(item){
  const body=$('detailBody');let host=$('detailRequestCards');if(!host){host=document.createElement('div');host.id='detailRequestCards';host.className='dc-request-details';body.after(host);}
  host.hidden=true;host.replaceChildren();
  const holiday=['holiday_approval','holiday_notice'].includes(item.message_type),share=item.message_type==='property_share_approval';if(!holiday&&!share)return;
  const row=(label,value)=>`<div class="dc-summary-row"><span>${escape(label)}</span><strong>${escape(value||'-')}</strong></div>`;
  if(holiday){
   const text=String(item.message||'').replace(/\\n/g,'\n'),field=label=>text.match(new RegExp('^'+label+':[ \t]*(.*)$','m'))?.[1]?.trim(),reason=text.match(/(?:^|\n)휴일 신청 사유:[^\S\n]*([\s\S]*)$/)?.[1]?.trim();
   if(!field('날짜')||reason===undefined)return;
   host.innerHTML=`<div class="dc-summary-card">${row('신청일',field('날짜'))}${row('신청자',field('신청자'))}${row('대상',field('대상'))}</div><div class="dc-reason-card"><span class="dc-section-label">휴일 신청 사유</span><p>${escape(reason)}</p></div>`;
  }else{
   const labels={attendance_records:'근무기록',work_status:'근무상태',missions:'To do'};
   host.innerHTML=`<div class="dc-summary-card">${row('요청 지점',item.share_source_name)}${row('대상 지점',item.share_target_name)}</div><div class="dc-reason-card"><span class="dc-section-label">공유 요청 항목</span><p>${escape((item.share_permissions||[]).map(x=>labels[x]||x).join(' · ')||'-')}</p></div>`;
  }
  host.hidden=false;body.hidden=true;
 }
 function present(item){
  const systemAlert=!!item.is_platform_system_notice,attendance=item.message_type==='attendance_approval',notice=['announcement','attendance_warning'].includes(item.message_type),contract=!!window.StaffChat?.contractId(item.message),overlay=$('detail');
  overlay.classList.toggle('dc-dialog',!contract);overlay.classList.toggle('dc-attendance',attendance);overlay.classList.toggle('dc-notice',(notice||systemAlert)&&!contract);
  $('detailBody').hidden=attendance;requestCards(item);
  $('detailTitle').classList.toggle('sr-only',contract);
  if(contract){$('detailKicker').textContent='';$('detailState').hidden=true;return;}
  $('detailKicker').textContent=systemAlert?'* 시스템 알림 *':attendance?'근태 수정':notice?(item.message_type==='attendance_warning'?'근태 안내':'직원 공지'):['holiday_approval','holiday_notice'].includes(item.message_type)?'휴일 신청':item.message_type==='property_share_approval'?'지점 공유':'결재 · 안내';
  const status=attendance||['holiday_approval','property_share_approval'].includes(item.message_type)?({approved:'결재완료',rejected:'반려',pending:'미결재'})[item.approval_status]||'미결재':notice?(item.is_sender?'발송한 공지':item.acknowledged_at?'확인완료':item.require_signature===false&&item.require_understanding===false?(item.read_at?'읽음':'새 공지'):'확인 필요'):'';
  $('detailState').textContent=status;$('detailState').hidden=!status;$('detailState').classList.toggle('complete',['결재완료','확인완료'].includes(status));
  if(attendance){
   $('detailTitle').textContent='출퇴근 시간 수정 요청';
   $('workDate').textContent=dateLabel(item.work_date);
   $('originalTime').innerHTML=range(item.original_clock_in_at,item.original_clock_out_at,item.attendance_timezone);
   $('requestedTime').innerHTML=range(item.requested_clock_in_at,item.requested_clock_out_at,item.attendance_timezone);
   const a=OMSAttendanceTime.parts(item.requested_clock_in_at,item.attendance_timezone),b=OMSAttendanceTime.parts(item.requested_clock_out_at,item.attendance_timezone);
   $('attendanceNote').textContent=a&&b&&a.date!==b.date?'다음 날 퇴근한 기록입니다.':'';$('attendanceNote').hidden=!$('attendanceNote').textContent;
  }
 }
 function preview(item,timezone){
  const start=$('editStart').value,end=$('editEnd').value;
  $('editPreview').hidden=!start||!end;if(!start||!end)return;
  const endDate=end<=start?OMSAttendanceTime.nextDate(item.work_date):item.work_date;
  $('editPreviewTime').innerHTML=`<div class="dc-range"><span><small>${escape(shortDate(item.work_date,item.work_date.slice(0,4)!==endDate.slice(0,4)))} · 출근</small><strong>${escape(start)}</strong></span><i aria-hidden="true">→</i><span><small>${escape(shortDate(endDate,item.work_date.slice(0,4)!==endDate.slice(0,4)))} · 퇴근</small><strong>${escape(end)}</strong></span></div>`;
  $('editDateNote').textContent=endDate!==item.work_date?`퇴근시간은 다음 날인 ${dateLabel(endDate)}입니다.`:'';$('editDateNote').hidden=endDate===item.work_date;
 }
 function edit(item,owner,timezone){
  $('editTitle').textContent=owner?'출퇴근 시간 수정':'출퇴근 시간 수정 신청';$('editKicker').textContent=owner?'근태 수정':'근태 신청';$('submitEdit').textContent=owner?'수정완료':'수정 요청 보내기';
  $('editMeta').textContent=`${dateLabel(item.work_date)} · ${item.employee_name}`;
  $('editOriginal').innerHTML=range(item.clock_in_at,item.clock_out_at,timezone);preview(item,timezone);
 }
 return {present,edit,preview,range};
})();
