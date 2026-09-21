// Browser workflow tests with a real DOM and mocked RPC/server-delivery transports.
// No live API or webhook requests are made.
const { JSDOM } = require('jsdom');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'report-session.js'), 'utf8');
const client = fs.readFileSync(path.join(root, 'supabase-client.js'), 'utf8');
let checks = 0;
function check(value, message) { assert.ok(value, message); checks++; }
const session = {
  accessToken: '10000000-0000-4000-8000-000000000001',
  employeeId: '20000000-0000-4000-8000-000000000001',
  employeeName: '테스트 직원', role: 'staff', sessionKind: 'staff', shift: 'morning', timezone: 'Asia/Seoul',
  clockInAt: '2026-09-16T00:02:00Z', status: 'working'
};
function browser(reportType, state = {}) {
  state.events ||= []; state.postCount ||= 0; state.saveCount ||= 0; state.updateCount ||= 0;
  const fixture = `<!doctype html><body>
    <main id="formPage"><select id="worker"></select></main>
    <section id="donePage" style="display:none"></section>
  </body>`;
  const dom = new JSDOM(fixture, {
    url: 'https://staff.example.test/report.html?type=' + reportType, runScripts: 'outside-only'
  });
  const w = dom.window;
  w.scrollTo = () => {};
  w.omgConfirmReportEdit = () => state.confirmEdit ?? true;
  w.AbortController = global.AbortController;
  w.OMG_SUPABASE = { url: 'https://db.example.test', publishableKey: 'test-only' };
  w.omgSession = {
    require: async () => ({ ...session, ...state.session }),
    logout: async () => { state.events.push('logout'); state.loggedOut = true; }
  };
  w.omgSupabase = { rpc: async (name, args) => {
    state.events.push(name);
    if (state.expired) return { data: { ok: false, code: 'invalid_session', message: '다시 로그인해주세요.' } };
    if (name === 'get_work_report') return { data: state.saved ? structuredClone(state.saved) : { ok: false, code: 'not_found' } };
    if (name === 'save_work_report') {
      if (state.failSave) return { error: { message: 'simulated offline' } };
      state.saveCount++;
      state.saved ||= { ok: true, report_id: '30000000-0000-4000-8000-000000000001',
        make_accepted: false, payload: { ...args.p_payload, worker: '테스트 직원', report_id: '30000000-0000-4000-8000-000000000001' } };
      return { data: structuredClone(state.saved) };
    }
    if (name === 'update_work_report') {
      state.updateCount++;
      state.saved = { ...state.saved, make_accepted: false, payload: { ...args.p_payload, worker: '테스트 직원', report_id: state.saved.report_id } };
      return { data: structuredClone(state.saved) };
    }
    throw new Error('Unexpected RPC: ' + name);
  }};
  w.fetch = async (url, args) => {
    assert.equal(url, 'https://db.example.test/functions/v1/deliver-report', 'only mocked server relay allowed');
    assert.equal(args.headers.Authorization, 'Bearer test-only', 'relay uses project publishable key');
    state.events.push('relay'); state.postCount++;
    state.lastPayload = JSON.parse(args.body);
    if (state.failPost) { state.failPost = false; return { ok: false, json: async () => ({ ok: false }) }; }
    state.saved.make_accepted = true;
    return { ok: true, json: async () => ({ ok: true }) };
  };
  w.eval(source);
  return { dom, w, state };
}
async function run() {
  // Parse every changed inline script as JavaScript; don't execute legacy UI code.
  for (const file of ['account.html', 'app.html', 'index.html', 'login.html', 'owner-login.html', 'platform-admin.html', 'report.html', 'owner-settings.html', 'staff-management.html', 'attendance.html', 'mission.html', 'emergency.html', 'owner-inbox.html', 'morning1.html', 'morning2.html', 'afternoon1.html', 'afternoon2.html']) {
    const dom = new JSDOM(fs.readFileSync(path.join(root, file), 'utf8'));
    for (const script of dom.window.document.querySelectorAll('script:not([src])')) new vm.Script(script.textContent, { filename: file });
    dom.window.close();
    check(true, file + ' script syntax');
  }
  const loginHtml = fs.readFileSync(path.join(root, 'login.html'), 'utf8');
  check(!loginHtml.includes('id="propertyTitle">게하워크') && loginHtml.includes('id="propertyTitle" class="loading"'), 'PIN login does not flash a hard-coded property name');
  check(loginHtml.includes('window.omgSession.get()') && loginHtml.includes('window.omgSession.require()') && loginHtml.includes('location.replace("app.html")'), 'PIN login automatically resumes an active work session');
  check(!loginHtml.includes('name="shift"') && !loginHtml.includes('근무 구분'), 'login has no morning/afternoon choice');
  check(loginHtml.includes('id="staffTab"') && loginHtml.includes('id="adminTab"') && loginHtml.includes('>관리자</button>'), 'one PIN page provides staff and administrator roles');
  check(loginHtml.indexOf('id="staffTab"') < loginHtml.indexOf('id="adminTab"'), 'staff is the default first login role');
  check(loginHtml.includes('get_or_create_account_property') && loginHtml.includes('list_account_login_employees') && loginHtml.includes('start_account_admin_session'), 'PIN login is scoped to the authenticated property account');
  check(loginHtml.includes('id="welcomeModal"') && loginHtml.includes('임시 관리자 PIN') && loginHtml.includes('1234'), 'new accounts receive a designed temporary administrator PIN dialog');
  check(loginHtml.includes('source.length===1') && loginHtml.includes('accountSelect.value=source[0].owner_id'), 'a single administrator is shown once and selected automatically');
  const indexHtml = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  check(indexHtml.includes('omg_work_session') && indexHtml.includes('target="app.html"') && indexHtml.includes('target="account.html"') && !indexHtml.includes('오전 근무자') && !indexHtml.includes('오후 근무자'), 'root resumes a persisted work session before account login');
  const accountHtml = fs.readFileSync(path.join(root, 'account.html'), 'utf8');
  check(accountHtml.includes('계정 로그인') && accountHtml.includes('가입') && accountHtml.includes('signUp') && accountHtml.includes('signInWithPassword'), 'account screen supports email login and signup');
  check(accountHtml.includes('id="accountShell" class="shell"') && accountHtml.includes('.shell.ready{visibility:visible') && accountHtml.includes('accountShell").classList.add("ready")'), 'account screen stays hidden while an existing account session redirects');
  const androidActivity = fs.readFileSync(path.join(root, 'guesthouse-manager-app/app/src/main/java/com/oneminute/guesthousemanager/AttendanceActivity.java'), 'utf8');
  check(androidActivity.includes('moveTaskToBack(true)') && !androidActivity.includes('else super.onBackPressed()'), 'Android back at the dashboard backgrounds the app instead of closing the activity');
  check(androidActivity.includes('WebSettings.LOAD_NO_CACHE') && androidActivity.includes('webView.restoreState(state)') && androidActivity.includes('webView.saveState(outState)'), 'Android WebView avoids stale startup pages and preserves navigation state');
  const appHtml = fs.readFileSync(path.join(root, 'app.html'), 'utf8');
  check(!appHtml.includes('id="propertyTitle">One Minute') && appHtml.includes('id="propertyTitle" class="loading"'), 'dashboard does not flash a hard-coded property name');
  check(appHtml.includes('id="appShell" class="shell"') && appHtml.includes('.shell.ready{visibility:visible') && appHtml.includes('appShell").classList.add("ready")'), 'dashboard stays hidden until session, role, and property data are ready');
  check(appHtml.includes('href="mission.html"'), 'main menu opens web mission page');
  check(appHtml.includes('report.html?type=clock_in') && appHtml.includes('report.html?type=clock_out'), 'main menu has direct side-by-side check-in and check-out buttons');
  check(appHtml.includes('shiba-face-morning-in.png') && appHtml.includes('shiba-face-morning-out-slim.png'), 'report buttons show bright and subtly slimmer tired dog faces');
  check(appHtml.includes('id="secondaryMenu"') && appHtml.includes('id="todayMissionCount"') && appHtml.includes('당일미션'), 'urgent report and mission share a row with a today counter');
  check(appHtml.includes('사장님<br>긴급보고') && appHtml.includes('class="quick-visual"'), 'urgent report uses large two-line text with the siren on the right');
  check(!appHtml.includes('<span class="icon">✓</span>') && appHtml.includes('<span class="copy"><b>미션</b>'), 'mission button removes the leading check icon');
  check(!appHtml.includes('id="noticeCard"') && !appHtml.includes('id="noticeText"'), 'main screen omits the retired property announcement');
  check(appHtml.includes('href="emergency.html"') && appHtml.includes('href="owner-inbox.html"'), 'urgent report and owner inbox use Supabase web pages');
  check(appHtml.includes('class="owner-grid"') && appHtml.includes('href="staff-management.html"') && appHtml.includes('>계정관리<'), 'owner property settings and account management share a row');
  check(appHtml.includes('id="owner-inbox" class="card quick-card"') && appHtml.includes('id="missionMenu" class="card quick-card"'), 'owner inbox and mission share a row');
  check(appHtml.includes('>메세지함<') && appHtml.includes('id="attendanceManagement"') && appHtml.includes('>근무시간 관리<'), 'owner dashboard includes message and work-time management menus');
  check(appHtml.includes('data-icon="users-round"'), 'account management uses the selected people line icon');
  check(appHtml.includes('data-icon="chart-no-axes-combined"'), 'work-time management uses the selected combined chart icon');
  check(appHtml.includes('data-icon="building-2"') && appHtml.includes('<b>Property</b>'), 'property menu uses the selected building icon and short label');
  check(appHtml.includes('data-icon="message-square-text"'), 'message inbox uses the selected conversation icon');
  check(appHtml.includes('id="staffWorkStatus"') && appHtml.includes('<b>근무현황</b>') && appHtml.includes('staffWorkStatus").style.display = isOwner ? "none" : "flex"'), 'staff main menu includes a half-width self attendance card');
  check(appHtml.includes('id="platformAdmin"') && appHtml.includes('href="platform-admin.html"') && appHtml.includes('is_platform_administrator'), 'founder owner menu reveals the separate platform operator center');
  check(appHtml.indexOf('id="attendanceManagement"') < appHtml.indexOf('id="platformAdmin"') && !appHtml.includes('.attendance-card{grid-column:1/-1'), 'work-time management and operator center share one half-width row');
  check(appHtml.includes('<b>OMG WORKS</b>') && !appHtml.includes('OMG WORKS<br>운영자 센터'), 'operator center uses the compact OMG WORKS title');
  check(appHtml.includes('page-transition.css') && appHtml.includes('window.omgTransition.ready()'), 'dashboard waits for complete data before revealing the branded transition');
  check(appHtml.includes('isOwner?(Number(item.target_count)') && appHtml.includes('todayMissionCount'), 'owner mission menu receives the today counter');
  const reportHtml = fs.readFileSync(path.join(root, 'report.html'), 'utf8');
  check(reportHtml.includes('data-omg-ready="manual"') && reportHtml.includes('window.omgTransition.ready()'), 'report page hides default labels until the complete report is ready');
  check(reportHtml.indexOf('memo-card') < reportHtml.indexOf('id="reminderSlot"') && reportHtml.indexOf('id="reminderSlot"') < reportHtml.indexOf('id="submitButton"'), 'reminder cards appear immediately above submit');
  const workConfigHtml = fs.readFileSync(path.join(root, 'work-config.js'), 'utf8');
  check(reportHtml.includes('createStepper') && reportHtml.includes('수량 줄이기') && reportHtml.includes('수량 늘리기'), 'no-show and bedding stain quantities use minus and plus steppers');
  check(workConfigHtml.includes('kind: "room_count"') && reportHtml.includes('expand-rooms'), 'no-show quantity expands room selection');
  check(reportHtml.includes('.room-group{display:grid;grid-template-columns:76px minmax(0,1fr)') && reportHtml.includes('grid-template-columns:repeat(5,minmax(0,1fr))'), 'room type stays left while up to five room numbers fit on the right');
  check(source.includes('role", "dialog"') && source.includes('수정하기'), 'existing report uses a custom edit dialog');
  const missionHtml = fs.readFileSync(path.join(root, 'mission.html'), 'utf8');
  check(['지연','당일','금주','아무때나','완료'].every(label => missionHtml.includes(`>${label}<`)), 'mission dashboard restores all mature categories');
  check(missionHtml.includes('happy-clapping-shiba.js') && missionHtml.includes('미션 클리어'), 'mission completion restores the dog celebration');
  check(missionHtml.includes('new Option("All",""') && !missionHtml.includes('workerFilter.disabled=true'), 'mission worker filter is clickable and includes All');
  check(missionHtml.includes('id="priorityStar"') && !missionHtml.includes('예상 시간(분)') && missionHtml.includes('creator_name'), 'mission editor uses a star toggle, omits estimated time, and shows creator');
  check(missionHtml.includes('document.getElementById("newMission").hidden=false'), 'staff and owner both receive the new mission button');
  check(missionHtml.includes('aria-label="미션 추가"') && !missionHtml.includes('+ 새 미션'), 'mission title has a compact plus-only add button');
  check(missionHtml.includes('id="descriptionPhotoInput"') && missionHtml.includes('description_photo'), 'mission details support a reference photo');
  check(missionHtml.includes('<span>중요</span>') && missionHtml.includes('완료 사진 필수') && !missionHtml.includes('완료 사진을 반드시 받기'), 'mission editor uses compact photo and star controls');
  check(missionHtml.includes('id="creatorDisplay"') && missionHtml.includes('class="editor-grid"') && missionHtml.includes('for="dueAt">마감일') && missionHtml.includes('id="dueAt" type="date"') && !missionHtml.includes('datetime-local'), 'mission editor places creator by timing and uses a date-only deadline');
  check(missionHtml.includes('class="mission-row"') && missionHtml.includes('class="mission-preview-row"') && missionHtml.includes('photo-indicator'), 'mission list uses compact summary rows with a photo indicator');
  const ownerSettingsHtml = fs.readFileSync(path.join(root, 'owner-settings.html'), 'utf8');
  const staffManagementHtml = fs.readFileSync(path.join(root, 'staff-management.html'), 'utf8');
  check(!ownerSettingsHtml.includes('id="accounts"') && staffManagementHtml.includes('delete-account') && staffManagementHtml.includes('>Delete</button>'), 'worker account controls moved from property settings to staff management');
  check(staffManagementHtml.includes('id="adminAccounts"') && staffManagementHtml.includes('saveAdministrators'), 'staff management creates and updates administrator accounts');
  check(staffManagementHtml.includes('<h1>계정관리</h1>') && staffManagementHtml.includes('PIN을 변경'), 'account management edits the default administrator name and PIN');
  const attendanceHtml = fs.readFileSync(path.join(root, 'attendance.html'), 'utf8');
  check(['data-period="day"','data-period="month"','data-period="custom"'].every(token => attendanceHtml.includes(token)) && !attendanceHtml.includes('data-period="week"'), 'attendance management provides day, month, and custom range views');
  check(attendanceHtml.includes('list_attendance_statistics') && attendanceHtml.includes('class="sheet"') && attendanceHtml.includes('근무시간 현황'), 'attendance page combines visual totals with an Excel-style table');
  check(attendanceHtml.includes('date.setDate(1);anchor.value=isoDate(date)') && attendanceHtml.includes('id="rangeStart"') && attendanceHtml.includes('id="rangeEnd"'), 'monthly dates are forced to day one and custom range has start and end inputs');
  check(attendanceHtml.indexOf('<th>근무시간</th>') < attendanceHtml.indexOf('<th>출근</th>') && attendanceHtml.includes('class="duration-cell"'), 'attendance table prioritizes work duration before clock-in and clock-out');
  check(attendanceHtml.includes('filterRow.hidden=true') && attendanceHtml.includes('session.employeeId'), 'staff attendance view hides the worker filter and selects the signed-in worker');
  check(ownerSettingsHtml.includes('id="managementNumber"') && ownerSettingsHtml.includes('readonly'), 'property settings show an operator-only management number');
  check(ownerSettingsHtml.includes('<h2>Property 기본정보</h2>') && !ownerSettingsHtml.includes('숙소명은 로그인과 메인화면'), 'property settings use the requested heading without the retired explanation');
  check(ownerSettingsHtml.includes('>Property ID</label>') && ownerSettingsHtml.includes('property-id-title') && !ownerSettingsHtml.includes('OMG WORKS 운영자만 변경 가능'), 'property ID stays on one line without the operator note');
  check(['value="lodging"','value="general"','value="other"'].every(token => ownerSettingsHtml.includes(token)) && ownerSettingsHtml.includes('id="lodgingFields" hidden'), 'property type choices control the lodging-only room editor');
  check(ownerSettingsHtml.includes('<div class="custom-field-row"><input id="customFieldName"') && ownerSettingsHtml.includes('addCustomField') && ownerSettingsHtml.includes('custom-delete'), 'all property types show custom report input inside the report panel');
  check(workConfigHtml.includes('fieldsFor(property)') && reportHtml.includes('fieldsFor(pageConfig.property)') && reportHtml.includes('field.kind==="text"'), 'custom fields flow into the staff report form as text inputs');
  const platformAdminHtml = fs.readFileSync(path.join(root, 'platform-admin.html'), 'utf8');
  check(platformAdminHtml.includes('get_platform_dashboard') && platformAdminHtml.includes('update_platform_property') && platformAdminHtml.includes('reset_platform_property_admin_pin'), 'platform operator center lists tenants, controls status, and resets administrator PINs');
  check(platformAdminHtml.includes('전체 숙소') && platformAdminHtml.includes('현재 근무 중') && platformAdminHtml.includes('최근 운영 기록'), 'platform operator center shows service and usage summaries');
  check(!ownerSettingsHtml.includes('id="propertyNotice"') && !ownerSettingsHtml.includes('saveNotice'), 'property settings omit the retired announcement field');
  check(ownerSettingsHtml.includes('class="report-tabs"') && ownerSettingsHtml.includes('data-report="clock_in"') && ownerSettingsHtml.includes('data-report="clock_out"'), 'report settings use side-by-side check-in and check-out tabs');
  check(!ownerSettingsHtml.includes('class="employee-head"') && !ownerSettingsHtml.includes('class="report-enabled"'), 'report settings remove duplicate employee identity and reminder enable checkboxes');
  check(workConfigHtml.includes('clock_in: reportFields') && workConfigHtml.includes('clock_out: reportFields'), 'check-in and check-out settings share the same report field choices');
  check(ownerSettingsHtml.includes('${label} 리마인더') && ownerSettingsHtml.includes('report_types') && ownerSettingsHtml.includes('report_weekdays'), 'each report tab manages its own reminder cards and weekdays');
  check(workConfigHtml.includes('report_types: ["clock_in"]') && workConfigHtml.includes('report_weekdays') && reportHtml.includes('.includes(reportType)'), 'reminder cards are filtered for the selected report type and its weekday schedule');
  new vm.Script(fs.readFileSync(path.join(root, 'work-config.js'), 'utf8'), { filename: 'work-config.js' });
  check(true, 'work config script syntax');
  let b = browser('clock_in');
  await b.w.omgReport.ready;
  check(b.w.document.getElementById('worker').value === session.employeeName && b.w.document.getElementById('worker').disabled, 'worker comes from verified session');
  check(b.w.omgReport.getCheckinTimeDiff('09:00') === 2, 'lateness uses login time in property timezone');
  check(!b.w.document.getElementById('formPage').inert, 'form enabled after verification');
  const first = b.w.omgReport.submit({ memo: 'submitted once' });
  const second = b.w.omgReport.submit({ memo: 'double tap' });
  check(first === second, 'double tap shares one submission');
  await first;
  check(b.state.saveCount === 1 && b.state.postCount === 1, 'one save and one delivery');
  check(b.state.events.indexOf('save_work_report') < b.state.events.indexOf('relay'), 'database saves before server delivery');
  check(b.w.document.getElementById('donePage').style.display === 'block', 'success page shown');
  b.dom.window.close();

  b = browser('clock_in', { failSave: true });
  await b.w.omgReport.ready;
  await assert.rejects(() => b.w.omgReport.submit({ memo: 'offline' }));
  check(b.state.postCount === 0, 'database failure never calls delivery relay');
  check(!b.w.document.getElementById('formPage').inert, 'unsaved form stays editable');
  b.dom.window.close();

  b = browser('clock_out', { failPost: true });
  await b.w.omgReport.ready;
  await assert.rejects(() => b.w.omgReport.submit({ memo: 'original report' }));
  check(!b.state.loggedOut && b.w.document.getElementById('formPage').inert, 'failed delivery retains session and locks saved contents');
  check(b.w.document.querySelector('[role="status"] button'), 'retry control available');
  await b.w.omgReport.submit({ memo: 'should not overwrite saved report' });
  check(b.state.saveCount === 1 && b.state.postCount === 2 && b.state.saved.payload.memo === 'original report', 'delivery retry uses original stored report');
  check(b.state.loggedOut && b.state.events.at(-1) === 'logout', 'checkout logs out only after acknowledgement');
  b.dom.window.close();

  const pending = { saved: { ok: true, report_id: 'test-pending', make_accepted: false, payload: { memo: 'pending' } } };
  b = browser('clock_in', pending);
  await b.w.omgReport.ready;
  pending.expired = true;
  await assert.rejects(() => b.w.omgReport.submit(null));
  check(pending.postCount === 0, 'cached report cannot be delivered after token is invalidated');
  b.dom.window.close();

  // Use the actual client to ensure localStorage roles/times aren't trusted.
  const dom = new JSDOM('<main></main>', { url: 'https://staff.example.test/app.html', runScripts: 'outside-only' });
  const w = dom.window;
  let logoutCalls = 0;
  w.OMG_SUPABASE = { url: 'https://db.example.test', publishableKey: 'test-only' };
  w.supabase = { createClient: () => ({ rpc: async name => {
    if (name === 'end_app_session') { logoutCalls++; return { data: { ok: true } }; }
    return { data: { ok: true, employee_id: session.employeeId, employee_name: session.employeeName,
      session_id: 'test-session', role: 'staff', session_kind: 'staff', status: 'working', shift: 'morning', clock_in_at: session.clockInAt } };
  } }) };
  w.eval(client);
  w.omgSession.set({ accessToken: session.accessToken, role: 'owner', sessionKind: 'owner', clockInAt: 'forged' });
  const verified = await w.omgSession.require();
  check(verified.role === 'staff' && verified.sessionKind === 'staff' && verified.clockInAt === session.clockInAt, 'server overrides forged local role, session kind, and timestamp');
  await w.omgSession.logout();
  check(logoutCalls === 1 && w.omgSession.get() === null, 'logout reaches server and clears local session');
  dom.window.close();
  console.log(`PASS: ${checks} browser workflow checks (mock transports; no live requests).`);
}
run().catch(error => { console.error(error.stack); process.exitCode = 1; });
