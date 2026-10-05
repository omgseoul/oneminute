(function(){
  async function rpc(name,args){const{data,error}=await window.omgSupabase.rpc(name,args);if(error||!data?.ok)throw new Error(data?.message||error?.message||'알림 설정을 처리하지 못했습니다.');return data;}
  const rows=[['todo','To do 알림'],['calendar','일정 알림']];
  const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  function scheduleRow(schedule={offset_days:1,send_time:'09:00'}){return`<div class="reminder-schedule"><label class="reminder-offset"><span>해당일</span><input data-field="offset" type="number" min="0" max="365" step="1" inputmode="numeric" value="${Number(schedule.offset_days)||0}" aria-label="며칠 전"><span>일 전</span></label><label class="reminder-time">발송 시각<input data-field="time" type="time" value="${escape(String(schedule.send_time||'09:00').slice(0,5))}"></label><button class="reminder-remove" type="button" aria-label="알림 조건 삭제">×</button></div>`;}
  function legacySchedules(row){const time=String(row.send_time||'09:00').slice(0,5);if(row.send_when==='off')return[];if(row.send_when==='today')return[{offset_days:0,send_time:time}];if(row.send_when==='both')return[{offset_days:1,send_time:time},{offset_days:0,send_time:time}];return[{offset_days:1,send_time:time}];}
  function bindKind(node){
    const list=node.querySelector('.reminder-schedules');
    const bindRemove=()=>list.querySelectorAll('.reminder-remove').forEach(button=>button.onclick=()=>button.closest('.reminder-schedule').remove());
    node.querySelector('.reminder-add').onclick=()=>{if(list.children.length>=10){alert('알림 조건은 최대 10개까지 추가할 수 있습니다.');return;}list.insertAdjacentHTML('beforeend',scheduleRow());bindRemove();};
    bindRemove();
  }
  function mount({host,token,propertyId}){
    host.innerHTML=rows.map(([kind,label])=>`<div class="reminder-setting" data-kind="${kind}"><div class="reminder-setting-head"><h3>${label}</h3><button class="reminder-add" type="button" aria-label="${label} 조건 추가">＋</button></div><div class="reminder-schedules">${scheduleRow()}</div><div class="reminder-recipients"><span>알림 대상</span><label><input data-field="staff" type="checkbox" checked>대상근로자</label><label><input data-field="owner" type="checkbox" checked>관리자</label></div></div>`).join('')+'<button id="saveReminderSettings" type="button">알림 설정 저장</button><p id="reminderSettingsMessage" role="status"></p>';
    host.querySelectorAll('.reminder-setting').forEach(bindKind);
    const message=host.querySelector('#reminderSettingsMessage');
    const fill=async()=>{const data=await rpc('get_property_reminder_settings',{p_access_token:token,p_property_id:propertyId});for(const row of data.settings||[]){const node=host.querySelector(`[data-kind="${row.kind}"]`);if(!node)continue;const schedules=Array.isArray(row.schedules)?row.schedules:legacySchedules(row);node.querySelector('.reminder-schedules').innerHTML=schedules.map(scheduleRow).join('');node.querySelector('[data-field=staff]').checked=row.notify_staff;node.querySelector('[data-field=owner]').checked=row.notify_owner;bindKind(node);}};
    host.querySelector('#saveReminderSettings').onclick=async()=>{const button=host.querySelector('#saveReminderSettings');button.disabled=true;message.textContent='';try{const settings=rows.map(([kind])=>{const node=host.querySelector(`[data-kind="${kind}"]`),schedules=[...node.querySelectorAll('.reminder-schedule')].map(row=>({offset_days:Number(row.querySelector('[data-field=offset]').value),send_time:row.querySelector('[data-field=time]').value}));if(schedules.some(item=>!Number.isInteger(item.offset_days)||item.offset_days<0||item.offset_days>365||!item.send_time))throw new Error('발송 날짜와 시각을 확인해주세요.');return{kind,schedules,notify_staff:node.querySelector('[data-field=staff]').checked,notify_owner:node.querySelector('[data-field=owner]').checked};});await rpc('save_property_reminder_settings',{p_access_token:token,p_property_id:propertyId,p_settings:settings});message.textContent='알림 설정이 저장되었습니다.';}catch(error){message.textContent=error.message;}finally{button.disabled=false;}};
    fill().catch(error=>message.textContent=error.message);
  }
  window.omgReminderSettings={mount};
})();
