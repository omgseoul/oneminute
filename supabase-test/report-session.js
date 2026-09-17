(function () {
  const contexts = {
    "morning1.html": { shift: "morning" }, "morning2.html": { shift: "morning" },
    "afternoon1.html": { shift: "afternoon" }, "afternoon2.html": { shift: "afternoon" }
  };
  const context = contexts[location.pathname.split("/").pop()];
  const formPage = document.getElementById("formPage");
  const notice = document.createElement("div");
  notice.setAttribute("role", "status");
  notice.style.cssText = "padding:16px;margin:12px;border-radius:12px;background:#edf5ff;color:#183153;font:14px/1.6 sans-serif";
  notice.textContent = "로그인 상태를 확인하고 있습니다…";
  if (formPage) { formPage.inert = true; formPage.before(notice); }
  else document.body.prepend(notice);
  const api = window.omgReport = { session: null, ready: null };
  // This preview deliberately contains no report-writing or webhook transport.
  api.submit = async function () {
    throw new Error("로그인 확인용 화면에서는 보고 저장과 알림 전송이 꺼져 있습니다.");
  };
  api.getCheckinTimeDiff = function (regularTime) {
    if (!api.session) throw new Error("로그인 확인이 필요합니다.");
    const parts = new Intl.DateTimeFormat("en-GB", {
      timeZone: api.session.timezone, hour: "2-digit", minute: "2-digit", hourCycle: "h23"
    }).formatToParts(new Date(api.session.clockInAt));
    const hour = Number(parts.find(p => p.type === "hour").value);
    const minute = Number(parts.find(p => p.type === "minute").value);
    const [regularHour, regularMinute] = regularTime.split(":").map(Number);
    return hour * 60 + minute - regularHour * 60 - regularMinute;
  };
  api.clockInText = function () {
    return new Date(api.session.clockInAt).toLocaleString("ko-KR", { timeZone: api.session.timezone });
  };
  api.ready = (async () => {
    const session = await window.omgSession.require({ allowCompleted: true });
    if (!session) return null;
    if (!context || session.shift !== context.shift) {
      location.replace("index.html");
      return null;
    }
    api.session = session;
    const worker = document.getElementById("worker");
    if (worker) {
      let option = [...worker.options].find(o => o.value === session.employeeName || o.text === session.employeeName);
      if (!option) { option = new Option(session.employeeName, session.employeeName); worker.add(option); }
      worker.value = option.value;
      worker.disabled = true;
    }
    if (formPage) formPage.inert = false;
    notice.textContent = "연결 확인 완료 · " + session.employeeName + " · 출근시각 " + api.clockInText() + " · 보고 저장/알림 전송은 꺼져 있습니다.";
    return session;
  })().catch(error => {
    notice.textContent = error.message || "로그인 상태를 확인하지 못했습니다. 새로고침해주세요.";
    return null;
  });
})();
