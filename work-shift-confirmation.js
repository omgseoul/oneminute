(function(){
 'use strict';
 const title='근무 12시간 초과 알림';
 const description='근무중인 경우 아래의 버튼을 눌러주십시오.\n10분 안에 누르지 않으면 퇴근 처리되며, 이후 별도로 수정하여 주십시오.';
 let dialog=null,current=null,checking=false,sending=false,nativeId=null,clockOffset=0,stopped=false;
 const css=document.createElement('link');css.rel='stylesheet';css.href='work-shift-confirmation.css?v=20261107';document.head.append(css);
 function close(){if(dialog){dialog.close();dialog.remove();}dialog=null;current=null;nativeId=null;}
 function paint(data,token){
  if(omgSession.get()?.accessToken!==token)return;
  clockOffset=Date.parse(data.server_now)-Date.now();
  const session=omgSession.fromResponse(data.session,token);
  if(JSON.stringify(session)!==JSON.stringify(omgSession.get())){
   omgSession.set(session);window.dispatchEvent(new CustomEvent('omg:work-shift-state',{detail:data.session}));
  }
  if(!data.pending){close();return;}
  current=data.pending;
  if(typeof window.OMGNative?.showWorkConfirmation==='function'){
   if(nativeId!==current.id){nativeId=current.id;window.OMGNative.showWorkConfirmation(current.id);}return;
  }
  if(!dialog){
   dialog=document.createElement('dialog');dialog.className='oms-work-confirmation';dialog.setAttribute('aria-labelledby','work-confirmation-title');
   const h=document.createElement('h2');h.id='work-confirmation-title';h.textContent=title;
   const p=document.createElement('p');p.textContent=description;
   const count=document.createElement('small');count.className='work-confirmation-time';count.setAttribute('aria-live','off');
   const error=document.createElement('p');error.className='work-confirmation-error';error.setAttribute('role','status');
   const button=document.createElement('button');button.type='button';button.textContent='예, 계속 근무중입니다.';button.onclick=confirm;
   dialog.append(h,p,count,error,button);dialog.addEventListener('cancel',e=>e.preventDefault());document.body.append(dialog);dialog.showModal();button.focus();
  }
  tick();
 }
 function tick(){
  if(!dialog||!current)return;
  const left=Math.max(0,Math.ceil((Date.parse(current.deadline_at)-Date.now()-clockOffset)/1000));
  dialog.querySelector('small').textContent=left?`확인까지 ${Math.floor(left/60)}분 ${String(left%60).padStart(2,'0')}초 남음`:'확인 시간이 지나 근무 종료 상태를 확인하고 있습니다.';
  dialog.querySelector('button').disabled=sending||left===0;
  if(left===0)check();
 }
 async function request(id){
  const session=omgSession.get();if(session?.sessionKind!=='staff')return null;
  const {data,error}=await omgSupabase.rpc('work_shift_confirmation',{p_access_token:session.accessToken,p_confirmation_id:id||null});
  if(error||!data?.ok)throw new Error(data?.message||'연결을 확인하고 다시 눌러주세요. 서버 확인 후 근무가 연장됩니다.');
  if(omgSession.get()?.accessToken!==session.accessToken)return null;
  paint(data,session.accessToken);return data;
 }
 async function confirm(){
  if(sending||!current)return;sending=true;tick();
  try{await request(current.id);window.dispatchEvent(new Event('omg:messages-changed'));}
  catch(e){if(dialog)dialog.querySelector('.work-confirmation-error').textContent=e.message;}
  finally{sending=false;tick();}
 }
 async function check(){
  if(checking||stopped||document.hidden)return;
  if(omgSession.get()?.sessionKind!=='staff'){close();return;}
  checking=true;try{await request();}catch(_){}finally{checking=false;}
 }
 window.addEventListener('omg:session-changed',()=>{if(!omgSession.get())close();else check();});
 window.addEventListener('pageshow',()=>{stopped=false;nativeId=null;check();});
 window.addEventListener('pagehide',()=>{stopped=true;});
 window.addEventListener('focus',()=>{nativeId=null;check();});
 document.addEventListener('visibilitychange',()=>{if(!document.hidden){nativeId=null;check();}});
 setInterval(check,15000);setInterval(tick,1000);check();
 window.OMSWorkShiftConfirmation={check};
})();
