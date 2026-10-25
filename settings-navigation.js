/* Keep edits on cancel and use the OMS dialog for links and device/browser Back.
   beforeunload remains only as the browser-controlled reload/tab-close fallback. */
window.OMSSettingsNavigation={install(isDirty){
  const guard='omsAISettingsGuard',pageURL=location.href;
  let leaving=false,restoring=false,pending=null;
  if(!history.state?.[guard])history.pushState({...history.state,[guard]:true},'',pageURL);
  const dialog=document.getElementById('aiLeaveDialog');
  function confirmLeave(){
    if(pending)return dialog.open?pending:pending.then(confirmLeave);
    pending=new Promise(resolve=>{
      dialog.addEventListener('close',()=>{pending=null;resolve(dialog.returnValue==='leave');},{once:true});
      dialog.returnValue='';dialog.showModal();document.getElementById('aiStay').focus();
    });
    return pending;
  }
  document.getElementById('aiStay').onclick=()=>dialog.close('stay');
  document.getElementById('aiLeave').onclick=()=>dialog.close('leave');
  document.addEventListener('click',async event=>{
    const link=event.target.closest('a[href]');
    if(!link||event.defaultPrevented||event.button!==0||event.metaKey||event.ctrlKey||event.shiftKey||event.altKey||link.target||link.hasAttribute('download')||link.getAttribute('href').startsWith('#'))return;
    if(!isDirty())return;
    event.preventDefault();
    if(pending&&dialog.open)return;
    if(await confirmLeave()){leaving=true;location.assign(link.href);}
  });
  window.addEventListener('popstate',async event=>{
    if(leaving)return;
    if(!event.state?.[guard]){
      // Return to the duplicate entry before asking, so Cancel never leaves this page.
      restoring=true;history.forward();return;
    }
    if(!restoring)return;
    restoring=false;
    const editor=[...document.querySelectorAll('dialog[open]')].at(-1);
    if(editor){editor.close();return;}
    if(!isDirty()||await confirmLeave()){
      leaving=true;
      if(history.length>2)history.go(-2);
      else location.replace('owner-settings.html');
    }
  });
  window.addEventListener('beforeunload',event=>{
    if(!leaving&&isDirty()){event.preventDefault();event.returnValue='';}
  });
  window.addEventListener('pageshow',()=>{leaving=false;restoring=false;});
}};
