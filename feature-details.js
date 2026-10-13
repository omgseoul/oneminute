(() => {
  'use strict';
  document.querySelectorAll('[role="tablist"]').forEach(group => {
    const tabs = [...group.querySelectorAll('[role="tab"][data-panel]')];
    function activate(tab) {
      tabs.forEach(item => {
        const selected = item === tab;
        item.setAttribute('aria-selected', String(selected));
        item.tabIndex = selected ? 0 : -1;
        document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
      });
    }
    tabs.forEach((tab,index) => {
      tab.addEventListener('click',()=>activate(tab));
      tab.addEventListener('keydown',event=>{
        if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
        event.preventDefault();
        const next=event.key==='Home'?0:event.key==='End'?tabs.length-1:(index+(event.key==='ArrowRight'?1:-1)+tabs.length)%tabs.length;
        activate(tabs[next]);tabs[next].focus();
      });
    });
  });
  const complete=document.querySelector('.demo-complete');
  complete?.addEventListener('click',()=>{complete.hidden=true;document.querySelector('.completion-result').hidden=false;});
  const photo=document.getElementById('photo-demo');
  if(photo){
    const scroll=photo.querySelector('.photo-scroll'),zoom=document.getElementById('zoom-demo');
    document.querySelector('.report-photo').addEventListener('click',()=>photo.showModal());
    document.getElementById('close-photo').addEventListener('click',()=>photo.close());
    zoom.addEventListener('click',()=>{const enlarged=scroll.classList.toggle('is-zoomed');zoom.textContent=enlarged?'축소 −':'확대 +';zoom.setAttribute('aria-label',enlarged?'사진 축소':'사진 확대');});
    photo.addEventListener('close',()=>{scroll.classList.remove('is-zoomed');scroll.scrollTo(0,0);zoom.textContent='확대 +';zoom.setAttribute('aria-label','사진 확대');});
  }
  const omit=document.querySelector('[data-photo-omit]');
  if(omit){
    let missing=false;
    const image=document.querySelector('.report-photo'),empty=document.querySelector('[data-photo-missing]'),guard=document.querySelector('[data-photo-guard]'),state=document.querySelector('[data-report-state]'),submit=document.querySelector('[data-report-submit]'),result=document.querySelector('.photo-submit-result');
    omit.addEventListener('click',()=>{
      missing=!missing;image.hidden=missing;empty.hidden=!missing;submit.disabled=missing;guard.classList.toggle('missing',missing);
      guard.textContent=missing?'! 필수 사진이 없습니다. 사진을 첨부해야 제출할 수 있습니다.':'✓ 필수 사진 확인 · 보고 제출 가능';
      state.textContent=missing?'사진 누락':'사진 첨부 완료';state.classList.toggle('green',!missing);state.classList.toggle('red-bg',missing);
      omit.textContent=missing?'사진 첨부 예시 복원':'사진 누락 예시 보기';result.hidden=true;
    });
    submit.addEventListener('click',()=>{if(missing)return;result.textContent='✓ 필수 사진과 함께 보고가 완료되었습니다. · 예시';result.hidden=false;state.textContent='보고 완료';});
  }
  const canvas=document.querySelector('.signature-demo');
  if(canvas){
    const ctx=canvas.getContext('2d'),clear=document.querySelector('[data-sign-clear]'),button=document.querySelector('[data-sign-complete]'),agree=document.querySelector('[data-sign-agree]'),result=document.querySelector('.signature-result');
    let drawing=false,points=1;
    ctx.strokeStyle='#183153';ctx.lineWidth=3.2;ctx.lineCap='round';ctx.lineJoin='round';
    ctx.beginPath();ctx.moveTo(135,118);ctx.bezierCurveTo(171,76,162,40,146,111);ctx.bezierCurveTo(131,164,231,63,217,96);ctx.bezierCurveTo(195,133,244,96,247,105);ctx.bezierCurveTo(249,144,282,78,288,96);ctx.bezierCurveTo(271,134,318,97,332,109);ctx.bezierCurveTo(350,139,384,67,395,96);ctx.bezierCurveTo(382,128,408,134,441,99);ctx.stroke();
    const position=event=>{const box=canvas.getBoundingClientRect();return[(event.clientX-box.left)*canvas.width/box.width,(event.clientY-box.top)*canvas.height/box.height];};
    canvas.addEventListener('pointerdown',event=>{event.preventDefault();drawing=true;canvas.setPointerCapture(event.pointerId);ctx.beginPath();ctx.moveTo(...position(event));});
    canvas.addEventListener('pointermove',event=>{if(!drawing)return;ctx.lineTo(...position(event));ctx.stroke();points++;});
    const stop=()=>{drawing=false;};canvas.addEventListener('pointerup',stop);canvas.addEventListener('pointercancel',stop);
    clear.addEventListener('click',()=>{ctx.clearRect(0,0,canvas.width,canvas.height);points=0;result.hidden=true;});
    button.addEventListener('click',()=>{result.hidden=false;result.classList.remove('error');if(!agree.checked||!points){result.classList.add('error');result.textContent=!agree.checked?'계약 내용을 확인해주세요.':'서명을 입력해주세요.';}else result.textContent='✓ 서명 완료 · PDF 문서함 보관 예시';});
  }
  const send=document.querySelector('[data-urgent-send]'),ack=document.querySelector('[data-urgent-ack]');
  if(send&&ack){
    const preview=document.querySelector('[data-urgent-preview]'),state=document.querySelector('[data-urgent-state]'),delivery=document.querySelector('[data-urgent-delivery]'),copy=preview.querySelector('.urgent-alarm-copy');
    state.setAttribute('aria-live','polite');
    send.addEventListener('click',()=>{preview.classList.remove('acknowledged');state.textContent='미확인';state.classList.remove('green');state.classList.add('red-bg');delivery.textContent='근무자 수신 예시 · 확인 대기';copy.innerHTML='<b>60초 미확인 시 반복 알람</b><span>확인할 때까지 알람이 계속됩니다.</span>';ack.disabled=false;ack.textContent='확인했습니다 · 예시';});
    ack.addEventListener('click',()=>{preview.classList.add('acknowledged');state.textContent='확인 완료';state.classList.remove('red-bg');state.classList.add('green');delivery.textContent='이준호 · 확인 완료 예시';copy.innerHTML='<b>명시적 확인 → 알림 종료</b><span>확인 여부까지 화면에서 살펴보세요.</span>';ack.disabled=true;ack.textContent='확인 완료 · 알림 종료 예시';});
  }
})();