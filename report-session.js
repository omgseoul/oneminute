(function () {
  const contexts = {
    "morning1.html": { shift: "morning", reportType: "clock_in" },
    "morning2.html": { shift: "morning", reportType: "clock_out" },
    "afternoon1.html": { shift: "afternoon", reportType: "clock_in" },
    "afternoon2.html": { shift: "afternoon", reportType: "clock_out" }
  };
  const context = contexts[location.pathname.split("/").pop()];
  const formPage = document.getElementById("formPage");
  const donePage = document.getElementById("donePage");
  const notice = document.createElement("div");
  notice.setAttribute("role", "status");
  notice.style.cssText = "padding:16px;margin:12px;border-radius:12px;background:#edf5ff;color:#183153;font:14px/1.6 sans-serif";
  notice.textContent = "로그인 상태를 확인하고 있습니다…";
  if (formPage) { formPage.inert = true; formPage.before(notice); }
  else document.body.prepend(notice);
  let saved = null;
  let inFlight = null;
  let initialError = null;
  const api = window.omgReport = { session: null, ready: null };

  async function rpc(name, args) {
    const { data, error } = await window.omgSupabase.rpc(name, args);
    if (error) throw new Error("연결을 확인하고 다시 시도해주세요.");
    return data;
  }
  function showPending(message) {
    notice.hidden = false;
    notice.replaceChildren(document.createTextNode(message || "보고는 저장됐습니다. 저장된 내용으로 전달을 다시 시도해주세요."));
    const retry = document.createElement("button");
    retry.type = "button";
    retry.textContent = "저장된 보고 다시 전송";
    retry.style.cssText = "display:block;margin-top:10px;padding:10px;border:0;border-radius:8px;background:#2467bd;color:white";
    retry.onclick = async () => {
      retry.disabled = true;
      try { await api.submit(null); } catch (_) { /* The notice shows the failure. */ }
    };
    notice.append(retry);
  }
  async function finish() {
    notice.hidden = true;
    if (formPage) formPage.style.display = "none";
    if (donePage) donePage.style.display = "block";
    if (context.reportType === "clock_out") await window.omgSession.logout();
    window.scrollTo(0, 0);
  }
  function receiptKey(id) { return "omg_make_accepted_" + id; }
  function hasReceipt(id) {
    try { return localStorage.getItem(receiptKey(id)) === "true"; } catch (_) { return false; }
  }
  function rememberReceipt(id) {
    try { localStorage.setItem(receiptKey(id), "true"); } catch (_) { /* Database still stores the report. */ }
  }
  api.submit = function (payload, url) {
    if (inFlight) return inFlight;
    inFlight = (async () => {
      const session = await api.ready;
      if (!session) throw initialError || new Error("다시 로그인해주세요.");
      if (formPage) formPage.inert = true;
      const args = { p_access_token: session.accessToken, p_report_type: context.reportType };
      const record = saved
        ? await rpc("get_work_report", args)
        : await rpc("save_work_report", { ...args, p_payload: payload });
      if (!record?.ok) throw new Error(record?.message || "보고를 저장하지 못했습니다. 다시 로그인해주세요.");
      saved = record;
      notice.hidden = false;
      notice.textContent = "보고가 저장됐습니다. 전달 상태를 확인하고 있습니다…";
      if (!saved.make_accepted && !hasReceipt(saved.report_id)) {
        const endpoint = url || (typeof webhookUrl === "string" ? webhookUrl : null);
        if (!endpoint) throw new Error("보고는 저장됐지만 전달 주소를 확인하지 못했습니다.");
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 20000);
        let response;
        try {
          response = await fetch(endpoint, {
            method: "POST", headers: { "Content-Type": "application/json" },
            body: JSON.stringify(saved.payload), signal: controller.signal
          });
        } finally { clearTimeout(timer); }
        if (!response.ok) throw new Error("보고는 저장됐지만 전달에 실패했습니다.");
        rememberReceipt(saved.report_id);
      }
      if (!saved.make_accepted) {
        const ack = await rpc("mark_report_delivered", {
          p_access_token: session.accessToken, p_report_id: saved.report_id
        });
        if (!ack?.ok) throw new Error(ack?.message || "전달 상태 확인을 다시 시도해주세요.");
        saved.make_accepted = true;
      }
      try { localStorage.removeItem(receiptKey(saved.report_id)); } catch (_) {}
      await finish();
      return saved;
    })().catch(error => {
      if (saved) showPending(error.message || "보고는 저장됐습니다. 전달을 다시 시도해주세요.");
      else {
        notice.hidden = false;
        notice.textContent = error.message || "저장하지 못했습니다. 다시 시도해주세요.";
        if (api.session && formPage) formPage.inert = false;
      }
      throw error;
    }).finally(() => { inFlight = null; });
    return inFlight;
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
    const record = await rpc("get_work_report", {
      p_access_token: session.accessToken, p_report_type: context.reportType
    });
    if (record?.ok) {
      saved = record;
      if (record.make_accepted) await finish();
      else showPending("저장된 보고의 전달이 완료되지 않았습니다. 아래 버튼으로 다시 시도해주세요.");
    } else if (record?.code === "not_found" && session.status === "working") {
      notice.hidden = true;
      if (formPage) formPage.inert = false;
    } else {
      throw new Error(record?.message || "이미 종료된 근무입니다. 다시 로그인해주세요.");
    }
    return session;
  })().catch(error => {
    initialError = error;
    notice.textContent = error.message || "로그인 상태를 확인하지 못했습니다. 새로고침해주세요.";
    return null;
  });
})();
