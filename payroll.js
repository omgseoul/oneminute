(function(){
  'use strict';
  const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'})[c]);
  const money=value=>value==null?'미설정':`${Number(value).toLocaleString('ko-KR')}원`;
  const duration=value=>`${Math.floor(Number(value)/60)}시간 ${Number(value)%60}분`;
  function init({accessToken,getPropertyIds}){
    const host=document.getElementById('payrollView'),button=document.getElementById('openPayroll'),content=document.getElementById('attendanceContent'),title=document.getElementById('pageTitle');
    let active=false,version=0,items=[];
    host.innerHTML=`<div class="payroll-top"><button class="payroll-back" type="button">‹ 근태관리</button><div class="payroll-month"><button type="button" data-step="-1" aria-label="이전 급여월">‹</button><input type="month" aria-label="급여 시작월"><button type="button" data-step="1" aria-label="다음 급여월">›</button></div></div><p class="payroll-message" role="alert"></p><section class="panel"><h2>근무자별 급여정보</h2><p class="payroll-help">근무자를 펼쳐 급여와 지급일을 설정하세요.</p><div class="payroll-list"></div></section><section class="panel"><h2>급여현황</h2><div class="payroll-results"></div><p class="payroll-help">선택한 월에 시작하는 급여주기 기준입니다. 현재 저장된 급여 설정으로 계산한 세전 기본급 예상액이며, 수당·공제·월급 일할계산은 포함하지 않습니다. 지급 완료 여부를 뜻하지 않습니다.</p></section>`;
    const month=host.querySelector('input[type=month]'),list=host.querySelector('.payroll-list'),results=host.querySelector('.payroll-results'),message=host.querySelector('.payroll-message');
    month.value=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Seoul',year:'numeric',month:'2-digit'}).format(new Date());
    async function rpc(name,args){const {data,error}=await window.omgSupabase.rpc(name,{p_access_token:accessToken,...args});if(error||!data?.ok)throw new Error(data?.message||'급여정보를 불러오지 못했습니다. 다시 시도해주세요.');return data;}
    function renderResults(){
      const configured=items.filter(x=>x.expected_pay!=null),total=configured.reduce((sum,x)=>sum+Number(x.expected_pay),0);
      results.innerHTML=items.length?`<div class="payroll-overview"><span>예상 기본급 합계 · ${configured.length}명${configured.length<items.length?' / 미설정 제외':''}</span><strong>${money(total)}</strong></div>`+items.map(x=>`<article class="payroll-result"><div class="payroll-result-head"><div class="payroll-name"><strong>${esc(x.display_name)}</strong><small>${esc(x.property_name)}${x.active?'':' · 비활성'}</small></div><strong>${money(x.expected_pay)}</strong></div><dl><dt>급여 산정기간</dt><dd>${esc(x.period_start)} ~ ${esc(x.period_end)}</dd><dt>완료 근무시간</dt><dd>${duration(x.work_minutes)} · ${x.work_days}일</dd><dt>급여 기준</dt><dd>${x.pay_type==='monthly'?'월급 '+money(x.monthly_salary):'시급 '+money(x.hourly_rate)}</dd><dt>급여일</dt><dd>${esc(x.pay_date||'미설정')}</dd></dl>${x.missing_count?`<p class="payroll-warning">미기록 ${x.missing_count}건 · 해당 시간은 계산에서 제외</p>`:''}${x.working_count?`<p class="payroll-help">근무 중 ${x.working_count}건 · 퇴근 기록 후 반영</p>`:''}</article>`).join(''):'<div class="empty">선택한 지점의 근무자가 없습니다.</div>';
    }
    function renderForms(){
      list.innerHTML=items.length?items.map(x=>`<details class="payroll-person" data-id="${esc(x.employee_id)}"><summary><span class="payroll-avatar">${esc(Array.from(x.display_name||'?')[0])}</span><span class="payroll-name"><strong>${esc(x.display_name)}</strong><small>${esc(x.property_name)}${x.active?'':' · 비활성'}</small></span><span class="payroll-badge">${x.pay_type==='monthly'?'월급제':'시급제'}</span></summary><form class="payroll-form"><div class="payroll-fields"><label class="wide">급여 계산방식<select name="pay_type"><option value="hourly" ${x.pay_type==='hourly'?'selected':''}>시급제 · 완료 근무시간 × 시급</option><option value="monthly" ${x.pay_type==='monthly'?'selected':''}>월급제 · 고정 월급</option></select></label><label>시급 (원)<input name="hourly_rate" type="number" inputmode="numeric" min="0" max="1000000000" step="1" placeholder="미설정" value="${x.hourly_rate??''}"></label><label>월급 (원)<input name="monthly_salary" type="number" inputmode="numeric" min="0" max="1000000000" step="1" placeholder="미설정" value="${x.monthly_salary??''}"></label><label class="wide">급여주기<div class="payroll-cycle"><select name="cycle_start_day" aria-label="급여주기 시작일">${Array.from({length:28},(_,i)=>`<option value="${i+1}" ${x.cycle_start_day===i+1?'selected':''}>매월 ${i+1}일</option>`).join('')}</select><span class="cycle-end"></span></div></label><label>급여일 기준<select name="pay_month_offset"><option value="0" ${x.pay_month_offset===0?'selected':''}>주기 종료월</option><option value="1" ${x.pay_month_offset===1?'selected':''}>주기 종료 다음 달</option></select></label><label>급여일<select name="pay_day"><option value="">미설정</option>${Array.from({length:31},(_,i)=>`<option value="${i+1}" ${x.pay_day===i+1?'selected':''}>${i===30?'말일':`${i+1}일`}</option>`).join('')}</select></label></div><p class="payroll-help">급여주기는 매월 반복됩니다. 급여일이 없는 달에는 말일로 적용합니다.</p><div class="payroll-footer"><span class="payroll-status" role="status"></span><button type="submit" class="payroll-save">저장</button></div></form></details>`).join(''):'<div class="empty">등록된 근무자가 없습니다.</div>';
      list.querySelectorAll('form').forEach(form=>{
        const cycle=form.elements.cycle_start_day,cycleLabel=form.querySelector('.cycle-end');
        const updateCycle=()=>cycleLabel.textContent=Number(cycle.value)===1?'~ 당월 말일':`~ 다음 달 ${Number(cycle.value)-1}일`;
        cycle.onchange=updateCycle;updateCycle();
        form.onsubmit=async event=>{
          event.preventDefault();const save=form.querySelector('button[type=submit]'),status=form.querySelector('.payroll-status'),id=form.closest('details').dataset.id;
          const settings=Object.fromEntries(new FormData(form));for(const key of ['hourly_rate','monthly_salary','pay_day'])settings[key]=settings[key]===''?null:Number(settings[key]);
          settings.cycle_start_day=Number(settings.cycle_start_day);settings.pay_month_offset=Number(settings.pay_month_offset);
          save.disabled=true;status.classList.remove('error');status.textContent='저장 중…';
          try{await rpc('save_employee_payroll',{p_employee_id:id,p_settings:settings});status.textContent='저장되었습니다.';form.closest('details').querySelector('.payroll-badge').textContent=settings.pay_type==='monthly'?'월급제':'시급제';await refresh(false);}catch(error){status.textContent=error.message;status.classList.add('error');}finally{save.disabled=false;}
        };
      });
    }
    async function refresh(forms=true){
      if(!active)return;const current=++version;
      message.textContent='';if(forms){list.innerHTML='<div class="empty">급여정보를 불러오는 중입니다.</div>';results.replaceChildren();}
      try{if(!/^\d{4}-\d{2}$/.test(month.value))throw new Error('조회할 급여월을 선택해주세요.');const data=await rpc('list_employee_payroll',{p_month:month.value+'-01',p_property_ids:getPropertyIds()});if(current!==version||!active)return;items=data.employees||[];if(forms)renderForms();renderResults();}
      catch(error){if(current!==version||!active)return;items=[];if(forms)list.replaceChildren();results.replaceChildren();message.textContent=error.message;}
    }
    button.hidden=false;button.onclick=()=>{active=true;content.hidden=true;host.hidden=false;button.hidden=true;title.textContent='급여정보';document.title='급여정보';refresh();};
    host.querySelector('.payroll-back').onclick=()=>{active=false;version++;host.hidden=true;content.hidden=false;button.hidden=false;title.textContent='근태관리';document.title='근태관리';window.dispatchEvent(new Event('payrollclosed'));button.focus();};
    month.onchange=()=>refresh();host.querySelectorAll('[data-step]').forEach(b=>b.onclick=()=>{const [y,m]=month.value.split('-').map(Number);if(!y||!m)return;const d=new Date(Date.UTC(y,m-1+Number(b.dataset.step),1));month.value=d.toISOString().slice(0,7);refresh();});
    return{isActive:()=>active,refresh};
  }
  window.OMSPayroll={init};
})();
