(function(){
  const $=id=>document.getElementById(id);
  function values(){return{notice_enabled:$('holidayNoticeEnabled').checked,notice_text:$('holidayNoticeContent').value.trim(),acknowledgement_required:$('holidayAckSwitch').getAttribute('aria-checked')==='true',acknowledgement_label:$('holidayAckText').value.trim()};}
  function validate(){const v=values();if(v.notice_enabled&&!v.notice_text)throw new Error('휴일 신청 공지 내용을 입력해주세요.');if(!v.acknowledgement_label)throw new Error('이해 확인 문구를 입력해주세요.');return v;}
  async function rpc(token,action,data={}){const r=await window.omgSupabase.rpc('holiday_request_action',{p_access_token:token,p_action:action,p_data:data});if(r.error||!r.data?.ok)throw new Error(r.data?.message||r.error?.message||'휴일 신청 설정을 처리하지 못했습니다.');return r.data;}
  function switchState(on){$('holidayAckSwitch').setAttribute('aria-checked',String(on));$('holidayAckSwitch').textContent=on?'On':'Off';}
  window.HolidaySettings={validate,async load(token){
    const {settings:s}=await rpc(token,'settings_get');
    document.querySelector('.attendance-settings-body').insertAdjacentHTML('beforeend',`<section class="holiday-settings"><h3>휴일 신청 설정</h3><label class="holiday-setting-check" for="holidayNoticeEnabled"><span>휴일 신청 시 공지 팝업</span><input id="holidayNoticeEnabled" type="checkbox"></label><textarea id="holidayNoticeContent" rows="4" maxlength="4000" aria-label="공지 내용" placeholder="공지 내용을 입력해주세요"></textarea><div class="holiday-switch-row"><span id="holidayAckSwitchLabel">이해 확인 체크 박스 사용</span><button id="holidayAckSwitch" class="holiday-switch" type="button" role="switch" aria-checked="true" aria-labelledby="holidayAckSwitchLabel">On</button></div><input id="holidayAckText" type="text" maxlength="100" value="이해했음" aria-label="이해 확인 체크 박스 문구"></section>`);
    $('holidayNoticeEnabled').checked=s.notice_enabled;$('holidayNoticeContent').value=s.notice_text;$('holidayNoticeContent').hidden=!s.notice_enabled;
    switchState(s.acknowledgement_required);$('holidayAckText').value=s.acknowledgement_label;
    $('holidayNoticeEnabled').onchange=()=>{$('holidayNoticeContent').hidden=!$('holidayNoticeEnabled').checked;};
    $('holidayAckSwitch').onclick=()=>switchState($('holidayAckSwitch').getAttribute('aria-checked')!=='true');
  },async save(token){return rpc(token,'settings_save',validate());}};
})();
