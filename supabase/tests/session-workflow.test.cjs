// Local in-memory PostgreSQL only. No network, live accounts, or Make calls.
// npm install --no-save @electric-sql/pglite@0.5.8
// NODE_PATH=/path/to/node_modules node supabase/tests/session-workflow.test.cjs
const { PGlite } = require('@electric-sql/pglite');
const { pgcrypto } = require('@electric-sql/pglite/contrib/pgcrypto');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');

const root = path.join(__dirname, '..');
const foundation = fs.readFileSync(path.join(root, 'migrations/001_initial_schema.sql'), 'utf8');
const functions = fs.readFileSync(path.join(root, 'migrations/003_staff_sessions.sql'), 'utf8');
const pinTemplate = fs.readFileSync(path.join(root, 'setup/002_register_employee_pins.example.sql'), 'utf8');
const testPins = ['731482', '628951', '849263', '953728']; // Synthetic test data only.
const pinSetup = pinTemplate.replace(/PIN_([1-4])/g, (_, i) => testPins[Number(i) - 1]);
const db = new PGlite({ extensions: { pgcrypto } });
let checks = 0;
function check(value, label) { assert.ok(value, label); checks++; }
async function rows(sql, params = []) { return (await db.query(sql, params)).rows; }
async function one(sql, params = []) { return (await rows(sql, params))[0]; }
async function asAnon(fn) {
  await db.exec('set role anon');
  try { return await fn(); } finally { await db.exec('reset role'); }
}
async function rpc(name, args) {
  const placeholders = args.map((_, i) => '$' + (i + 1)).join(',');
  return asAnon(async () => (await one(`select public.${name}(${placeholders}) as result`, args)).result);
}
async function forbidden(fn, label, code = '42501') {
  let error;
  try { await fn(); } catch (caught) { error = caught; }
  check(error && error.code === code, label);
}
async function run() {
  await db.exec(`create role anon; create role authenticated;
    grant usage on schema public to anon, authenticated;
    alter default privileges in schema public grant all on tables to anon, authenticated;`);
  await db.exec(foundation);
  await db.exec(foundation);
  check(Number((await one('select count(*) as n from public.employees')).n) === 4, 'repeated setup preserves four staff');
  const tableChecks = await rows(`select c.relname, c.relrowsecurity,
    has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE') as anon_access,
    has_table_privilege('authenticated', c.oid, 'SELECT,INSERT,UPDATE,DELETE') as user_access
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'`);
  check(tableChecks.length === 5 && tableChecks.every(x => x.relrowsecurity && !x.anon_access && !x.user_access), 'RLS and privileges close all five tables');
  await db.exec(pinSetup);
  check((await rows('select pin_hash from public.employees')).every(x => x.pin_hash.startsWith('$2a$10$')), 'PIN template installs bcrypt cost 10');
  await db.exec(functions);
  const setupAgain = await db.exec(functions);
  check(setupAgain.at(-1).rows.length === 7 && setupAgain.at(-1).rows.every(x => x.access_locked), 'all seven RPCs are closed, including after rerun');
  await forbidden(() => asAnon(() => db.query('select * from public.employees')), 'anonymous table reads denied');
  await forbidden(() => asAnon(() => db.query('select * from public.list_login_employees()')), 'anonymous login list denied before activation');
  await forbidden(() => asAnon(() => db.query('select omg_private.token_hash(gen_random_uuid())')), 'private helper schema denied');

  // Simulated activation only inside this disposable test database.
  await db.exec(`grant execute on function public.list_login_employees(text,text),
    public.start_work_session(uuid,text,text,text,text), public.get_work_session(uuid),
    public.end_device_session(uuid), public.save_work_report(uuid,text,jsonb),
    public.get_work_report(uuid,text), public.mark_report_delivered(uuid,uuid) to anon, authenticated;`);
  const staff = await asAnon(() => rows('select * from public.list_login_employees()'));
  check(staff.length === 4, 'property-scoped staff list');
  const first = staff.find(x => x.display_name === '변지훈').employee_id;
  const second = staff.find(x => x.display_name === '문정국').employee_id;
  const pin = testPins[0];
  const badPin = '999887';
  for (const input of [null, '', '1234', 'abcdef']) {
    check(!(await rpc('start_work_session', [first, input, 'morning'])).ok, 'malformed/null PIN fails closed');
  }
  check(!(await rpc('start_work_session', [first, pin, null])).ok, 'null shift rejected');
  check(!(await rpc('start_work_session', [randomUUID(), pin, 'morning'])).ok, 'unknown employee denied');
  for (let i = 0; i < 5; i++) check(!(await rpc('start_work_session', [first, badPin, 'morning'])).ok, 'wrong PIN rejected');
  check((await rpc('start_work_session', [first, pin, 'morning'])).code === 'locked', 'correct PIN cannot bypass timed lockout');
  check(Number((await one('select count(*) as n from public.work_sessions')).n) === 0, 'failed authentication never clocks in');
  await db.query("update public.employees set login_locked_until = now() - interval '1 minute' where id = $1", [first]);
  let login = await rpc('start_work_session', [first, pin, 'morning']);
  check(login.ok && !login.resumed && login.employee_name === '변지훈', 'correct PIN clocks in');
  const initial = login;
  check((await one('select clock_in_at::text as t from public.work_sessions where id=$1', [login.session_id])).t !== null, 'clock-in stored by database');
  check(!(await rpc('get_work_session', [randomUUID()])).ok, 'random bearer token denied');
  const repeat = await rpc('start_work_session', [first, pin, 'morning']);
  check(repeat.ok && repeat.resumed && repeat.session_id === login.session_id && repeat.clock_in_at === login.clock_in_at, 're-login preserves clock-in and session');
  check(!(await rpc('get_work_session', [login.access_token])).ok, 'rotated token invalidated');
  login = repeat;
  check((await rpc('start_work_session', [first, pin, 'afternoon'])).code === 'shift_conflict', 'changing an open shift is rejected');
  await rpc('end_device_session', [login.access_token]);
  check(!(await rpc('get_work_session', [login.access_token])).ok, 'logout invalidates token server-side');
  check((await one('select clock_out_at from public.work_sessions where id=$1', [login.session_id])).clock_out_at === null, 'logout does not invent a checkout time');
  login = await rpc('start_work_session', [first, pin, 'morning']);
  check(login.clock_in_at === initial.clock_in_at, 'login after logout preserves original clock-in');

  for (const [type, payload] of [[null, {}], ['clock_in', null], ['clock_in', []]]) {
    check(!(await rpc('save_work_report', [login.access_token, type, payload])).ok, 'invalid reports rejected');
  }
  let report = await rpc('save_work_report', [login.access_token, 'clock_in', { worker: 'forged', shift: 'forged', memo: 'first report' }]);
  check((await rpc('get_work_report', [login.access_token, 'clock_in'])).report_id === report.report_id, 'saved report recoverable after page reload');
  check(!(await rpc('get_work_report', [randomUUID(), 'clock_in'])).ok, 'reading a report requires valid token');
  check((await rpc('get_work_report', [login.access_token, 'clock_out'])).code === 'not_found', 'reading absent report never creates one');
  check(report.ok && !report.already_saved && report.payload.worker === '변지훈' && report.payload.shift === '오전', 'report identity comes from authenticated session');
  check(report.payload.attendance_clock_in_at === initial.clock_in_at, 'report keeps login time independent of submission time');
  const retry = await rpc('save_work_report', [login.access_token, 'clock_in', { memo: 'changed retry' }]);
  check(retry.report_id === report.report_id && retry.already_saved && retry.payload.memo === 'first report', 'retry returns original persisted report');
  check(Number((await one('select count(*) as n from public.work_reports')).n) === 1, 'retry does not duplicate reports');
  check(!(await rpc('mark_report_delivered', [randomUUID(), report.report_id])).ok, 'delivery acknowledgement requires session token');
  check((await rpc('mark_report_delivered', [login.access_token, report.report_id])).ok, 'delivery acknowledgement persisted');
  check((await rpc('save_work_report', [login.access_token, 'clock_in', {}])).make_accepted, 'retry knows Make already accepted report');

  const checkout = await rpc('save_work_report', [login.access_token, 'clock_out', { memo: 'finished' }]);
  const completed = await rpc('get_work_session', [login.access_token]);
  check(checkout.ok && completed.status === 'completed' && completed.clock_out_at, 'checkout report completes session');
  const checkoutRetry = await rpc('save_work_report', [login.access_token, 'clock_out', {}]);
  const completedRetry = await rpc('get_work_session', [login.access_token]);
  check(checkoutRetry.report_id === checkout.report_id && completedRetry.clock_out_at === completed.clock_out_at, 'checkout retry preserves report and checkout time');
  check(Number((await one('select count(*) as n from public.work_reports')).n) === 2, 'one check-in and one checkout report');
  await db.query("update public.work_sessions set token_expires_at=now()-interval '1 minute' where id=$1", [login.session_id]);
  check(!(await rpc('get_work_session', [login.access_token])).ok, 'expired session cannot be used');
  check(!(await rpc('save_work_report', [login.access_token, 'clock_in', {}])).ok, 'expired token cannot read/replay reports');

  let other = await rpc('start_work_session', [second, testPins[1], 'morning']);
  check(!(await rpc('mark_report_delivered', [other.access_token, report.report_id])).ok, 'staff cannot acknowledge another staff report');
  await db.query(`update public.work_sessions set clock_in_at=now()-interval '2 days',
    work_date=(now() at time zone 'Asia/Seoul')::date-2 where id=$1`, [other.session_id]);
  const nextDay = await rpc('start_work_session', [second, testPins[1], 'morning']);
  const previous = await one('select status,clock_out_at from public.work_sessions where id=$1', [other.session_id]);
  check(nextDay.ok && nextDay.session_id !== other.session_id && previous.status === 'needs_review' && previous.clock_out_at === null, 'missing checkout preserved for review while next workday starts');
  check(!(await rpc('get_work_session', [other.access_token])).ok, 'previous unfinished session token invalidated');
  await db.query('update public.employees set active=false where id=$1', [second]);
  check(!(await rpc('get_work_session', [nextDay.access_token])).ok, 'disabled employee loses access');
  check(!(await rpc('start_work_session', [second, testPins[1], 'morning'])).ok, 'disabled employee cannot log in');
  await db.query('update public.employees set active=true where id=$1', [second]);

  const business = (await one("insert into public.businesses(name,code) values('Test only','other-test') returning id")).id;
  const property = (await one("insert into public.properties(business_id,name,code) values($1,'Test only','other-test') returning id", [business])).id;
  const outsider = (await one("insert into public.employees(business_id,property_id,display_name,pin_hash) values($1,$2,'Test outsider',extensions.crypt($3,extensions.gen_salt('bf',4))) returning id", [business, property, pin])).id;
  check(!(await rpc('start_work_session', [outsider, pin, 'morning'])).ok, 'employee from a different property cannot use this login scope');
  check((await asAnon(() => rows('select * from public.list_login_employees()'))).length === 4, 'staff list excludes other businesses');
  await forbidden(() => db.query('update public.employees set property_id=$1 where id=$2', [property, first]), 'cross-tenant employee relation rejected', '23503');
  await forbidden(() => asAnon(() => db.query('select * from public.work_reports')), 'table access remains closed after RPC activation');

  // Reinstall closes previously activated RPCs, without removing attendance data.
  const reinstalled = await db.exec(functions);
  check(reinstalled.at(-1).rows.every(x => x.access_locked), 'reinstall closes RPC execution');
  check(Number((await one('select count(*) as n from public.work_reports')).n) === 2, 'reinstall preserves reports');
  const activationTemplate = fs.readFileSync(path.join(root, 'setup/004_rotate_and_activate.example.sql'), 'utf8');
  let rejected = false;
  try { await db.exec(activationTemplate); } catch (_) { rejected = true; await db.exec('rollback'); }
  check(rejected, 'unfilled activation template fails closed');
  const stillClosed = await db.exec(functions);
  check(stillClosed.at(-1).rows.every(x => x.access_locked), 'failed activation does not open RPCs');
  const newPins = ['852741', '964827', '638295', '749382']; // Synthetic replacement PINs only.
  const activation = activationTemplate.replace(/NEW_PIN_([1-4])/g, (_, i) => newPins[Number(i) - 1]);
  const activated = await db.exec(activation);
  check(activated.at(-1).rows.length === 7 && activated.at(-1).rows.every(x => x.api_ready), 'all seven RPCs enabled only after successful rotation');
  check(!(await rpc('start_work_session', [first, pin, 'morning'])).ok, 'old PIN rejected after rotation');
  check((await rpc('start_work_session', [first, newPins[0], 'morning'])).ok, 'replacement PIN accepted');
  check(!(await rpc('get_work_session', [nextDay.access_token])).ok, 'rotation invalidates old device sessions');

  // The exact one-paste handoff must be atomic and work on the user's step-2 state.
  const handoff = fs.readFileSync(path.join(root, 'setup/005_install_and_activate.example.sql'), 'utf8');
  const fresh = new PGlite({ extensions: { pgcrypto } });
  try {
    await fresh.exec('create role anon; create role authenticated; grant usage on schema public to anon, authenticated;');
    await fresh.exec(foundation);
    await fresh.exec(pinSetup);
    let handoffRejected = false;
    try { await fresh.exec(handoff); } catch (_) { handoffRejected = true; await fresh.exec('rollback'); }
    check(handoffRejected, 'combined installer rejects unfilled PINs');
    const absent = await fresh.query("select to_regnamespace('omg_private') is null as absent");
    check(absent.rows[0].absent, 'failed combined installer rolls back new functions and schema');
    const handoffResults = await fresh.exec(handoff.replace(/NEW_PIN_([1-4])/g, (_, i) => newPins[Number(i) - 1]));
    check(handoffResults.at(-1).rows.length === 7 && handoffResults.at(-1).rows.every(x => x.api_ready), 'exact one-paste installer enables seven functions after successful PIN rotation');
  } finally { await fresh.close(); }
  console.log(`PASS: ${checks} PostgreSQL workflow/security checks (local PGlite; no live writes).`);
}
run().catch(error => { console.error(error.message); process.exitCode = 1; }).finally(() => db.close());
