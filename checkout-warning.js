(function(){
 function show(warning,index,total){
  return new Promise(resolve=>{
   const overlay=document.createElement('div');overlay.className='checkout-warning-overlay';
   const dialog=document.createElement('section');dialog.className='checkout-warning-card';dialog.setAttribute('role','dialog');dialog.setAttribute('aria-modal','true');dialog.setAttribute('aria-labelledby','checkout-warning-title');
   dialog.innerHTML='<div class="checkout-warning-banner">퇴근 전 확인</div><h2 id="checkout-warning-title">근무시간 경고</h2><p class="checkout-warning-message"></p><div class="checkout-warning-context"></div><div class="checkout-warning-response"></div><small></small><div class="checkout-warning-actions"><button type="button" data-cancel>돌아가기</button><button type="button" data-confirm>완료</button></div>';
   dialog.querySelector('p').textContent=warning.message;
   const context=dialog.querySelector('.checkout-warning-context');
   if(warning.expected_at&&warning.actual_at){try{const format=value=>new Intl.DateTimeFormat('ko-KR',{timeZone:warning.timezone||'Asia/Seoul',month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit',hour12:false}).format(new Date(value));context.textContent=`기준 퇴근 ${format(warning.expected_at)} · 보고 시각 ${format(warning.actual_at)}`;}catch(_){context.hidden=true;}}else context.hidden=true;dialog.querySelector('small').textContent=total>1?`${index+1} / ${total}`:'';
   overlay.append(dialog);document.body.append(overlay);
   const form=window.OMSAttendanceResponse.mount(dialog.querySelector('.checkout-warning-response'),dialog.querySelector('[data-confirm]'));
   const previous=document.activeElement;
   const finish=value=>{overlay.remove();previous?.focus?.();resolve(value);};
   dialog.querySelector('[data-cancel]').onclick=()=>finish(false);dialog.querySelector('[data-confirm]').onclick=()=>{if(form.valid())finish(form.value());};
   dialog.addEventListener('keydown',event=>{if(event.key==='Escape'){event.preventDefault();finish(false);}if(event.key==='Tab'){const controls=[...dialog.querySelectorAll('button:not(:disabled),textarea')].filter(x=>!x.closest('[hidden]'));const first=controls[0],last=controls.at(-1);if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}}});
   dialog.querySelector('[data-agreed]').focus();
  });
 }
 window.OMSCheckoutWarning={async confirm(rpc,token,warnings){
  for(let i=0;i<warnings.length;i++){
   const response=await show(warnings[i],i,warnings.length);if(!response)throw new Error('퇴근보고를 취소했습니다. 입력한 내용은 유지됩니다.');
   const result=await rpc('respond_checkout_warning',{...response,p_access_token:token,p_rule_id:warnings[i].rule_id,p_rule_updated_at:warnings[i].rule_updated_at});
   if(!result?.ok)throw new Error(result?.message||'확인 내용을 저장하지 못했습니다. 다시 시도해주세요.');
  }
 }};
})();
