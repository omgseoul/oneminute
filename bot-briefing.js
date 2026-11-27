window.BotBriefing=(()=>{
 const statusLabels={pending:'대기 중',running:'분석 중',completed:'완료',empty:'대상 없음',failed:'실패',cancelled:'취소'};
 function period(run){const fmt=new Intl.DateTimeFormat('ko-KR',{timeZone:run.timezone||'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false});return fmt.format(new Date(run.period_start))+' ~ '+fmt.format(new Date(run.period_end));}
 async function mount(host,token,property){
  const box=document.createElement('section');box.className='bot-briefing';host.querySelector('.bot-settings-actions').before(box);let loaded=false,logsDialog=null;
  box.innerHTML=`<div class="briefing-heading"><label><input type="checkbox" class="briefing-enabled" disabled>브리핑</label><button type="button" class="employee-help briefing-help-button" aria-label="브리핑 도움말" aria-expanded="false">?</button><button type="button" class="briefing-expand" aria-expanded="false" aria-label="브리핑 설정 펼치기"><span class="briefing-summary">불러오는 중…</span><b aria-hidden="true">⌄</b></button></div><p class="briefing-help" hidden>예약관리·현장관리·청소·체크인 명단을 선택하고, 각 내용을 받을 관리자와 근무자를 지정합니다. 여러 역할을 맡은 근무자는 선택된 내용을 한 브리핑으로 받습니다.</p><div class="briefing-fields" hidden><div class="briefing-times"><label>시작시간<div class="briefing-time-controls"><select class="briefing-start-kind" aria-label="시작시간 기준"><option value="time">시간</option><option value="checkout">예약관리 퇴근시</option></select><span class="briefing-clock"><input class="briefing-start-time" type="time" aria-label="브리핑 시작시간"><span class="briefing-time-value" aria-hidden="true"></span></span></div></label><label>종료시간<div class="briefing-time-controls"><select class="briefing-end-kind" aria-label="종료시간 기준"><option value="time">시간</option><option value="checkin">예약관리 출근시</option></select><span class="briefing-clock"><input class="briefing-end-time" type="time" aria-label="브리핑 종료시간"><span class="briefing-time-value" aria-hidden="true"></span></span></div></label></div><p class="briefing-note">출퇴근 기준은 예약관리 담당자의 마지막 퇴근보고부터 첫 출근보고까지입니다.</p><div class="briefing-targets"></div><div class="briefing-notify"><label>알림 시점<select class="briefing-notify-kind"><option value="time">시간 지정</option><option value="checkin">출근보고 시</option></select></label><label class="briefing-notify-clock">알림 시간<input class="briefing-notify-time" type="time"></label></div><p class="briefing-note">분석이 끝난 브리핑을 관리자와 선택한 근무자의 봇 알림으로 보냅니다.</p><label>브리핑 프롬프트<textarea class="briefing-prompt" rows="7" maxlength="12000"></textarea></label><p class="briefing-note">예약관리·현장관리·청소는 새로 수신한 게스트 대화를 분석합니다. 체크인 명단은 알림을 보내는 날의 예약정보로 작성하며 AI 크레딧을 사용하지 않습니다. 사진·동영상은 직접 판독하지 않습니다.</p><button type="button" class="briefing-run">테스트 실행</button><p class="briefing-run-status" role="status"></p><pre class="briefing-result" hidden></pre><small class="briefing-status" role="status"></small><button type="button" class="briefing-logs">실행 로그</button></div>`;
  const q=s=>box.querySelector(s),enabled=q('.briefing-enabled'),status=q('.briefing-status');
  async function call(action,data={}){const res=await fetch(OMG_SUPABASE.url+'/functions/v1/bot-briefing',{method:'POST',headers:{apikey:OMG_SUPABASE.publishableKey,'Content-Type':'application/json'},body:JSON.stringify({access_token:token,property_id:property,action,data})});const v=await res.json();if(!res.ok||!v.ok)throw Error(v.message||'브리핑 요청에 실패했습니다.');return v;}
  const expand=q('.briefing-expand');
  let expanded=false,picker=null,categoryControls=[];
  const selectedTargets=()=>[...new Set(categoryControls.filter(c=>c.enabled.checked).flatMap(c=>c.targets()).filter(t=>!t.startsWith('owner:')&&t!=='manager'))];
  const deliveryTargets=()=>selectedTargets();
  const categories=()=>Object.fromEntries(categoryControls.map(c=>[c.key,{enabled:c.enabled.checked,targets:c.targets()}]));
  function summary(){
   const count=selectedTargets().length;
   const delivery=q('.briefing-notify-kind').value==='checkin'?'출근보고 시':(q('.briefing-notify-time').value||'알림 시간 미정');
   q('.briefing-summary').textContent=!loaded?'불러오는 중…':enabled.checked?`${delivery} · ${count?count+'개 선택 · 관리자':'관리자 수신'}`:'사용 안 함';
  }
  function paintExpanded(){
   q('.briefing-fields').hidden=!expanded;
   logsButton.hidden=!expanded;
   expand.setAttribute('aria-expanded',String(expanded));
   expand.setAttribute('aria-label',expanded?'브리핑 설정 접기':'브리핑 설정 펼치기');
   expand.querySelector('b').textContent=expanded?'⌃':'⌄';
   if(!expanded)categoryControls.forEach(c=>c.picker.close());
  }
  expand.onclick=()=>{expanded=!expanded;paintExpanded();};
  function loadTargets(employees,properties,selected,owners,saved){
   const host=q('.briefing-targets');host.replaceChildren();categoryControls=[];
   const heading=document.createElement('strong');heading.textContent='브리핑 내용 · 수신 대상';host.append(heading);
   for(const [key,title,role] of [['reservation','예약관리','reservation'],['onsite','현장관리','onsite'],['cleaning','청소','cleaning'],['checkin','체크인 명단','reservation']]){
    const cfg=saved?.[key]||{enabled:true,targets:['manager',role,...selected.filter(t=>/^[0-9a-f-]{36}$/.test(t)),...owners.filter(o=>!selected.includes('skip-owner:'+o.id)).map(o=>'owner:'+o.id)]};
    const card=document.createElement('details');card.className='briefing-category';
    const head=document.createElement('summary'),label=document.createElement('label'),enabled=document.createElement('input');enabled.type='checkbox';enabled.checked=cfg.enabled;enabled.onchange=summary;label.append(enabled,document.createTextNode(title));label.onclick=e=>e.stopPropagation();head.append(label,document.createTextNode(' 수신 대상 ⌄'));card.append(head);
    const content=document.createElement('div');card.append(content);host.append(card);
    const inputs=[],roles=document.createElement('div');roles.className='briefing-role-options';
    for(const [value,name] of [['manager','이 지점 관리자'],['reservation','예약관리 담당'],['onsite','현장관리 담당'],['cleaning','청소 담당'],...owners.map(o=>['owner:'+o.id,o.property_name+' · '+o.name+' (관리자)'])]){
     const label=document.createElement('label'),input=document.createElement('input');input.type='checkbox';input.value=value;input.checked=cfg.targets.includes(value);input.onchange=summary;inputs.push(input);label.append(input,document.createTextNode(name));roles.append(label);
    }
    content.append(roles);const target=document.createElement('div');content.append(target);
    const picker=window.OMSTargetPicker.mount({host:target,items:employees.map(e=>({...e,employee_id:e.id})),properties,ownPropertyId:property,selected:cfg.targets.includes('all')?employees.filter(e=>String(e.property_id||property)===String(property)).map(e=>e.id):cfg.targets.filter(t=>/^[0-9a-f-]{36}$/.test(t)),onChange:summary,title:title+' 받을 근무자'});
    categoryControls.push({key,enabled,picker,targets:()=>[...inputs.filter(x=>x.checked).map(x=>x.value),...picker.value()]});
   }
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
   const data={...read(),categories:categories()};
   if(data.enabled){
    data.notify_targets=deliveryTargets();
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
   const data={...read(),notify_targets:deliveryTargets(),categories:categories()},preview=await call('preview',data);
   if(!box.isConnected)return;
   if(!confirm(`다음 기간의 메시지를 분석할까요?\n\n${period(preview.run)}\n기준: ${preview.run.timezone}\n\n가장 최근에 종료된 기간입니다. 현재 입력한 프롬프트로 실행하며 AI 크레딧이 사용됩니다. 관리자와 선택한 근무자에게 예약 시간과 관계없이 [테스트] 봇 알림이 발송됩니다.`)){q('.briefing-run-status').textContent='실행을 취소했습니다.';return;}
   const result=await call('run',{id:preview.run.id});q('.briefing-run-status').textContent='분석 중입니다. 완료되면 테스트 봇 알림이 발송됩니다.';
   for(let n=0;n<30;n++){if(!box.isConnected)return;const v=await call('logs');const run=v.logs.find(x=>x.id===result.id);if(run){showRun(run);if(!['pending','running'].includes(run.status))break;}await new Promise(resolve=>setTimeout(resolve,3000));}
  }catch(e){q('.briefing-run-status').textContent=e.message;}finally{button.disabled=false;}};
  try{const v=await call('get'),s=v.settings;if(!box.isConnected)return {save};enabled.checked=s.enabled;for(const k of ['start','end']){q('.briefing-'+k+'-kind').value=s[k+'_kind'];q('.briefing-'+k+'-time').value=s[k+'_time']?.slice(0,5)||'';}q('.briefing-prompt').value=s.prompt;loadTargets(v.employees||[],v.properties||[],s.notify_targets||['reservation'],v.shared_owners||[],s.categories);q('.briefing-notify-kind').value=s.notify_kind||'time';q('.briefing-notify-time').value=s.notify_time?.slice(0,5)||'09:00';paintNotify();loaded=true;enabled.disabled=false;paint();summary();status.textContent=v.provider_ready?`AI 잔액 ${Number(v.usage.balance).toFixed(3)} 크레딧`:'AI 연결을 확인해주세요.';}catch(e){status.textContent=e.message;q('.briefing-summary').textContent='설정 불러오기 실패';}
  return {save,destroy:()=>categoryControls.forEach(c=>c.picker.destroy())};
 }
 return {mount};
})();
