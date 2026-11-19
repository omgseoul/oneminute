window.BotBriefing=(()=>{
 const statusLabels={pending:'대기 중',running:'분석 중',completed:'완료',empty:'대상 없음',failed:'실패',cancelled:'취소'};
 function period(run){const fmt=new Intl.DateTimeFormat('ko-KR',{timeZone:run.timezone||'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false});return fmt.format(new Date(run.period_start))+' ~ '+fmt.format(new Date(run.period_end));}
 async function mount(host,token,property){
  const box=document.createElement('section');box.className='bot-briefing';host.querySelector('.bot-settings-actions').before(box);let loaded=false,logsDialog=null;
  box.innerHTML=`<div class="briefing-heading"><label><input type="checkbox" class="briefing-enabled" disabled>브리핑</label><button type="button" class="briefing-expand" aria-expanded="false" aria-label="브리핑 설정 펼치기"><span class="briefing-summary">불러오는 중…</span><b aria-hidden="true">⌄</b></button></div><div class="briefing-fields" hidden><div class="briefing-help-row"><button type="button" class="employee-help briefing-help-button" aria-label="브리핑 도움말" aria-expanded="false">?</button><p class="briefing-help" hidden>정해진 시간에 메세지를 모두 종합하여 요약해주는 기능입니다.</p></div><div class="briefing-times"><label>시작시간<div class="briefing-time-controls"><select class="briefing-start-kind" aria-label="시작시간 기준"><option value="time">시간</option><option value="checkout">예약관리 퇴근시</option></select><span class="briefing-clock"><input class="briefing-start-time" type="time" aria-label="브리핑 시작시간"><span class="briefing-time-value" aria-hidden="true"></span></span></div></label><label>종료시간<div class="briefing-time-controls"><select class="briefing-end-kind" aria-label="종료시간 기준"><option value="time">시간</option><option value="checkin">예약관리 출근시</option></select><span class="briefing-clock"><input class="briefing-end-time" type="time" aria-label="브리핑 종료시간"><span class="briefing-time-value" aria-hidden="true"></span></span></div></label></div><p class="briefing-note">출퇴근 기준은 예약관리 담당자의 마지막 퇴근보고부터 첫 출근보고까지입니다.</p><div class="briefing-targets"></div><div class="briefing-notify"><label>알림 시점<select class="briefing-notify-kind"><option value="time">시간 지정</option><option value="checkin">출근보고 시</option></select></label><label class="briefing-notify-clock">알림 시간<input class="briefing-notify-time" type="time"></label></div><p class="briefing-note">분석이 끝난 브리핑을 선택한 근무자의 봇 알림으로 보냅니다.</p><label>브리핑 프롬프트<textarea class="briefing-prompt" rows="7" maxlength="12000"></textarea></label><p class="briefing-note">기간 내 새 메시지를 받은 온라인·현장 게스트 대화를 분석합니다. 사진·동영상의 내용은 직접 판독하지 않습니다.</p><button type="button" class="briefing-run">테스트 실행</button><p class="briefing-run-status" role="status"></p><pre class="briefing-result" hidden></pre><small class="briefing-status" role="status"></small><button type="button" class="briefing-logs">실행 로그</button></div>`;
  const q=s=>box.querySelector(s),enabled=q('.briefing-enabled'),status=q('.briefing-status');
  async function call(action,data={}){const res=await fetch(OMG_SUPABASE.url+'/functions/v1/bot-briefing',{method:'POST',headers:{apikey:OMG_SUPABASE.publishableKey,'Content-Type':'application/json'},body:JSON.stringify({access_token:token,property_id:property,action,data})});const v=await res.json();if(!res.ok||!v.ok)throw Error(v.message||'브리핑 요청에 실패했습니다.');return v;}
  const expand=q('.briefing-expand');
  let expanded=false,picker=null,roleInputs=[];
  const selectedTargets=()=>[...roleInputs.filter(input=>input.checked).map(input=>input.value),...(picker?.value()||[])];
  function summary(){
   const count=selectedTargets().length;
   const delivery=q('.briefing-notify-kind').value==='checkin'?'출근보고 시':(q('.briefing-notify-time').value||'알림 시간 미정');
   q('.briefing-summary').textContent=!loaded?'불러오는 중…':enabled.checked?`${delivery} · ${count?count+'개 대상 선택':'대상 미선택'}`:'사용 안 함';
  }
  function paintExpanded(){
   q('.briefing-fields').hidden=!expanded;
   logsButton.hidden=!expanded;
   expand.setAttribute('aria-expanded',String(expanded));
   expand.setAttribute('aria-label',expanded?'브리핑 설정 접기':'브리핑 설정 펼치기');
   expand.querySelector('b').textContent=expanded?'⌃':'⌄';
   if(!expanded)picker?.close();
  }
  expand.onclick=()=>{expanded=!expanded;paintExpanded();};
  function loadTargets(employees,properties,selected){
   const items=employees.map(employee=>({...employee,employee_id:employee.id}));
   const individual=selected.includes('all')?items.filter(item=>String(item.property_id||property)===String(property)).map(item=>item.id):selected;
   const host=q('.briefing-targets');
   picker=window.OMSTargetPicker.mount({host,items,properties,ownPropertyId:property,selected:individual,onChange:summary,title:'브리핑 대상 선택'});
   const roles=document.createElement('div');roles.className='briefing-role-options';
   for(const [value,name] of [['reservation','예약관리자'],['onsite','현장관리자'],['cleaning','청소']]){
    const label=document.createElement('label'),input=document.createElement('input');
    input.type='checkbox';input.value=value;input.checked=selected.includes(value);input.onchange=summary;
    roleInputs.push(input);label.append(input,document.createTextNode(name));roles.append(label);
   }
   host.querySelector('.target-legend').after(roles);
  }
  function paintNotify(){
   const fixed=q('.briefing-notify-kind').value==='time';
   q('.briefing-notify-clock').hidden=!fixed;
   q('.briefing-notify-time').disabled=!fixed;
  }
  q('.briefing-notify-kind').onchange=()=>{paintNotify();summary();};
  q('.briefing-notify-time').oninput=summary;
  function paint(){for(const end of ['start','end']){const input=q('.briefing-'+end+'-time'),manual=q('.briefing-'+end+'-kind').value==='time';input.parentElement.hidden=!manual;input.disabled=!manual;input.parentElement.parentElement.classList.toggle('attendance-time',!manual);input.nextElementSibling.textContent=input.value||'--:--';} }
  for(const end of ['start','end']){const input=q('.briefing-'+end+'-time');input.oninput=()=>{input.nextElementSibling.textContent=input.value||'--:--';};input.onclick=()=>{try{input.showPicker?.();}catch{}};}
  enabled.onchange=summary;for(const end of ['start','end'])q('.briefing-'+end+'-kind').onchange=paint;
  q('.briefing-help-button').onclick=e=>{const help=q('.briefing-help');help.hidden=!help.hidden;e.currentTarget.setAttribute('aria-expanded',String(!help.hidden));};
  function read(){if(!loaded)throw Error('브리핑 설정을 먼저 불러와주세요.');const data={enabled:enabled.checked,start_kind:q('.briefing-start-kind').value,end_kind:q('.briefing-end-kind').value,start_time:q('.briefing-start-time').value||null,end_time:q('.briefing-end-time').value||null,prompt:q('.briefing-prompt').value.trim()};if(data.enabled){if(data.start_kind==='time'&&!data.start_time||data.end_kind==='time'&&!data.end_time)throw Error('시작·종료 시간을 선택해주세요.');if(!data.prompt)throw Error('프롬프트를 입력해주세요.');}return data;}
  async function save(){
   if(!loaded)throw Error('브리핑 설정을 먼저 불러와주세요.');
   const data=read();
   if(data.enabled){
    const targets=selectedTargets();
    if(!targets.length)throw Error('브리핑을 받을 근무자를 선택해주세요.');
    data.notify_targets=targets;
    data.notify_kind=q('.briefing-notify-kind').value;
    data.notify_time=data.notify_kind==='time'?q('.briefing-notify-time').value:null;
    if(data.notify_kind==='time'&&!data.notify_time)throw Error('알림 시간을 선택해주세요.');
   }
   await call('save',data);
   status.textContent='브리핑 설정을 저장했습니다.';
  }
  function showRun(run){const result=q('.briefing-result');q('.briefing-run-status').textContent=`${statusLabels[run.status]||run.status} · ${run.conversation_count||0}개 대화 · ${Number(run.credits||0).toFixed(3)} 크레딧${run.estimated?' (추정 정산)':''}`;result.hidden=!run.summary&&!run.error;result.textContent=run.summary||run.error||'';}
  async function logs(){
   if(logsDialog?.isConnected)logsDialog.remove();logsDialog=document.createElement('dialog');logsDialog.className='briefing-log-dialog';logsDialog.innerHTML='<header><strong>브리핑 실행 로그</strong><button type="button" class="briefing-log-close" aria-label="실행 로그 닫기">×</button></header><p class="briefing-note">사용 크레딧은 지점 AI 잔액에서 차감됩니다. 1크레딧 = US$0.001</p><button type="button" class="briefing-log-refresh">새로고침</button><div class="briefing-log-list" role="status"></div>';
   const dialog=logsDialog;document.body.append(dialog);dialog.querySelector('.briefing-log-close').onclick=()=>dialog.close();dialog.onclose=()=>dialog.remove();dialog.addEventListener('click',e=>{if(e.target===dialog)dialog.close();});dialog.showModal();
   async function refresh(){const list=dialog.querySelector('.briefing-log-list');list.textContent='불러오는 중…';try{const v=await call('logs');list.replaceChildren();if(!v.logs.length)list.textContent='실행 기록이 없습니다.';for(const run of v.logs){const entry=document.createElement('details'),summary=document.createElement('summary'),meta=document.createElement('p'),body=document.createElement('pre');summary.textContent=`${statusLabels[run.status]} · ${run.mode==='manual'?'시험 실행':'자동 실행'} · ${Number(run.credits).toFixed(3)} 크레딧${run.estimated?' (추정)':''}`;meta.textContent=`${period(run)} (${run.timezone})\n대화 ${run.conversation_count}개 · 수신 ${run.message_count}건\n${run.model} · 입력 ${run.input_tokens} / 출력 ${run.output_tokens} 토큰`;body.textContent=run.summary||run.error||'처리 중입니다. 잠시 후 새로고침해주세요.';entry.append(summary,meta,body);list.append(entry);}}catch(e){list.textContent=e.message;}}
   dialog.querySelector('.briefing-log-refresh').onclick=refresh;await refresh();
  }
  const logsButton=q('.briefing-logs');logsButton.onclick=()=>logs();host.querySelector('.bot-settings-actions').prepend(logsButton);paintExpanded();
  q('.briefing-run').onclick=async()=>{const button=q('.briefing-run');button.disabled=true;q('.briefing-run-status').textContent='기간 확인 중…';try{
   const targets=selectedTargets();
   if(!targets.length)throw Error('브리핑을 받을 근무자를 선택해주세요.');
   const data={...read(),notify_targets:targets},preview=await call('preview',data);
   if(!box.isConnected)return;
   if(!confirm(`다음 기간의 메시지를 분석할까요?\n\n${period(preview.run)}\n기준: ${preview.run.timezone}\n\n가장 최근에 종료된 기간입니다. 현재 입력한 프롬프트로 실행하며 AI 크레딧이 사용됩니다. 선택한 브리핑 대상에게 예약 시간과 관계없이 [테스트] 봇 알림이 발송됩니다.`)){q('.briefing-run-status').textContent='실행을 취소했습니다.';return;}
   const result=await call('run',{id:preview.run.id});q('.briefing-run-status').textContent='분석 중입니다. 완료되면 테스트 봇 알림이 발송됩니다.';
   for(let n=0;n<30;n++){if(!box.isConnected)return;const v=await call('logs');const run=v.logs.find(x=>x.id===result.id);if(run){showRun(run);if(!['pending','running'].includes(run.status))break;}await new Promise(resolve=>setTimeout(resolve,3000));}
  }catch(e){q('.briefing-run-status').textContent=e.message;}finally{button.disabled=false;}};
  try{const v=await call('get'),s=v.settings;if(!box.isConnected)return {save};enabled.checked=s.enabled;for(const k of ['start','end']){q('.briefing-'+k+'-kind').value=s[k+'_kind'];q('.briefing-'+k+'-time').value=s[k+'_time']?.slice(0,5)||'';}q('.briefing-prompt').value=s.prompt;loadTargets(v.employees||[],v.properties||[],s.notify_targets||['reservation']);q('.briefing-notify-kind').value=s.notify_kind||'time';q('.briefing-notify-time').value=s.notify_time?.slice(0,5)||'09:00';paintNotify();loaded=true;enabled.disabled=false;paint();summary();status.textContent=v.provider_ready?`AI 잔액 ${Number(v.usage.balance).toFixed(3)} 크레딧`:'AI 연결을 확인해주세요.';}catch(e){status.textContent=e.message;q('.briefing-summary').textContent='설정 불러오기 실패';}
  return {save,destroy:()=>picker?.destroy()};
 }
 return {mount};
})();
