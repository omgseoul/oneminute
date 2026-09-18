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
  for (const file of ['account.html', 'app.html', 'index.html', 'login.html', 'owner-login.html', 'report.html', 'owner-settings.html', 'staff-management.html', 'mission.html', 'emergency.html', 'owner-inbox.html', 'morning1.html', 'morning2.html', 'afternoon1.html', 'afternoon2.html']) {
    const dom = new JSDOM(fs.readFileSync(path.join(root, file), 'utf8'));
    for (const script of dom.window.document.querySelectorAll('script:not([src])')) new vm.Script(script.textContent, { filename: file });
    dom.window.close();
    check(true, file + ' script syntax');
  }
  const loginHtml = fs.readFileSync(path.join(root, 'login.html'), 'utf8');
  check(!loginHtml.includes('name="shift"') && !loginHtml.includes('근무 구분'), 'login has no morning/afternoon choice');
  check(loginHtml.includes('id="staffTab"') && loginHtml.includes('id="adminTab"') && loginHtml.includes('>관리자</button>'), 'one PIN page provides staff and administrator roles');
  check(loginHtml.indexOf('id="staffTab"') < loginHtml.indexOf('id="adminTab"'), 'staff is the default first login role');
  const indexHtml = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  check(indexHtml.includes('account.html') && !indexHtml.includes('오전 근무자') && !indexHtml.includes('오후 근무자'), 'root starts at account login and has no shift sections');
  const accountHtml = fs.readFileSync(path.join(root, 'account.html'), 'utf8');
  check(accountHtml.includes('계정 로그인') && accountHtml.includes('가입') && accountHtml.includes('signUp') && accountHtml.includes('signInWithPassword'), 'account screen supports email login and signup');
  const appHtml = fs.readFileSync(path.join(root, 'app.html'), 'utf8');
  check(appHtml.includes('href="mission.html"'), 'main menu opens web mission page');
  check(appHtml.includes('report.html?type=clock_in') && appHtml.includes('report.html?type=clock_out'), 'main menu has direct side-by-side check-in and check-out buttons');
  check(appHtml.includes('shiba-face-morning-in.png') && appHtml.includes('shiba-face-morning-out.png'), 'report buttons show bright and tired dog faces');
  check(appHtml.includes('id="secondaryMenu"') && appHtml.includes('id="todayMissionCount"') && appHtml.includes('당일미션'), 'urgent report and mission share a row with a today counter');
  check(appHtml.includes('사장님<br>긴급보고') && appHtml.includes('class="quick-visual"'), 'urgent report uses large two-line text with the siren on the right');
  check(!appHtml.includes('<span class="icon">✓</span>') && appHtml.includes('<span class="copy"><b>미션</b>'), 'mission button removes the leading check icon');
  check(appHtml.includes('id="noticeCard"') && appHtml.includes('공지사항'), 'staff main screen includes property announcement');
  check(appHtml.includes('class="notice-section empty"') && appHtml.includes('class="notice-line"') && !appHtml.includes('class="card notice-card'), 'announcement is rendered as a plain titled section');
  check(appHtml.includes('href="emergency.html"') && appHtml.includes('href="owner-inbox.html"'), 'urgent report and owner inbox use Supabase web pages');
  check(appHtml.includes('class="owner-grid"') && appHtml.includes('href="staff-management.html"') && appHtml.includes('>직원관리<'), 'owner property settings and staff management share a row');
  check(appHtml.includes('id="owner-inbox" class="card quick-card"') && appHtml.includes('id="missionMenu" class="card quick-card"'), 'owner inbox and mission share a row');
  check(appHtml.includes('isOwner?(Number(item.target_count)') && appHtml.includes('todayMissionCount'), 'owner mission menu receives the today counter');
  const reportHtml = fs.readFileSync(path.join(root, 'report.html'), 'utf8');
  check(reportHtml.indexOf('memo-card') < reportHtml.indexOf('id="reminderSlot"') && reportHtml.indexOf('id="reminderSlot"') < reportHtml.indexOf('id="submitButton"'), 'reminder cards appear immediately above submit');
  const workConfigHtml = fs.readFileSync(path.join(root, 'work-config.js'), 'utf8');
  check(reportHtml.includes('createStepper') && reportHtml.includes('수량 줄이기') && reportHtml.includes('수량 늘리기'), 'no-show and bedding stain quantities use minus and plus steppers');
  check(workConfigHtml.includes('kind: "room_count"') && reportHtml.includes('expand-rooms'), 'no-show quantity expands room selection');
  check(reportHtml.includes('grid-template-columns:repeat(6,minmax(0,1fr))'), 'up to six room numbers fit on one row');
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
  check(missionHtml.includes('id="creatorDisplay"') && missionHtml.includes('class="editor-grid"') && missionHtml.includes('for="dueAt">마감일시'), 'mission editor places creator by timing and deadline below');
  check(missionHtml.includes('class="mission-row"') && missionHtml.includes('class="mission-preview-row"') && missionHtml.includes('photo-indicator'), 'mission list uses compact summary rows with a photo indicator');
  const ownerSettingsHtml = fs.readFileSync(path.join(root, 'owner-settings.html'), 'utf8');
  const staffManagementHtml = fs.readFileSync(path.join(root, 'staff-management.html'), 'utf8');
  check(!ownerSettingsHtml.includes('id="accounts"') && staffManagementHtml.includes('delete-account') && staffManagementHtml.includes('>Delete</button>'), 'worker account controls moved from property settings to staff management');
  check(staffManagementHtml.includes('id="adminAccounts"') && staffManagementHtml.includes('saveAdministrators'), 'staff management creates and updates administrator accounts');
  check(ownerSettingsHtml.includes('id="managementNumber"') && ownerSettingsHtml.includes('readonly'), 'property settings show an operator-only management number');
  check(ownerSettingsHtml.includes('id="propertyNotice"') && ownerSettingsHtml.includes('saveNotice'), 'property settings save an announcement');
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
