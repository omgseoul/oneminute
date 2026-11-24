/* Only the Calendar companion owns this navigation. Browser/OMS routes stay unchanged. */
(() => {
  const bridge=window.OMSCalendarAndroid;
  if(!bridge||new URLSearchParams(location.search).get('app')!=='todo')return;
  document.documentElement.classList.add('widget-todo');
  const style=document.createElement('style');
  style.textContent='html.widget-todo.omg-brand::after{content:"할 일을 여는 중…";background:none;animation:none;width:auto;height:auto;font-size:14px;color:#758094}';
  document.head.append(style);
  let consumed=false;
  function clearTarget(){const url=new URL(location.href);url.searchParams.delete('task');history.replaceState(history.state,'',url.pathname+url.search+url.hash);}
  function back(){
    const dialog=document.querySelector('dialog[open]');if(dialog){dialog.close();return true;}
    const overlays=[...document.querySelectorAll('.overlay')].filter(node=>!node.hidden);
    if(overlays.length){overlays.at(-1).hidden=true;document.body.style.overflow=overlays.length>1?'hidden':'';clearTarget();return true;}
    return false;
  }
  window.OMSWidgetNavigation={
    back,changed(){bridge.refreshWidgets?.();},
    ready(session,items,open){
      bridge.setSession(session.accessToken,session.sessionKind,session.ownerId||session.employeeId||'',session.propertyId||'',session.timezone||'Asia/Seoul');
      if(consumed)return;consumed=true;
      const id=new URLSearchParams(location.search).get('task');
      if(id){const item=items.find(item=>item.id===id);if(item)open(item);else document.getElementById('message').textContent='이 항목은 삭제되었거나 현재 계정에서 볼 수 없습니다.';clearTarget();}
    }
  };
  const home=document.querySelector('.back');
  if(home){home.textContent='닫기';home.onclick=event=>{event.preventDefault();if(!back())bridge.exitToLauncher?.();};}
  window.addEventListener('omg:session-changed',()=>{if(!window.omgSession?.get())bridge.clearSession();});
  if(window.OMSMissionTasks){const original=OMSMissionTasks.privateAction;OMSMissionTasks.privateAction=async(...args)=>{const result=await original(...args);if(args[1]!=='list')bridge.refreshWidgets?.();return result;};}
})();
