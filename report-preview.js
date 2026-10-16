(() => {
  const KEY = "omg_report_preview";
  const $ = id => document.getElementById(id);
  const dayList = [{label:"월", value:1}, {label:"화", value:2}, {label:"수", value:3}, {label:"목", value:4}, {label:"금", value:5}, {label:"토", value:6}, {label:"일", value:0}];
  let state;
  try { state = JSON.parse(sessionStorage.getItem(KEY) || "null"); } catch (_) {}
  if (!state || !state.property || !state.reportConfig) {
    document.querySelector(".preview-stage").innerHTML = '<div class="preview-error">미리보기 정보를 찾을 수 없습니다. 설정 화면에서 다시 열어주세요.</div>';
    return;
  }
  let screen = "input";
  let submittedValues = null;
  let submittedMemo = null;
  let weekday = new Date().getDay();
  const typeLabel = state.reportType === "clock_out" ? "퇴근보고" : "출근보고";
  document.querySelector('[data-screen="input"]').textContent = typeLabel + " 입력 예시";
  document.querySelector('[data-screen="result"]').textContent = typeLabel + " 결과 예시";
  const reportConfig = state.reportConfig;
  const fields = (state.property.custom_report_fields || []).filter(field => (reportConfig[state.reportType] || []).includes(field.key));
  const allCards = (reportConfig.reminder_cards || []).filter(card => (card.report_types || []).includes(state.reportType));
  const roomTypes = state.property.room_types || [];
  const esc = value => String(value == null ? "" : value).replace(/[&<>\"']/g, ch => ({"&":"&amp;", "<":"&lt;", ">":"&gt;", "\"":"&quot;", "'":"&#39;"}[ch]));

  document.querySelectorAll("[data-screen]").forEach(button => button.addEventListener("click", () => {
    screen = button.dataset.screen;
    render();
  }));
  $("previewBack").addEventListener("click", () => history.back());
  $("previewDays").innerHTML = dayList.map(day => '<button type="button" data-day="' + day.value + '" aria-pressed="false">' + day.label + '</button>').join("");
  $("previewDays").querySelectorAll("[data-day]").forEach(button => button.addEventListener("click", () => {
    weekday = Number(button.dataset.day);
    render();
  }));

  function createStepper(label) {
    const wrap = document.createElement("div"); wrap.className = "stepper";
    const minus = document.createElement("button"); minus.type = "button"; minus.textContent = "−"; minus.setAttribute("aria-label", label + " 수량 줄이기");
    const input = document.createElement("input"); input.type = "number"; input.inputMode = "numeric"; input.min = "0"; input.max = "99"; input.value = "0"; input.className = "compact-input"; input.setAttribute("aria-label", label + " 수량");
    const plus = document.createElement("button"); plus.type = "button"; plus.textContent = "+"; plus.setAttribute("aria-label", label + " 수량 늘리기");
    const set = value => { input.value = String(Math.max(0, Math.min(99, Number(value) || 0))); };
    minus.onclick = () => set(Number(input.value) - 1); plus.onclick = () => set(Number(input.value) + 1);
    wrap.append(minus, input, plus); return wrap;
  }
  function appendRooms(parent, field) {
    if (!roomTypes.length) { const empty = document.createElement("div"); empty.className = "empty"; empty.textContent = "Property 설정에서 객실을 먼저 등록해주세요."; parent.append(empty); return; }
    window.OMSHousingRooms.append(parent, field, roomTypes);
  }

  function createInputField(field) {
    const section = document.createElement("section");
    section.className = "field-card custom-result " + (["third", "half"].includes(field.size) ? field.size : "full");
    section.dataset.field = field.key;
    const head = document.createElement("div"); head.className = "field-head";
    const heading = document.createElement("h2"); heading.textContent = field.label;
    if (field.required) { const mark = document.createElement("span"); mark.className = "required-mark"; mark.textContent = " *"; heading.append(mark); }
    head.append(heading); section.append(head);
    if (field.kind === "text" || field.kind === "numeric") {
      const input = document.createElement("input"); input.className = "custom-value"; input.type = field.kind === "numeric" ? "number" : "text";
      if (field.kind === "numeric") { input.step = "any"; input.inputMode = "decimal"; } else input.maxLength = 500;
      input.setAttribute("aria-label", field.label); head.append(input);
    } else if (field.kind === "counter") {
      const stepper = createStepper(field.label); stepper.querySelector("input").value = ""; head.append(stepper);
    } else if (field.kind === "rooms") {
      const button = document.createElement("button"); button.type = "button"; button.className = "custom-value custom-choice"; button.textContent = "객실선택"; head.append(button);
      const dialog = document.createElement("dialog"); dialog.className = "room-dialog";
      const title = document.createElement("h2"); title.textContent = field.label; dialog.append(title); appendRooms(dialog, field);
      const done = document.createElement("button"); done.type = "button"; done.className = "room-done"; done.textContent = "확인"; done.onclick = () => { const chosen = [...dialog.querySelectorAll("input:checked")].map(input => input.value); section.dataset.previewRooms = JSON.stringify(chosen); section.dataset.previewValue = chosen.join(", "); button.textContent = chosen.length ? chosen.length + "건 " + chosen.join(", ") : "객실선택"; dialog.close(); }; dialog.append(done); section.append(dialog);
      button.onclick = () => dialog.showModal();
    } else if (field.kind === "photo") {
      const photo = document.createElement("div"); photo.className = "custom-photo";
      const button = document.createElement("button"); button.type = "button"; button.className = "custom-value custom-choice"; button.textContent = "사진첨부";
      const picker = document.createElement("input"); picker.type = "file"; picker.accept = "image/*"; picker.multiple = true; picker.hidden = true;
      button.onclick = () => picker.click(); picker.onchange = () => { const count = picker.files.length; section.dataset.previewValue = count ? count + "장 첨부" : ""; button.textContent = count ? count + "장 선택" : "사진첨부"; };
      photo.append(button, picker); head.append(photo);
    }
    return section;
  }
  function createReminders(cards) {
    const section = document.createElement("section"); section.className = "reminder-section";
    section.innerHTML = '<h2>리마인더 카드</h2><p class="help">사진을 누르면 뒷면 안내가 보입니다. 모든 내용을 확인해주세요.</p><div class="directive-grid"></div>';
    const grid = section.querySelector(".directive-grid");
    cards.forEach(cardData => {
      const card = document.createElement("article"); card.className = "directive-card"; card.tabIndex = 0;
      card.innerHTML = '<div class="directive-inner"><div class="directive-face directive-front"><img alt=""><span class="directive-label"></span></div><div class="directive-face directive-back"><h3></h3><p></p><button class="ack" type="button">이해했음</button></div></div>';
      const img = card.querySelector("img"); img.src = cardData.image; img.alt = cardData.title;
      card.querySelector(".directive-label").textContent = cardData.title; card.querySelector("h3").textContent = cardData.title; card.querySelector("p").textContent = cardData.text;
      card.addEventListener("click", event => { if (!event.target.closest(".ack")) card.classList.toggle("flipped"); });
      card.querySelector(".ack").addEventListener("click", event => { event.stopPropagation(); card.classList.add("acknowledged", "flipped"); event.currentTarget.textContent = "✓ 이해했음"; event.currentTarget.disabled = true; });
      grid.append(card);
    });
    return section;
  }
  function sampleValue(field) {
    if (submittedValues) return submittedValues[field.key] || "미입력";
    if (field.kind === "numeric" || field.kind === "counter") return "3";
    if (field.kind === "rooms") return roomTypes.flatMap(group => (group.rooms || []).length ? group.rooms : [group.name]).slice(0, 3);
    if (field.kind === "photo") return "사진 첨부";
    return "예시 입력값";
  }
  function renderInput(host) {
    const top = document.createElement("div"); top.className = "top";
    top.innerHTML = '<span class="back">미리보기 화면</span><span class="property"></span>'; top.querySelector(".property").textContent = state.property.name || ""; host.append(top);
    const hero = document.createElement("section"); hero.className = "hero";
    hero.innerHTML = '<h1></h1><p>직원별로 설정된 항목을 확인해주세요.</p><div class="clock"></div>';
    hero.querySelector("h1").textContent = typeLabel; hero.querySelector(".clock").textContent = "근무자: " + (state.employeeName || "근무자") + " · 출근시각 예시 08:58"; host.append(hero);
    const form = document.createElement("div"); form.id = "fields"; form.className = "fields";
    fields.forEach(field => form.append(createInputField(field)));
    if (!fields.length && !(reportConfig[state.reportType] || []).includes("reminder_cards")) { const empty = document.createElement("div"); empty.className = "empty"; empty.textContent = "설정된 보고 항목이 없습니다. 특이사항을 작성할 수 있습니다."; form.append(empty); }
    host.append(form);
    const memo = document.createElement("section"); memo.className = "memo-card"; memo.innerHTML = '<label>특이사항</label><textarea placeholder="추가로 보고할 내용이 있으면 입력해주세요."></textarea>'; host.append(memo);
    const cards = allCards.filter(card => (card.report_weekdays?.[state.reportType] || card.weekdays || [0,1,2,3,4,5,6]).includes(weekday));
    if ((reportConfig[state.reportType] || []).includes("reminder_cards") && cards.length) host.append(createReminders(cards));
    const submit = document.createElement("button"); submit.className = "submit"; submit.type = "button"; submit.textContent = "보고 제출";
    submit.onclick = () => {
      submittedValues = {};
      fields.forEach(field => {
        const section = [...form.querySelectorAll(".field-card")].find(card => card.dataset.field === field.key);
        const input = section?.querySelector(field.kind === "counter" ? ".stepper input" : ".custom-value:not(button)");
        submittedValues[field.key] = field.kind === "rooms" ? JSON.parse(section?.dataset.previewRooms || "[]") : (section?.dataset.previewValue || input?.value || "").trim();
      });
      submittedMemo = host.querySelector(".memo-card textarea")?.value.trim() || "";
      screen = "result"; render(); document.querySelector(".preview-stage").scrollTop = 0;
    };
    host.append(submit);
  }
  function renderResult(host) {
    const top = document.createElement("div"); top.className = "top"; top.innerHTML = '<span class="back">미리보기 화면</span><span class="property"></span>'; top.querySelector(".property").textContent = state.property.name || ""; host.append(top);
    const hero = document.createElement("section"); hero.className = "hero"; hero.innerHTML = '<h1></h1><p>보고 결과 화면 예시</p><div class="clock"></div>';
    hero.querySelector("h1").textContent = typeLabel + " 결과"; hero.querySelector(".clock").textContent = (state.employeeName || "근무자") + " · 예시 제출 08:58"; host.append(hero);
    const result = document.createElement("section"); result.className = "preview-result-card";
    const rows = fields.map(field => '<div class="report-value-row"><strong>' + esc(field.label) + '</strong><div>' + (field.kind === 'rooms' ? window.OMSHousingRooms.result(sampleValue(field), window.OMSHousingRooms.housesFor(roomTypes)) : esc(sampleValue(field))) + '</div></div>').join("");
    result.innerHTML = '<div class="preview-result-head"><b>' + esc(typeLabel) + '</b><span>예시 결과</span></div>' + (rows || '<p class="empty">표시할 보고 항목이 없습니다.</p>');
    if ((reportConfig[state.reportType] || []).includes("reminder_cards")) result.innerHTML += '<div class="report-value-row"><strong>리마인더 확인</strong><div>' + allCards.filter(card => (card.report_weekdays?.[state.reportType] || card.weekdays || [0,1,2,3,4,5,6]).includes(weekday)).length + '개</div></div>';
    result.innerHTML += '<div class="report-value-row"><strong>특이사항</strong><div>' + esc(submittedMemo === null ? "예시 메모" : submittedMemo || "없음") + '</div></div>'; host.append(result);
  }
  function render() {
    $("previewTitle").textContent = typeLabel + (screen === "input" ? " 입력 예시" : " 결과 예시");
    $("previewDays").querySelectorAll("[data-day]").forEach(button => button.setAttribute("aria-pressed", String(Number(button.dataset.day) === weekday)));
    document.querySelectorAll("[data-screen]").forEach(button => button.setAttribute("aria-current", String(button.dataset.screen === screen)));
    const host = $("workerPreview"); host.replaceChildren(); host.className = "container";
    if (screen === "input") renderInput(host); else renderResult(host);
  }
  render();
})();
