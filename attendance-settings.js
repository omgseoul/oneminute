(function(){
  const boxes=[...document.querySelectorAll('input[name="clockInBasis"]')];
  const report=document.getElementById('attendanceReportOptions'),nfc=document.getElementById('attendanceNfcOptions');
  const offset=document.getElementById('attendanceOffset'),hint=document.getElementById('attendanceOffsetHint');
  const values=document.getElementById('attendanceNfcValues'),status=document.getElementById('attendanceNfcStatus');
  const manual=document.getElementById('attendanceNfcManual'),input=document.getElementById('attendanceNfcUid');
  let tags=[],generation=0,scan=null,loaded=false;
  function basis(){return boxes.find(box=>box.checked)?.value||'first_login';}
  function cancel(){generation++;scan?.cancel();scan=null;document.getElementById('attendanceNfcScan').textContent='사용할 NFC 태그';}
  function update(){report.hidden=basis()!=='report';nfc.hidden=basis()!=='nfc';const n=Number(offset.value);hint.textContent=!Number.isInteger(n)?'분 단위 숫자를 입력해주세요.':n===0?'출근보고 전송 시각이 출근시각으로 기록됩니다.':`출근보고 전송 ${Math.abs(n)}분 ${n<0?'전':'후'}가 출근시각으로 기록됩니다.`;}
  function show(message,error=false){status.textContent=message;status.classList.toggle('error',error);}
  function render(){values.replaceChildren();tags.forEach(uid=>{const card=document.createElement('div');card.className='attendance-nfc-value';card.append(document.createTextNode(uid));const del=document.createElement('button');del.type='button';del.textContent='×';del.setAttribute('aria-label',`${uid} 태그 삭제`);del.onclick=()=>{tags=tags.filter(x=>x!==uid);render();show('설정 저장을 누르면 삭제가 적용됩니다.');};card.append(del);values.append(card);});}
  function add(value){const uid=window.OMSAttendanceNfc.normalize(value);if(tags.includes(uid)){show('이미 추가한 NFC 태그입니다.');return;}if(tags.length>=10)throw new Error('NFC 태그는 최대 10개까지 등록할 수 있습니다.');tags.push(uid);render();show('태그가 추가되었습니다. 설정 저장을 눌러 적용해주세요.');}
  boxes.forEach(box=>box.addEventListener('change',()=>{boxes.forEach(other=>other.checked=other===box);cancel();update();}));
  offset.addEventListener('input',update);
  document.querySelectorAll('[data-attendance-step]').forEach(button=>button.onclick=()=>{offset.value=String(Math.max(-1440,Math.min(1440,(Number(offset.value)||0)+Number(button.dataset.attendanceStep))));update();});
  document.getElementById('attendanceNfcManualToggle').onclick=()=>{cancel();manual.hidden=!manual.hidden;if(!manual.hidden)input.focus();};
  const addManual=()=>{try{add(input.value);input.value='';}catch(error){show(error.message,true);}};
  document.getElementById('attendanceNfcAdd').onclick=addManual;
  input.addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();addManual();}});
  document.getElementById('attendanceNfcScan').onclick=async()=>{if(scan){cancel();show('태그 읽기를 취소했습니다.');return;}const seq=++generation;try{scan=window.OMSAttendanceNfc.scan();document.getElementById('attendanceNfcScan').textContent='읽기 취소';show('휴대폰 뒷면에 사용할 NFC 태그를 대주세요.');const uid=await scan.promise;if(seq===generation)add(uid);}catch(error){if(seq===generation)show(error.message,true);}finally{if(seq===generation){scan=null;document.getElementById('attendanceNfcScan').textContent='사용할 NFC 태그';}}};
  document.querySelector('.attendance-settings-menu').addEventListener('toggle',event=>{if(!event.currentTarget.open)cancel();});
  window.OMSAttendanceSettings={
    reset(){loaded=false;cancel();boxes.forEach(box=>box.checked=box.value==='first_login');update();tags=[];offset.value='0';input.value='';manual.hidden=true;show('');render();},
    set(data){this.reset();boxes.forEach(box=>box.checked=box.value===data.basis);offset.value=String(data.report_offset_minutes||0);tags=[...(data.nfc_tags||[])];render();update();loaded=true;},
    value(){if(!loaded)throw new Error('근태설정을 불러오는 중입니다. 잠시 후 다시 시도해주세요.');const minutes=Number(offset.value);if(offset.value.trim()===''||!Number.isInteger(minutes)||Math.abs(minutes)>1440)throw new Error('출근보고 시간 조정은 -1440~1440분 사이의 정수로 입력해주세요.');if(basis()==='nfc'&&!tags.length)throw new Error('사용할 NFC 태그를 등록해주세요.');if(input.value.trim())throw new Error('입력한 NFC 값을 추가하거나 지워주세요.');return {basis:basis(),report_offset_minutes:minutes,nfc_tags:tags};}
  };
  update();
})();
