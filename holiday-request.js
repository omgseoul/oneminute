(function(){
  const $=id=>document.getElementById(id),esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  let session,context,requestId,noticeSeen=false,acknowledged=false;
  async function rpc(action,data={}){
    const result=await window.omgSupabase.rpc('holiday_request_action',{p_access_token:session.accessToken,p_action:action,p_data:data});
    if(result.error||!result.data?.ok)throw new Error(result.data?.message||result.error?.message||'휴일 신청을 처리하지 못했습니다.');
    return result.data;
  }
  function openDialog(dialog){
    dialog.style.top='';dialog.style.bottom='';dialog.style.margin='';dialog.style.maxHeight='';
    dialog.showModal();const top=Math.max(16,Math.round(dialog.getBoundingClientRect().top));
    dialog.style.top=`${top}px`;dialog.style.bottom='auto';dialog.style.margin='0 auto';dialog.style.maxHeight=`calc(100dvh - ${top+16}px)`;dialog.scrollTop=0;
  }
  function updateTargets(){
    const chosen=[...$('holidayTargets').querySelectorAll('input:checked')];
    $('holidayTargetButton').textContent=chosen.length===1?(chosen[0].value===context.employee_id?'본인':context.employees.find(e=>e.id===chosen[0].value)?.name):chosen.length?`${chosen.length}명 선택`:'대상 선택';
  }
  function openForm(){
    $('holidayNoticeDialog').close();$('holidayForm').reset();$('holidayDate').value=context.today;
    $('holidayTargets').innerHTML=context.employees.map(e=>`<label><span>${esc(e.id===context.employee_id?'본인':e.name)}</span><input type="checkbox" value="${esc(e.id)}" ${e.id===context.employee_id?'checked':''}></label>`).join('');
    $('holidayTargetPanel').hidden=true;$('holidayTargetButton').setAttribute('aria-expanded','false');
    $('holidayError').textContent='';requestId=crypto.randomUUID();updateTargets();openDialog($('holidayFormDialog'));
  }
  async function begin(){
    const button=$('requestHoliday');button.disabled=true;$('message').textContent='';
    try{
      context=await rpc('context');noticeSeen=false;acknowledged=false;
      if(!context.settings.notice_enabled){openForm();return;}
      $('holidayNoticeText').textContent=context.settings.notice_text;
      $('holidayAckLabel').textContent=context.settings.acknowledgement_label||'이해했음';
      $('holidayAckRow').hidden=!context.settings.acknowledgement_required;
      $('holidayAck').checked=false;$('holidayContinue').disabled=context.settings.acknowledgement_required;
      openDialog($('holidayNoticeDialog'));
    }catch(error){$('message').textContent=error.message;}finally{button.disabled=false;}
  }
  window.HolidayRequest={init(s){
    session=s;if(s.sessionKind==='owner')return;
    document.body.insertAdjacentHTML('beforeend',`
      <dialog id="holidayNoticeDialog" class="holiday-dialog"><div class="holiday-head"><h2>휴일 신청 안내</h2><button type="button" data-holiday-close="holidayNoticeDialog" aria-label="닫기">×</button></div>
        <div id="holidayNoticeText" class="holiday-notice"></div>
        <label id="holidayAckRow" class="holiday-ack"><input id="holidayAck" type="checkbox"><span id="holidayAckLabel">이해했음</span></label>
        <div class="holiday-actions"><button type="button" id="holidayContinue" class="holiday-primary">다음</button></div>
      </dialog>
      <dialog id="holidayFormDialog" class="holiday-dialog"><form id="holidayForm">
        <div class="holiday-head"><h2>휴일 신청</h2><button type="button" data-holiday-close="holidayFormDialog" aria-label="닫기">×</button></div>
        <label class="holiday-field">날짜<input id="holidayDate" type="date" required></label>
        <div class="holiday-field"><label for="holidayTargetButton">대상</label><div class="holiday-selector">
          <button id="holidayTargetButton" class="holiday-select" type="button" aria-expanded="false" aria-controls="holidayTargetPanel">본인</button>
          <div id="holidayTargetPanel" class="holiday-select-panel" hidden><p>대상 · 여러 명 선택 가능</p><div id="holidayTargets"></div></div>
        </div></div>
        <label class="holiday-field">휴일 신청 사유<textarea id="holidayReason" rows="3" maxlength="1500" required placeholder="휴일 신청 사유를 적어주세요"></textarea></label>
        <p id="holidayError" class="holiday-error" role="alert"></p>
        <div class="holiday-actions"><button id="holidaySubmit" class="holiday-primary" type="submit">신청</button></div>
      </form></dialog>`);
    $('requestHoliday').hidden=false;$('requestHoliday').onclick=begin;
    document.querySelectorAll('[data-holiday-close]').forEach(b=>b.onclick=()=>$(b.dataset.holidayClose).close());
    $('holidayAck').onchange=()=>{$('holidayContinue').disabled=context.settings.acknowledgement_required&&!$('holidayAck').checked;};
    $('holidayContinue').onclick=()=>{if(context.settings.acknowledgement_required&&!$('holidayAck').checked)return;noticeSeen=true;acknowledged=$('holidayAck').checked;openForm();};
    $('holidayTargetButton').onclick=()=>{const panel=$('holidayTargetPanel');panel.hidden=!panel.hidden;$('holidayTargetButton').setAttribute('aria-expanded',String(!panel.hidden));};
    $('holidayTargets').onchange=updateTargets;
    document.addEventListener('click',e=>{if(!e.target.closest('.holiday-selector')){$('holidayTargetPanel').hidden=true;$('holidayTargetButton').setAttribute('aria-expanded','false');}});
    $('holidayForm').onsubmit=async e=>{
      e.preventDefault();const targets=[...$('holidayTargets').querySelectorAll('input:checked')].map(x=>x.value),reason=$('holidayReason').value.trim();
      if(!targets.length||!reason){$('holidayError').textContent='대상과 휴일 신청 사유를 입력해주세요.';return;}
      const button=$('holidaySubmit');button.disabled=true;$('holidayError').textContent='';
      try{
        const result=await rpc('submit',{id:requestId,holiday_date:$('holidayDate').value,target_employee_ids:targets,reason,notice_seen:noticeSeen,acknowledged,notice_version:context.settings.updated_at});
        $('holidayFormDialog').close();$('message').textContent='휴일 신청을 보냈습니다. 알림과 캘린더에서 결재 상태를 확인할 수 있습니다.';
        try{if(result.message_id)await window.omgNotifications.send(session.accessToken,result.message_id);}catch(_){$('message').textContent+=' 관리자 푸시 알림 전송은 실패했지만 결재함에는 등록되었습니다.';}
      }catch(error){$('holidayError').textContent=error.message;}finally{button.disabled=false;}
    };
  }};
})();
