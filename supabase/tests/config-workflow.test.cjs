// Property settings and role authorization tests in local in-memory PostgreSQL.
// No network, hosted database, credentials, or Make webhooks are used.
const { PGlite } = require('@electric-sql/pglite');
const { pgcrypto } = require('@electric-sql/pglite/contrib/pgcrypto');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const foundation = read('migrations/001_initial_schema.sql');
const sessions = read('migrations/003_staff_sessions.sql');
const settings = read('migrations/006_property_report_settings.sql');
const missions = read('migrations/008_missions_reminder_cards.sql');
const pins = ['731482', '628951', '849263', '953728']; // Synthetic local-only PINs.
const ownerPin = '517394';
const pinSetup = read('setup/002_register_employee_pins.example.sql')
  .replace(/PIN_([1-4])/g, (_, number) => pins[Number(number) - 1]);
const db = new PGlite({ extensions: { pgcrypto } });
let checks = 0;
function check(value, label) { assert.ok(value, label); checks++; }
async function rows(sql, params = []) { return (await db.query(sql, params)).rows; }
async function one(sql, params = []) { return (await rows(sql, params))[0]; }
async function asAnon(fn) { await db.exec('set role anon'); try { return await fn(); } finally { await db.exec('reset role'); } }
async function rpc(name, args) {
  const placeholders = args.map((_, index) => '$' + (index + 1)).join(',');
  return asAnon(async () => (await one(`select public.${name}(${placeholders}) as result`, args)).result);
}

async function run() {
  await db.exec('create role anon; create role authenticated; grant usage on schema public to anon, authenticated;');
  await db.exec(foundation);
  await db.exec(pinSetup);
  await db.exec(sessions);
  await db.exec(settings);
  await db.exec(missions);

  const ownerSetup = read('setup/007_create_owner.example.sql')
    .replace(/OWNER_LOGIN_ID/g, 'boss.test')
    .replace(/OWNER_PIN_6_TO_8/g, ownerPin);
  await db.exec(ownerSetup);

  const employees = await rows('select id,display_name from public.employees order by display_name');
  const staff = employees.find(employee => employee.display_name === '문정국');

  const publicProperty = await rpc('get_login_property', []);
  check(publicProperty.ok && publicProperty.property_name === 'One Minute', 'login title loads without a session');

  const ownerLogin = await rpc('start_owner_session', ['boss.test', ownerPin]);
  check(ownerLogin.ok && ownerLogin.session_kind === 'owner', 'owner uses a separate owner session');
  check(ownerLogin.property_name === 'One Minute', 'session includes property name');
  check(Number((await one('select count(*) as count from public.work_sessions')).count) === 0, 'owner login never creates attendance');
  check((await rpc('get_app_session', [ownerLogin.access_token])).session_kind === 'owner', 'owner session is verified independently');
  let ownerConfig = await rpc('get_work_app_config', [ownerLogin.access_token]);
  check(ownerConfig.can_manage && ownerConfig.employees.length === 4, 'owner receives employee settings');
  check(ownerConfig.property.rooms.length === 16, 'existing One Minute rooms are preserved as defaults');

  const employeeConfigs = {};
  for (const employee of ownerConfig.employees) {
    employeeConfigs[employee.employee_id] = employee.employee_id === staff.id
      ? { clock_in: ['clean_rooms', 'no_show', 'reminder_cards'], clock_out: ['cleaned_rooms'], reminder_cards: employee.report_config.reminder_cards }
      : employee.report_config;
  }
  const saved = await rpc('save_property_settings', [
    ownerLogin.access_token,
    '테스트 숙소',
    ['101', '102', '102', '103'],
    employeeConfigs
  ]);
  check(saved.ok && saved.property.name === '테스트 숙소', 'owner changes property title');
  check(saved.property.rooms.join(',') === '101,102,103', 'room names are trimmed and deduplicated');

  const loginTitle = await rpc('get_login_property', []);
  check(loginTitle.property_name === '테스트 숙소', 'new property title appears on login');
  const staffLogin = await rpc('start_work_session', [staff.id, pins[1], 'general']);
  check(staffLogin.session_kind === 'staff', 'employee login creates a staff attendance session');
  const staffConfig = await rpc('get_work_app_config', [staffLogin.access_token]);
  check(!staffConfig.can_manage && staffConfig.employees.length === 0, 'staff cannot list employee settings');
  check(staffConfig.report_config.clock_in.join(',') === 'clean_rooms,no_show,reminder_cards', 'staff receives only configured check-in fields');
  check(staffConfig.report_config.clock_out.join(',') === 'cleaned_rooms', 'staff receives only configured check-out fields');
  check(staffConfig.report_config.reminder_cards.length === 2, 'staff receives configured reminder cards');
  check((await rpc('save_property_settings', [staffLogin.access_token, '해킹', ['999'], {}])).code === 'owner_required', 'staff cannot change property settings');
  check((await rpc('save_property_settings', [ownerLogin.access_token, '테스트 숙소', [], employeeConfigs])).code === 'invalid_rooms', 'empty room list is rejected');
  check((await rpc('save_property_settings', [ownerLogin.access_token, '테스트 숙소', ['101'], { [staff.id]: { clock_in: ['unknown'], clock_out: [], reminder_cards: [] } }])).code === 'invalid_employee_config', 'unknown report fields are rejected');

  const newMission = await rpc('save_mission', [ownerLogin.access_token, {
    title: '침구 확인', description: '오염 여부 확인', timing: 'today', priority: 'important',
    target_employee_ids: [staff.id], photo_required: true, estimated_minutes: 15, due_at: null
  }]);
  check(newMission.ok, 'owner creates a targeted mission');
  let staffMissions = await rpc('list_missions', [staffLogin.access_token]);
  check(staffMissions.missions.length === 1 && staffMissions.missions[0].title === '침구 확인', 'target employee sees mission');
  check((await rpc('complete_mission', [staffLogin.access_token, newMission.mission_id, '', ''])).code === 'photo_required', 'required completion photo is enforced');
  check((await rpc('complete_mission', [staffLogin.access_token, newMission.mission_id, '완료', 'data:image/jpeg;base64,dGVzdA=='])).ok, 'staff completes mission with photo');
  staffMissions = await rpc('list_missions', [staffLogin.access_token]);
  check(Boolean(staffMissions.missions[0].completed_at), 'mission completion is returned');
  check((await rpc('archive_mission', [ownerLogin.access_token, newMission.mission_id])).ok, 'owner archives mission');

  let tableDenied = false;
  try { await asAnon(() => db.query('select * from public.properties')); } catch (_) { tableDenied = true; }
  check(tableDenied, 'direct table access remains denied');
  let ownersDenied = false;
  try { await asAnon(() => db.query('select * from public.owners')); } catch (_) { ownersDenied = true; }
  check(ownersDenied, 'owner credentials remain unreadable to browser roles');
  const privateExecute = await one("select has_function_privilege('anon','omg_private.owner_session_result(uuid)','EXECUTE') as allowed");
  check(!privateExecute.allowed, 'private owner-session helper is not executable by browser roles');
  console.log(`PASS: ${checks} property/report-setting checks (local PGlite; no live writes).`);
}
run().catch(error => { console.error(error.stack || error.message); process.exitCode = 1; }).finally(() => db.close());
