(() => {
  const bridge = window.OMSCalendarAndroid;
  if (!new URLSearchParams(location.search).has('app')) return;
  if (!bridge) document.getElementById('companionSettings').hidden = true;
  if(bridge?.getAppInfo&&bridge?.checkForUpdate){
    const title=document.querySelector('.calendar-top>a'),button=document.createElement('button');button.id='calendarUpdate';button.type='button';button.textContent='업데이트';button.hidden=true;button.setAttribute('aria-label','OMS 캘린더 업데이트');title.after(button);
    button.onclick=()=>bridge.checkForUpdate();
    async function refreshUpdate(){try{const installed=JSON.parse(bridge.getAppInfo()),r=await fetch('downloads/oms-calendar-update.json',{cache:'no-store'}),latest=await r.json();button.hidden=!(Number.isSafeInteger(installed.version_code)&&Number.isSafeInteger(latest.version_code)&&latest.version_code>installed.version_code);}catch{button.hidden=true;}}
    refreshUpdate();window.addEventListener('pageshow',refreshUpdate);document.addEventListener('visibilitychange',()=>{if(!document.hidden)refreshUpdate();});
  }
  if (bridge) window.addEventListener("omg:session-changed", () => { if (!window.omgSession.get()) bridge.clearSession(); });
  window.OMSCalendarCompanion = {
    session(session) {
      bridge?.setSession(session.accessToken, session.sessionKind, session.ownerId || session.employeeId || '', session.propertyId || '', session.timezone || 'Asia/Seoul');
    },
    settings() { bridge?.openSettings(); }
  };
})();
