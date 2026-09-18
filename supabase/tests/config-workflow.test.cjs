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
const management = read('migrations/009_complete_management.sql');
const compactSettings = read('migrations/010_compact_settings_report_edits.sql');
const urgentMessages = read('migrations/011_urgent_messages_and_mission_filter.sql');
const staffMissionMigration = read('migrations/012_staff_missions_property_number.sql');
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
  await db.exec(management);
  await db.exec(compactSettings);
  await db.exec(urgentMessages);
  await db.exec(staffMissionMigration);

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
  check(ownerConfig.property.room_types.length === 4, 'existing One Minute rooms are grouped by room type');
  check(ownerConfig.property.management_number === 1, 'current property receives management number 1');

  const employeeConfigs = {};
  for (const employee of ownerConfig.employees) {
    employeeConfigs[employee.employee_id] = employee.employee_id === staff.id
      ? { clock_in: ['clean_rooms', 'no_show', 'reminder_cards'], clock_out: ['cleaned_rooms'], reminder_cards: employee.report_config.reminder_cards }
      : employee.report_config;
  }
  const saved = await rpc('save_property_settings', [
    ownerLogin.access_token,
    '테스트 숙소',
    ['101', '102', '103'],
    employeeConfigs,
    [{ name: '싱글', rooms: ['101', '102'] }, { name: '더블', rooms: ['103'] }]
  ]);
  check(saved.ok && saved.property.name === '테스트 숙소', 'owner changes property title');
  check(saved.property.rooms.join(',') === '101,102,103', 'room names are trimmed and deduplicated');
  check(saved.property.room_types[0].name === '싱글' && saved.property.room_types[1].rooms[0] === '103', 'room type names and room numbers are saved together');

  const accountSaved = await rpc('save_employee_accounts', [ownerLogin.access_token, [
    ...ownerConfig.employees.map(employee => ({ employee_id: employee.employee_id, display_name: employee.display_name, pin: '' })),
    { employee_id: null, display_name: '신규직원', pin: '246813' }
  ]]);
  check(accountSaved.ok && accountSaved.employees.some(employee => employee.display_name === '신규직원'), 'owner adds a worker account with a PIN');
  const added = accountSaved.employees.find(employee => employee.display_name === '신규직원');
  check((await rpc('start_work_session', [added.employee_id, '246813', 'general'])).ok, 'new worker PIN can log in');

  const loginTitle = await rpc('get_login_property', []);
  check(loginTitle.property_name === '테스트 숙소', 'new property title appears on login');
  const staffLogin = await rpc('start_work_session', [staff.id, pins[1], 'general']);
  check(staffLogin.session_kind === 'staff', 'employee login creates a staff attendance session');
  const staffConfig = await rpc('get_work_app_config', [staffLogin.access_token]);
  check(!staffConfig.can_manage && staffConfig.employees.length === 0, 'staff cannot list employee settings');
  check(staffConfig.report_config.clock_in.join(',') === 'clean_rooms,no_show,reminder_cards', 'staff receives only configured check-in fields');
  check(staffConfig.report_config.clock_out.join(',') === 'cleaned_rooms', 'staff receives only configured check-out fields');
  check(staffConfig.report_config.reminder_cards.length === 4, 'staff receives four default reminder cards');
  check(staffConfig.report_config.reminder_cards.every(card => card.weekdays.length === 7), 'reminder cards include weekday visibility');
  check((await rpc('save_property_settings', [staffLogin.access_token, '해킹', ['999'], {}, [{ name: '객실', rooms: ['999'] }]])).code === 'owner_required', 'staff cannot change property settings');
  check((await rpc('save_employee_accounts', [staffLogin.access_token, [{ display_name: '침입자', pin: '123456' }]])).code === 'owner_required', 'staff cannot create worker accounts');
  check((await rpc('save_property_settings', [ownerLogin.access_token, '테스트 숙소', [], employeeConfigs, []])).code === 'invalid_room_types', 'empty room types are rejected');
  check((await rpc('save_property_settings', [ownerLogin.access_token, '테스트 숙소', ['101'], { [staff.id]: { clock_in: ['unknown'], clock_out: [], reminder_cards: [] } }, [{ name: '객실', rooms: ['101'] }]])).code === 'invalid_employee_config', 'unknown report fields are rejected');

  const newMission = await rpc('save_mission', [ownerLogin.access_token, {
    title: '침구 확인', description: '오염 여부 확인', timing: 'today', priority: 'important',
    target_employee_ids: [staff.id], photo_required: true, estimated_minutes: 15, due_at: null
  }]);
  check(newMission.ok, 'owner creates a targeted mission');
  const editedMission = await rpc('save_mission', [ownerLogin.access_token, {
    id: newMission.mission_id, title: '침구 재확인', description: '오염 여부 재확인', timing: 'this_week', priority: 'urgent',
    target_employee_ids: [staff.id], photo_required: true, estimated_minutes: 20, due_at: null
  }]);
  check(editedMission.ok && editedMission.mission_id === newMission.mission_id, 'owner edits an existing mission');
  let staffMissions = await rpc('list_missions', [staffLogin.access_token]);
  check(staffMissions.missions.length === 1 && staffMissions.missions[0].title === '침구 재확인', 'target employee sees edited mission');
  check(staffMissions.employees.some(employee => employee.employee_id === staff.id), 'mission response includes selectable workers');
  check((await rpc('complete_mission', [staffLogin.access_token, newMission.mission_id, '', ''])).code === 'photo_required', 'required completion photo is enforced');
  check((await rpc('complete_mission', [staffLogin.access_token, newMission.mission_id, '완료', 'data:image/jpeg;base64,dGVzdA=='])).ok, 'staff completes mission with photo');
  staffMissions = await rpc('list_missions', [staffLogin.access_token]);
  check(Boolean(staffMissions.missions[0].completed_at), 'mission completion is returned');
  const ownerMissions = await rpc('list_missions', [ownerLogin.access_token]);
  check(ownerMissions.missions[0].completions[0].note === '완료', 'owner can open completed mission details');
  check(staffMissions.missions[0].completion_employee_ids.includes(staff.id), 'staff mission filter receives completion employee ids');
  check((await rpc('archive_mission', [ownerLogin.access_token, newMission.mission_id])).ok, 'owner archives mission');

  const staffCreated = await rpc('save_mission', [staffLogin.access_token, {
    title: '직원 생성 미션', description: '직접 등록', timing: 'anytime', priority: 'important',
    target_employee_ids: [], photo_required: false, due_at: null
  }]);
  check(staffCreated.ok, 'staff creates a mission for themselves');
  staffMissions = await rpc('list_missions', [staffLogin.access_token]);
  const staffCreatedItem = staffMissions.missions.find(item => item.id === staffCreated.mission_id);
  check(staffCreatedItem.creator_name === staff.display_name && staffCreatedItem.target_employee_ids.includes(staff.id), 'staff mission records employee creator and self target');
  check((await rpc('save_mission', [staffLogin.access_token, { id: staffCreated.mission_id, title: '변조', timing: 'today' }])).code === 'owner_required', 'staff cannot edit an existing mission');

  const urgent = await rpc('send_urgent_message', [staffLogin.access_token, '보일러가 작동하지 않습니다.']);
  check(urgent.ok, 'staff sends an urgent message through Supabase');
  let inbox = await rpc('list_urgent_messages', [ownerLogin.access_token]);
  check(inbox.unread_count === 1 && inbox.messages[0].employee_name === staff.display_name, 'owner receives the staff urgent message');
  check((await rpc('acknowledge_urgent_message', [ownerLogin.access_token, inbox.messages[0].message_id])).ok, 'owner acknowledges an urgent message');
  inbox = await rpc('list_urgent_messages', [ownerLogin.access_token]);
  check(inbox.unread_count === 0 && inbox.messages[0].acknowledged_at, 'acknowledged urgent message remains in history');

  const originalReport = await rpc('save_work_report', [staffLogin.access_token, 'clock_in', { memo: '처음 보고' }]);
  const editedReport = await rpc('update_work_report', [staffLogin.access_token, 'clock_in', { memo: '수정 보고' }]);
  check(originalReport.report_id === editedReport.report_id && editedReport.payload.memo === '수정 보고' && !editedReport.make_accepted, 'completed report can be edited and queued for delivery again');

  const deleted = await rpc('delete_employee_account', [ownerLogin.access_token, added.employee_id]);
  check(deleted.ok && !deleted.employees.some(employee => employee.employee_id === added.employee_id), 'owner can remove a worker account');
  check(!(await rpc('start_work_session', [added.employee_id, '246813', 'general'])).ok, 'deleted worker cannot log in');

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
