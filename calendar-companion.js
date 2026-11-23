(() => {
  const bridge = window.OMSCalendarAndroid;
  if (!new URLSearchParams(location.search).has('app')) return;
  if (!bridge) document.getElementById('companionSettings').hidden = true;
  if (bridge) window.addEventListener("omg:session-changed", () => { if (!window.omgSession.get()) bridge.clearSession(); });
  window.OMSCalendarCompanion = {
    session(session) {
      bridge?.setSession(session.accessToken, session.sessionKind, session.ownerId || session.employeeId || '', session.propertyId || '', session.timezone || 'Asia/Seoul');
    },
    settings() { bridge?.openSettings(); }
  };
})();
