(function(){
  let activeDialog=null;
  function dialog(title,{secondary=null}={}){
    if(activeDialog)return activeDialog.promise;
    const node=document.createElement('dialog');node.className='oms-action-dialog attendance-dialog';
    const heading=document.createElement('h2');heading.id='attendanceDialogTitle';heading.textContent=title;
    const head=document.createElement('div');head.className='oms-action-head';head.append(heading);node.append(head);
    node.setAttribute('aria-labelledby',heading.id);
    const buttons=document.createElement('div');buttons.className='oms-action-buttons';node.append(buttons);
    if(secondary){const bypass=document.createElement('button');bypass.type='button';bypass.className='oms-action-button';bypass.textContent=secondary;bypass.onclick=()=>node.close('proceed');buttons.append(bypass);}
    const okay=document.createElement('button');okay.type='button';okay.className='oms-action-button primary';okay.textContent='확인';okay.onclick=()=>node.close('dismiss');buttons.append(okay);
    const promise=new Promise(resolve=>node.addEventListener('close',()=>{node.remove();activeDialog=null;resolve(node.returnValue==='proceed');},{once:true}));
    activeDialog={promise,node};document.body.append(node);node.showModal();okay.focus();return promise;
  }
  function firstLabel(basis){return basis==='nfc'?'도착':basis?'로그인':'확인중';}
  function renderProgress(host,state,session){
    const completed=(state?.status||session.status)==='completed';
    const reported=!!(state?state.checkin_report_at:session.checkinReportAt);
    const arrived=state?.basis==='nfc'?!!state.entry_at:!!state;
    // An untagged NFC shift has not reached any step. Opening a form is not a report.
    const current=completed?3:reported?2:arrived?0:-1;
    const labels=[firstLabel(state?.basis),'출근보고','근무중','퇴근보고'];
    host.className='attendance-progress';host.setAttribute('aria-label','출퇴근 진행 상태');
    host.replaceChildren();
    labels.forEach((label,index)=>{
      const step=document.createElement('li'),dot=document.createElement('span'),text=document.createElement('span');
      step.dataset.step=String(index);dot.className='attendance-progress-dot';text.className='attendance-progress-label';text.textContent=label;dot.setAttribute('aria-hidden','true');
      const done=index<current||completed;
      step.className=done?'is-done':index===current?'is-current':'';
      if(index===current)step.setAttribute('aria-current','step');
      step.setAttribute('aria-label',label+(done?' 완료':index===current?(index===1?' 대기':' 현재 단계'):' 대기'));
      dot.textContent=done?'✓':'';step.append(dot,text);host.append(step);
    });
    host.classList.toggle('is-nfc',state?.basis==='nfc');
  }
  function renderHeading(host,state,session){
    const reported=!!(state?state.checkin_report_at:session.checkinReportAt),completed=(state?.status||session.status)==='completed';
    const dot=document.createElement('i');dot.className='online-dot'+(completed?' ended':reported?' reported':'');dot.setAttribute('aria-hidden','true');
    const name=document.createElement('span');name.className='working-self-name';name.textContent=session.employeeName||'근무자';
    host.replaceChildren(dot,name,document.createTextNode(completed?' 근무 종료':reported?' 근무중':' 로그인'));
    host.setAttribute('aria-label',`${session.employeeName||'근무자'} · ${completed?'근무 종료':reported?'근무중':'로그인 · 출근보고 전'}`);
  }
  async function mayOpenReport(controller){
    try{
      const state=await controller.refresh();
      if(!state)throw new Error('출근 상태를 확인하지 못했습니다. 다시 시도해주세요.');
      if(state.basis!=='nfc'||state.entry_at||state.checkin_report_at||state.status==='completed')return true;
      return await dialog('NFC 태그를 해주십시오',{secondary:'무시하고 메뉴보기'});
    }catch(error){await dialog(error.message);return false;}
  }
  function bindCheckin(link,controller,navigate=url=>location.assign(url)){
    link.setAttribute('data-oms-managed-navigation','');
    let pending=false;
    link.addEventListener('click',async event=>{
      event.preventDefault();if(pending)return;pending=true;
      try{if(await mayOpenReport(controller)){controller.stop();navigate(link.href);}}finally{pending=false;}
    });
  }
  window.OMSAttendanceFlow={dialog,firstLabel,renderProgress,renderHeading,mayOpenReport,bindCheckin};
})();
