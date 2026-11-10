/* One response form shared by delivered and pre-checkout attendance warnings. */
window.OMSAttendanceResponse=(()=>{
 function mount(host,button){
  host.innerHTML='<div class="awr-choice"><span>관리자와 기존협의 완료</span><div role="group" aria-label="관리자와 기존협의 완료"><button type="button" data-agreed="yes" aria-pressed="false">네</button><button type="button" data-agreed="no" aria-pressed="false">아니오</button></div></div><label class="awr-reason" hidden><span>사유를 써주세요</span><textarea maxlength="500" rows="3" placeholder="지각·야근 등의 사유를 3자 이상 입력해주세요."></textarea><small>3자 이상 입력해주세요.</small></label>';
  host.classList.add('attendance-warning-response');host.hidden=false;
  let agreed=null;const reason=host.querySelector('textarea'),field=host.querySelector('.awr-reason');
  const valid=()=>agreed===true||(agreed===false&&Array.from(reason.value.trim()).length>=3);
  const refresh=()=>{button.disabled=!valid();field.hidden=agreed!==false;host.querySelector('small').textContent=Array.from(reason.value.trim()).length+'/500 · 3자 이상';};
  host.querySelectorAll('[data-agreed]').forEach(choice=>choice.onclick=()=>{agreed=choice.dataset.agreed==='yes';host.querySelectorAll('[data-agreed]').forEach(x=>x.setAttribute('aria-pressed',String(x===choice)));refresh();if(!agreed)reason.focus();});
  reason.oninput=refresh;button.textContent='완료';refresh();
  return {valid,value:()=>({p_agreed:agreed,p_reason:agreed?'':reason.value.trim()})};
 }
 return {mount};
})();
