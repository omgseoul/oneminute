(() => {
  const bridge = window.OMSCalendarAndroid;
  if (!new URLSearchParams(location.search).has('app')) return;
  if (!bridge) document.getElementById('companionSettings').hidden = true;
  const button = document.getElementById('calendarUpdate');
  if (bridge && button) {
    let sequence = 0;
    async function refreshUpdate() {
      const request = ++sequence;
      try {
        const response = await fetch('/downloads/oms-calendar-update.json', {cache:'no-store'});
        if (!response.ok) return;
        const latest = await response.json();
        // The version bridge first shipped in 1.3.0 (version code 8).
        const installed = bridge.getAppInfo ? JSON.parse(bridge.getAppInfo()).version_code : 7;
        const url = new URL(latest.apk_url, location.origin);
        if (request !== sequence) return;
        const available = Number.isSafeInteger(installed) && Number.isSafeInteger(latest.version_code)
          && latest.version_code > installed && url.origin === location.origin
          && /^\/downloads\/OMS-Calendar-\d+\.\d+\.\d+\.apk$/.test(url.pathname);
        button.hidden = !available;
        button.onclick = available ? () => {
          if (bridge.checkForUpdate) bridge.checkForUpdate();
          else location.assign('https://omgseoul.github.io/oneminute' + url.pathname);
        } : null;
      } catch {
        // Keep a previously verified update visible during a temporary network failure.
      }
    }
    refreshUpdate();
    window.addEventListener('pageshow', refreshUpdate);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshUpdate(); });
  }
  if (bridge) window.addEventListener("omg:session-changed", () => { if (!window.omgSession.get()) bridge.clearSession(); });
  window.OMSCalendarCompanion = {
    session(session) {
      bridge?.setSession(session.accessToken, session.sessionKind, session.ownerId || session.employeeId || '', session.propertyId || '', session.timezone || 'Asia/Seoul');
    },
    settings() { bridge?.openSettings(); }
  };
})();
