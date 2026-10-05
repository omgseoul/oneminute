(function(){
  const scope='property_settings';
  async function rpc(name,args){const {data,error}=await window.omgSupabase.rpc(name,args);if(error||!data?.ok)throw new Error(data?.message||error?.message||'알림 설정을 처리하지 못했습니다.');return data;}
  const rows=[['todo','To do 알림'],['calendar','일정 알림']];
  function mount({host,token,propertyId}){
    host.innerHTML=rows.map(([kind,label])=>`<div class="reminder-setting" data-kind="${kind}"><h3>${label}</h3><div class="reminder-setting-grid"><label>발송 날짜<select data-field="when"><option value="before">전날</option><option value="today">당일</option><option value="both">전날과 당일</option><option value="off">사용 안 함</option></select></label><label>발송 시각<input data-field="time" type="time" value="09:00"></label></div><div class="reminder-recipients"><span>알림 대상</span><label><input data-field="staff" type="checkbox" checked>근로자</label><label><input data-field="owner" type="checkbox" checked>관리자</label></div></div>`).join('')+'<button id="saveReminderSettings" type="button">알림 설정 저장</button><p id="reminderSettingsMessage" role="status"></p>';
    const message=host.querySelector('#reminderSettingsMessage');
    const fill=async()=>{const data=await rpc('get_property_reminder_settings',{p_access_token:token,p_property_id:propertyId});for(const row of data.settings||[]){const node=host.querySelector(`[data-kind="${row.kind}"]`);if(!node)continue;node.querySelector('[data-field=when]').value=row.send_when;node.querySelector('[data-field=time]').value=row.send_time.slice(0,5);node.querySelector('[data-field=staff]').checked=row.notify_staff;node.querySelector('[data-field=owner]').checked=row.notify_owner;}};
    host.querySelector('#saveReminderSettings').onclick=async()=>{const button=host.querySelector('#saveReminderSettings');button.disabled=true;message.textContent='';try{const settings=rows.map(([kind])=>{const node=host.querySelector(`[data-kind="${kind}"]`);return{kind,send_when:node.querySelector('[data-field=when]').value,send_time:node.querySelector('[data-field=time]').value,notify_staff:node.querySelector('[data-field=staff]').checked,notify_owner:node.querySelector('[data-field=owner]').checked};});await rpc('save_property_reminder_settings',{p_access_token:token,p_property_id:propertyId,p_settings:settings});message.textContent='알림 설정이 저장되었습니다.';}catch(error){message.textContent=error.message;}finally{button.disabled=false;}};
    fill().catch(error=>message.textContent=error.message);
  }
  window.omgReminderSettings={mount};
})();
