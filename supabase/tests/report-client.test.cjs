// Browser workflow tests with a real DOM and mocked RPC/Make transports.
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
  employeeName: '테스트 직원', shift: 'morning', timezone: 'Asia/Seoul',
  clockInAt: '2026-09-16T00:02:00Z', status: 'working'
};
function browser(file, state = {}) {
  state.events ||= []; state.postCount ||= 0; state.saveCount ||= 0;
  const dom = new JSDOM(fs.readFileSync(path.join(root, file), 'utf8'), {
    url: 'https://staff.example.test/' + file, runScripts: 'outside-only'
  });
  const w = dom.window;
  w.scrollTo = () => {};
  w.AbortController = global.AbortController;
  w.webhookUrl = 'https://make.example.test/report';
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
    if (name === 'mark_report_delivered') {
      if (state.failAck) { state.failAck = false; return { error: { message: 'simulated ack failure' } }; }
      state.saved.make_accepted = true;
      return { data: { ok: true } };
    }
    throw new Error('Unexpected RPC: ' + name);
  }};
  w.fetch = async (url, args) => {
    assert.equal(url, w.webhookUrl, 'only mocked webhook allowed');
    state.events.push('make'); state.postCount++;
    state.lastPayload = JSON.parse(args.body);
    if (state.failPost) { state.failPost = false; return { ok: false }; }
    return { ok: true };
  };
  w.eval(source);
  return { dom, w, state };
}
async function run() {
  // Parse every changed inline script as JavaScript; don't execute legacy UI code.
  for (const file of ['app.html', 'index.html', 'login.html', 'morning1.html', 'morning2.html', 'afternoon1.html', 'afternoon2.html']) {
    const dom = new JSDOM(fs.readFileSync(path.join(root, file), 'utf8'));
    for (const script of dom.window.document.querySelectorAll('script:not([src])')) new vm.Script(script.textContent, { filename: file });
    dom.window.close();
    check(true, file + ' script syntax');
  }
  let b = browser('morning1.html');
  await b.w.omgReport.ready;
  check(b.w.document.getElementById('worker').value === session.employeeName && b.w.document.getElementById('worker').disabled, 'worker comes from verified session');
  check(b.w.omgReport.getCheckinTimeDiff('09:00') === 2, 'lateness uses login time in property timezone');
  check(!b.w.document.getElementById('formPage').inert, 'form enabled after verification');
  const first = b.w.omgReport.submit({ memo: 'submitted once' });
  const second = b.w.omgReport.submit({ memo: 'double tap' });
  check(first === second, 'double tap shares one submission');
  await first;
  check(b.state.saveCount === 1 && b.state.postCount === 1, 'one save and one delivery');
  check(b.state.events.indexOf('save_work_report') < b.state.events.indexOf('make'), 'database saves before webhook');
  check(b.w.document.getElementById('donePage').style.display === 'block', 'success page shown');
  b.dom.window.close();

  b = browser('morning1.html', { failSave: true });
  await b.w.omgReport.ready;
  await assert.rejects(() => b.w.omgReport.submit({ memo: 'offline' }));
  check(b.state.postCount === 0, 'database failure never sends to Make');
  check(!b.w.document.getElementById('formPage').inert, 'unsaved form stays editable');
  b.dom.window.close();

  b = browser('morning2.html', { failPost: true });
  await b.w.omgReport.ready;
  await assert.rejects(() => b.w.omgReport.submit({ memo: 'original report' }));
  check(!b.state.loggedOut && b.w.document.getElementById('formPage').inert, 'failed delivery retains session and locks saved contents');
  check(b.w.document.querySelector('[role="status"] button'), 'retry control available');
  await b.w.omgReport.submit({ memo: 'should not overwrite saved report' });
  check(b.state.saveCount === 1 && b.state.postCount === 2 && b.state.lastPayload.memo === 'original report', 'delivery retry uses original stored report');
  check(b.state.loggedOut && b.state.events.at(-1) === 'logout', 'checkout logs out only after acknowledgement');
  b.dom.window.close();

  const ackState = { failAck: true };
  b = browser('morning2.html', ackState);
  await b.w.omgReport.ready;
  await assert.rejects(() => b.w.omgReport.submit({ memo: 'accepted by Make' }));
  const receipt = b.w.localStorage.getItem('omg_make_accepted_' + ackState.saved.report_id);
  check(receipt === 'true' && !ackState.loggedOut, 'HTTP success retained if acknowledgement fails');
  b.dom.window.close();
  b = browser('morning2.html', ackState);
  b.w.localStorage.setItem('omg_make_accepted_' + ackState.saved.report_id, receipt);
  await b.w.omgReport.ready;
  check(b.w.document.querySelector('[role="status"] button'), 'reload restores saved-report retry');
  await b.w.omgReport.submit(null);
  check(ackState.postCount === 1 && ackState.loggedOut, 'acknowledgement retry after reload does not repost');
  b.dom.window.close();

  const pending = { saved: { ok: true, report_id: 'test-pending', make_accepted: false, payload: { memo: 'pending' } } };
  b = browser('morning1.html', pending);
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
    if (name === 'end_device_session') { logoutCalls++; return { data: { ok: true } }; }
    return { data: { ok: true, employee_id: session.employeeId, employee_name: session.employeeName,
      session_id: 'test-session', role: 'staff', status: 'working', shift: 'morning', clock_in_at: session.clockInAt } };
  } }) };
  w.eval(client);
  w.omgSession.set({ accessToken: session.accessToken, role: 'owner', clockInAt: 'forged' });
  const verified = await w.omgSession.require();
  check(verified.role === 'staff' && verified.clockInAt === session.clockInAt, 'server overrides forged local role and timestamp');
  await w.omgSession.logout();
  check(logoutCalls === 1 && w.omgSession.get() === null, 'logout reaches server and clears local session');
  dom.window.close();
  console.log(`PASS: ${checks} browser workflow checks (mock transports; no live requests).`);
}
run().catch(error => { console.error(error.stack); process.exitCode = 1; });
