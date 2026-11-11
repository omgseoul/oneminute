/* Display-only home snapshots. Server authorization and actions always stay live. */
(function () {
  const KEY = 'oms.home.summary.v1', MAX_AGE = 6 * 60 * 60 * 1000;
  const scopeOf = session => session && session.sessionId && JSON.stringify([
    session.sessionId, session.sessionKind, session.ownerId || '', session.employeeId || '',
    session.propertyId, session.timezone || 'Asia/Seoul'
  ]);
  function clear() { try { sessionStorage.removeItem(KEY); } catch (_) {} }
  function open(session) {
    const scope = scopeOf(session), timezone = session.timezone || 'Asia/Seoul';
    let widgets = {};
    const day = () => new Intl.DateTimeFormat('en-CA', {timeZone: timezone, year:'numeric', month:'2-digit', day:'2-digit'}).format(new Date());
    const active = () => !window.omgSession?.get || scopeOf(window.omgSession.get()) === scope;
    try {
      const saved = JSON.parse(sessionStorage.getItem(KEY) || 'null');
      if (scope && saved?.scope === scope && saved.widgets && typeof saved.widgets === 'object') widgets = saved.widgets;
      else clear();
    } catch (_) { clear(); }
    return {
      read(name, daily = false) {
        const item = widgets[name], age = Date.now() - item?.at;
        return active() && item && age >= 0 && age < MAX_AGE && (!daily || item.day === day()) ? item.value : null;
      },
      write(name, value, forDay = day()) {
        if (!active()) return;
        widgets[name] = {value, day: forDay, at: Date.now()};
        if (scope) try { sessionStorage.setItem(KEY, JSON.stringify({scope, widgets})); } catch (_) {}
      },
      day,
      clear() { widgets = {}; clear(); }
    };
  }
  // Coalesce focus/pageshow/visibility events; allow a genuinely changed inbox to refresh again.
  // If a request stalls, the next refresh can replace it; late replies cannot repaint the UI.
  function channel(task, {minInterval = 1500, timeout = 25000} = {}) {
    let flight = null, generation = 0, lastStart = -Infinity, queued = null;
    function refresh(options = {}) {
      if (flight && Date.now() - lastStart < timeout) {
        if (options.force) queued = options;
        return flight;
      }
      if (!options.force && !flight && Date.now() - lastStart < minInterval) return Promise.resolve();
      const id = ++generation; lastStart = Date.now(); queued = null;
      const job = Promise.resolve().then(() => task(options, () => id === generation))
        .catch(() => {}) // Keep the last successful display on temporary network failures.
        .finally(() => {
          if (flight !== job) return;
          flight = null;
          if (queued) { const next = queued; queued = null; refresh(next); }
        });
      flight = job;
      return job;
    }
    return {refresh, cancel() { generation++; flight = null; queued = null; lastStart = -Infinity; }};
  }
  window.addEventListener('omg:session-changed', () => {
    try {
      const saved = JSON.parse(sessionStorage.getItem(KEY) || 'null');
      if (saved && saved.scope !== scopeOf(window.omgSession?.get?.())) clear();
    } catch (_) { clear(); }
  });
  window.OMSHomeState = {open, channel, clear};
})();
