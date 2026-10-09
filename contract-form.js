/* Structured contract editor. The generated text is the signed, immutable snapshot. */
window.OMSContractForm = (() => {
 const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const today = () => new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Seoul'}).format(new Date());
 function mount({body,employer,title,defaults={},existing,changed}) {
  const b=defaults.business_info||{};
  const f={kind:'standard',term:'open',start:today(),end:'',place:b.address||defaults.property||'',job:defaults.job||'',start_time:defaults.clock_in?.slice(0,5)||'',end_time:defaults.clock_out?.slice(0,5)||'',break_minutes:'',days:[],holiday:'',pay_type:defaults.pay_type||'hourly',amount:defaults.pay_type==='monthly'?defaults.monthly_salary??'':defaults.hourly_rate??'',pay_day:defaults.pay_day||'',pay_period:'매월 1일부터 말일까지',pay_method:'근로자 본인 명의 계좌로 지급',bonus:'없음',allowance:'없음',overtime:'적용 법령에 따라 별도 산정하여 지급',insurance:[],business_name:b.business_name||defaults.property||'',employer_name:b.employer_name||'',business_phone:b.phone||'',business_address:b.address||'',employee_name:defaults.name||'',employee_phone:defaults.contact||'',employee_address:'',extra:'',written_date:today(),...existing?.contract_fields};
  let mode=existing&&(!existing.contract_fields?.kind||existing.contract_fields.editor_mode==='manual')?'manual':'structured';
  const host=document.createElement('div');host.className='contract-fields';
  body.closest('label').before(host);
  const input=(key,label,type='text',full=false)=>`<label class="${full?'field-wide':''}">${label}<input data-field="${key}" type="${type}" value="${esc(f[key])}" ${type==='number'?'min="0" step="1" inputmode="numeric"':''} maxlength="500"></label>`;
  const choice=(key,label,options)=>`<fieldset class="field-wide contract-choice-${key}"><legend>${label}</legend><div class="contract-segments">${options.map(([value,name])=>`<label><input type="radio" name="contract-${key}" data-field="${key}" value="${value}" ${f[key]===value?'checked':''}><span>${name}</span></label>`).join('')}</div></fieldset>`;
  const checks=(key,label,options)=>`<fieldset class="field-wide"><legend>${label}</legend><div class="contract-checks">${options.map(name=>`<label><input type="checkbox" data-set="${key}" value="${name}" ${f[key].includes(name)?'checked':''}><span>${name}</span></label>`).join('')}</div></fieldset>`;
  host.innerHTML=`<div class="contract-form-grid">
   ${choice('kind','계약 유형',[['standard','표준 근로계약서'],['parttime','단시간 근로계약서'],['other','기타 계약서']])}<h2>근로조건</h2>
   ${choice('term','계약기간',[['open','기간의 정함 없음'],['fixed','기간 정함']])}${input('start','근로 시작일','date')}${input('end','계약 종료일','date')}
   ${input('place','근무장소','text',true)}${input('job','업무 내용','text',true)}${input('start_time','출근','time')}${input('end_time','퇴근','time')}${input('break_minutes','휴게시간 · 분','number')}${input('holiday','주휴일 (예: 일요일)')}
   ${checks('days','근무요일',['월','화','수','목','금','토','일'])}<label class="field-wide">요일별 근무시간 / 휴게시간 보충<input data-field="schedule_note" value="${esc(f.schedule_note)}" maxlength="1000" placeholder="요일마다 시간이 다르면 각각 입력"></label>
   <h2>임금</h2>${choice('pay_type','급여 종류',[['hourly','시급'],['monthly','월급'],['annual','연봉']])}${input('amount','계약 금액 · 원','number')}${input('pay_day','매월 지급일 · 말일은 31','number')}${input('pay_period','임금 산정기간','text',true)}${input('pay_method','지급방법','text',true)}${input('bonus','상여금')}${input('allowance','기타수당 / 구성 내역')}${input('overtime','연장·야간·휴일근로 수당','text',true)}
   ${checks('insurance','사회보험 적용 항목',['고용보험','산재보험','국민연금','건강보험'])}<label class="field-wide">보험 적용 / 제외 사유<input data-field="insurance_note" value="${esc(f.insurance_note)}" maxlength="500" placeholder="해당 사항이 있으면 입력"></label>
   <h2>사업장 정보</h2>${input('business_name','사업장명')}${input('employer_name','사업주명')}${input('business_phone','연락처','tel',true)}${input('business_address','사업장 주소','text',true)}
   <h2>근로자 정보</h2>${input('employee_name','근로자명')}${input('employee_phone','연락처','tel')}${input('employee_address','주소','text',true)}
   <h2>기타 약정</h2><label class="field-wide">추가 약정<textarea data-field="extra" maxlength="6000">${esc(f.extra)}</textarea></label>${input('written_date','작성일','date')}
  </div><p class="contract-note">사업장 정보는 Property 설정의 기본값입니다. 이 계약서에 맞게 수정할 수 있습니다.</p><button type="button" id="useStructured">입력 항목으로 계약 내용 생성</button>`;
  const bodyLabel=body.closest('label'),ownerLabel=employer.closest('label');ownerLabel.hidden=mode==='structured';
  const details=document.createElement('details');details.className='contract-text-editor';details.innerHTML='<summary>계약서 전문 확인·직접 수정</summary>';bodyLabel.before(details);details.append(bodyLabel);details.open=mode==='manual';
  const read=()=>{host.querySelectorAll('[data-field]').forEach(el=>{if(el.type!=='radio'||el.checked)f[el.dataset.field]=el.value;});['days','insurance'].forEach(k=>f[k]=[...host.querySelectorAll(`[data-set="${k}"]:checked`)].map(el=>el.value));return f;};
  function text(){read();const pay={hourly:'시급',monthly:'월급',annual:'연봉'}[f.pay_type],kind={standard:'표준',parttime:'단시간',other:'기타'}[f.kind]||'표준';return `${kind} 근로계약서

${f.business_name}의 사업주 ${f.employer_name}와 근로자 ${f.employee_name}는 다음과 같이 근로계약을 체결합니다.

1. 계약기간
${f.start}부터 ${f.term==='fixed'?f.end+'까지':'기간의 정함 없음'}

2. 근무장소 및 업무
근무장소: ${f.place}
업무 내용: ${f.job}

3. 근무시간 및 휴게
근무시간: ${f.start_time} ~ ${f.end_time}
휴게시간: ${f.break_minutes}분
근무요일: ${f.days.join(' · ')} (주 ${f.days.length}일)
요일별 시간 및 보충: ${f.schedule_note||'위 근무시간과 동일'}

4. 휴일 및 휴가
주휴일: ${f.holiday}
연차유급휴가는 적용되는 근로기준법에 따라 부여합니다.

5. 임금
${pay}: ${Number(f.amount||0).toLocaleString('ko-KR')}원${f.pay_type==='annual'?'\n월 기본 지급액: '+(Number(f.amount||0)/12).toLocaleString('ko-KR',{maximumFractionDigits:2})+'원 (연봉 ÷ 12, 상여·기타수당 구성은 아래 약정에 따름)':''}
임금 산정기간: ${f.pay_period}
임금 지급일: 매월 ${Number(f.pay_day)===31?'말일':f.pay_day+'일'}
지급방법: ${f.pay_method}
상여금: ${f.bonus}
기타수당 / 임금 구성: ${f.allowance}
연장·야간·휴일근로 수당: ${f.overtime}

6. 사회보험
적용 항목: ${f.insurance.join(' · ')||'별도 기재 없음'}
보충: ${f.insurance_note||'적용 법령에 따릅니다.'}

7. 당사자 정보
사업장명: ${f.business_name}
사업주명: ${f.employer_name}
사업장 주소: ${f.business_address}
사업장 연락처: ${f.business_phone}
근로자명: ${f.employee_name}
근로자 주소: ${f.employee_address}
근로자 연락처: ${f.employee_phone}

8. 계약서 교부 및 기타 약정
서명 완료된 계약서는 사업주와 근로자의 OMS 관련문서에 동일한 PDF로 보관하며 열람·다운로드할 수 있습니다.
${f.extra||'추가 약정 없음'}
본 계약에서 정하지 않은 사항은 적용 법령 및 취업규칙에 따릅니다.

작성일: ${f.written_date}`;}
  function update(){host.querySelector('[data-field="end"]').disabled=f.term!=='fixed';if(mode==='structured'){body.value=text();employer.value=f.employer_name;}}
  host.addEventListener('input',()=>{read();if(mode==='structured')update();changed();});host.addEventListener('change',()=>{read();update();changed();});
  body.addEventListener('input',()=>{mode='manual';ownerLabel.hidden=false;});
  host.querySelector('#useStructured').onclick=()=>{if(mode==='manual'&&!confirm('직접 수정한 전문을 입력 항목으로 다시 생성할까요?'))return;mode='structured';ownerLabel.hidden=true;update();changed();};
  update();
  return {fields(){read();return {...f,editor_mode:mode};},manual(){mode='manual';details.open=true;ownerLabel.hidden=false;},validate(){read();if(mode==='manual'){if(!body.value.trim()||body.value.includes('【입력】')||body.value.includes('{{')||!employer.value.trim())throw Error('계약 내용과 사업주명을 모두 입력해주세요.');return;}const required=['start','place','job','start_time','end_time','break_minutes','holiday','amount','pay_day','pay_period','pay_method','business_name','employer_name','business_phone','business_address','employee_name','employee_phone','employee_address','written_date'];for(const key of required){if(String(f[key]??'').trim()===''){host.querySelector(`[data-field="${key}"]`).focus();throw Error('근로조건, 임금 및 당사자 정보를 모두 입력해주세요.');}}if(!f.days.length)throw Error('근무요일을 선택해주세요.');if(f.term==='fixed'&&(!f.end||f.end<f.start))throw Error('계약 종료일을 확인해주세요.');if(!Number.isInteger(Number(f.pay_day))||Number(f.pay_day)<1||Number(f.pay_day)>31)throw Error('급여일은 1~31로 입력해주세요.');if(Number(f.amount)<=0||Number(f.amount)>1e10)throw Error('계약 금액을 확인해주세요.');if(Number(f.break_minutes)<0||Number(f.break_minutes)>1440)throw Error('휴게시간을 확인해주세요.');update();}};
 }
 return {mount};
})();
