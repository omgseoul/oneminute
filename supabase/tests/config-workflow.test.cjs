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
const missionNoticeMigration = read('migrations/013_mission_photos_property_notice.sql');
const accountAdminMigration = read('migrations/014_account_staff_admin_navigation.sql');
const accountPropertyMigration = read('migrations/015_account_property_tenancy.sql');
const attendanceMigration = read('migrations/016_attendance_statistics.sql');
const staffAttendanceMigration = read('migrations/017_staff_attendance_access.sql');
const sharedReportFieldsMigration = read('migrations/018_shared_report_fields.sql');
const platformOperatorMigration = read('migrations/019_platform_operator_center.sql');
const businessTypesMigration = read('migrations/020_business_types_custom_report_fields.sql');
const attendanceAdjustmentMigration = read('migrations/021_attendance_adjustment_approval.sql');
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
async function accountRpc(userId, email, name, args = []) {
  await db.exec(`set role authenticated; set request.jwt.claim.sub='${userId}'; set request.jwt.claim.email='${email.replaceAll("'", "''")}';`);
  try {
    const placeholders = args.map((_, index) => '$' + (index + 1)).join(',');
    return (await one(`select public.${name}(${placeholders}) as result`, args)).result;
  } finally { await db.exec('reset role; reset request.jwt.claim.sub; reset request.jwt.claim.email;'); }
}
async function accountRows(userId, email, name) {
  await db.exec(`set role authenticated; set request.jwt.claim.sub='${userId}'; set request.jwt.claim.email='${email.replaceAll("'", "''")}';`);
  try { return await rows(`select * from public.${name}()`); }
  finally { await db.exec('reset role; reset request.jwt.claim.sub; reset request.jwt.claim.email;'); }
}

async function run() {
  await db.exec(`create role anon; create role authenticated; grant usage on schema public to anon, authenticated;
    create schema auth; create table auth.users(id uuid primary key,email text not null);
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    create function auth.jwt() returns jsonb language sql stable as $$select jsonb_build_object('email',current_setting('request.jwt.claim.email',true))$$;
    grant usage on schema auth to authenticated; grant execute on function auth.uid(),auth.jwt() to authenticated;`);
  await db.exec(foundation);
  await db.exec(pinSetup);
  await db.exec(sessions);
  await db.exec(settings);
  await db.exec(missions);
  await db.exec(management);
  await db.exec(compactSettings);
  await db.exec(urgentMessages);
  await db.exec(staffMissionMigration);
  await db.exec(missionNoticeMigration);
  await db.exec(accountAdminMigration);

  const ownerSetup = read('setup/007_create_owner.example.sql')
    .replace(/OWNER_LOGIN_ID/g, 'boss.test')
    .replace(/OWNER_PIN_6_TO_8/g, ownerPin);
  await db.exec(ownerSetup);
  const existingUserId = 'e770cb6a-9925-4f62-a5f3-cebcfe37278f';
  const newUserId = '10000000-0000-4000-8000-000000000099';
  await db.query('insert into auth.users(id,email) values($1,$2),($3,$4)', [existingUserId, 'oneminute01@naver.com', newUserId, 'new-owner@example.com']);
  await db.exec(accountPropertyMigration);
  await db.exec(attendanceMigration);
  await db.exec(staffAttendanceMigration);
  await db.exec(sharedReportFieldsMigration);

  const employees = await rows('select id,display_name from public.employees order by display_name');
  const staff = employees.find(employee => employee.display_name === '문정국');

  const existingContext = await accountRpc(existingUserId, 'oneminute01@naver.com', 'get_or_create_account_property');
  check(existingContext.ok && existingContext.property_name === 'One Minute' && !existingContext.onboarding_pending, 'existing email is linked to original One Minute data');
  const existingStaff = await accountRows(existingUserId, 'oneminute01@naver.com', 'list_account_login_employees');
  check(existingStaff.length === 4, 'existing account sees its original workers');
  const newContext = await accountRpc(newUserId, 'new-owner@example.com', 'get_or_create_account_property');
  check(newContext.ok && newContext.property_name === '새 숙소' && newContext.onboarding_pending, 'new email automatically receives an isolated property');
  const newAdmins = await accountRows(newUserId, 'new-owner@example.com', 'list_account_login_admins');
  check(newAdmins.length === 1 && newAdmins[0].display_name === '관리자', 'new property receives a temporary administrator');
  const newAdminLogin = await accountRpc(newUserId, 'new-owner@example.com', 'start_account_admin_session', [newAdmins[0].owner_id, '1234']);
  check(newAdminLogin.ok && newAdminLogin.session_kind === 'owner', 'temporary administrator PIN 1234 logs in');
  check((await accountRows(newUserId, 'new-owner@example.com', 'list_account_login_employees')).length === 0, 'new property cannot see original workers');
  check((await accountRpc(newUserId, 'new-owner@example.com', 'acknowledge_account_onboarding')).ok, 'welcome dialog can be acknowledged');
  check(!(await accountRpc(newUserId, 'new-owner@example.com', 'get_or_create_account_property')).onboarding_pending, 'welcome dialog is shown only until acknowledged');

  await db.exec(platformOperatorMigration);
  await db.exec(businessTypesMigration);
  await db.exec(attendanceAdjustmentMigration);
  check(await accountRpc(existingUserId, 'oneminute01@naver.com', 'is_platform_administrator'), 'founder email receives platform operator access');
  check(!(await accountRpc(newUserId, 'new-owner@example.com', 'is_platform_administrator')), 'tenant email does not receive platform operator access');
  const platformDenied = await accountRpc(newUserId, 'new-owner@example.com', 'get_platform_dashboard');
  check(!platformDenied.ok && platformDenied.code === 'platform_admin_required', 'tenant cannot open the platform dashboard');
  let platformDashboard = await accountRpc(existingUserId, 'oneminute01@naver.com', 'get_platform_dashboard');
  check(platformDashboard.ok && platformDashboard.properties.length === 2, 'platform dashboard lists every isolated property');
  check(platformDashboard.summary.total === 2 && platformDashboard.summary.active === 1 && platformDashboard.summary.trial === 1, 'platform dashboard summarizes active and trial properties');
  const tenantProperty = platformDashboard.properties.find(item => item.email === 'new-owner@example.com');
  check(tenantProperty && tenantProperty.management_number === 2 && tenantProperty.employee_count === 0, 'platform dashboard shows tenant management number and usage');
  check((await accountRpc(newUserId, 'new-owner@example.com', 'update_platform_property', [tenantProperty.property_id, 'suspended', 'blocked'])).code === 'platform_admin_required', 'tenant cannot change service status');
  check((await accountRpc(existingUserId, 'oneminute01@naver.com', 'update_platform_property', [tenantProperty.property_id, 'suspended', '지원 확인 중'])).ok, 'platform operator suspends a property');
  check((await accountRpc(newUserId, 'new-owner@example.com', 'start_account_admin_session', [newAdmins[0].owner_id, '1234'])).code === 'service_unavailable', 'suspended property cannot start a PIN session');
  check((await accountRpc(existingUserId, 'oneminute01@naver.com', 'update_platform_property', [tenantProperty.property_id, 'active', '확인 완료'])).ok, 'platform operator reactivates a property');
  check((await accountRpc(existingUserId, 'oneminute01@naver.com', 'reset_platform_property_admin_pin', [tenantProperty.property_id])).temporary_pin === '1234', 'platform operator resets the default administrator PIN without reading it');
  check((await accountRpc(newUserId, 'new-owner@example.com', 'start_account_admin_session', [newAdmins[0].owner_id, '1234'])).ok, 'reset temporary administrator PIN logs in after reactivation');
  platformDashboard = await accountRpc(existingUserId, 'oneminute01@naver.com', 'get_platform_dashboard');
  check(platformDashboard.recent_actions.length === 3, 'platform changes are retained in an audit log');

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
  check(ownerConfig.property.notice === '', 'property announcement defaults to empty');
  check(ownerConfig.property.business_type === null, 'business type defaults to no selection');
  check(ownerConfig.property.custom_report_fields.length === 0, 'custom report fields default to empty');
  check(ownerConfig.administrators.length === 1 && ownerConfig.administrators[0].is_current, 'owner receives the current administrator account');

  const publicAdmins = await asAnon(() => rows('select * from public.list_login_admins($1,$2)', ['omg', 'seoul-station']));
  check(publicAdmins.length === 1 && publicAdmins[0].display_name === '사장', 'unified PIN login lists administrators');
  const adminByPin = await rpc('start_admin_session', [publicAdmins[0].owner_id, ownerPin, 'omg', 'seoul-station']);
  check(adminByPin.ok && adminByPin.session_kind === 'owner', 'administrator can enter with the same PIN flow');

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
    [{ name: '싱글', rooms: ['101', '102'] }, { name: '더블', rooms: ['103'] }],
    'lodging',
    [{ key: 'custom_lobby_note', label: '로비 상태' }]
  ]);
  check(saved.ok && saved.property.name === '테스트 숙소', 'owner changes property title');
  check(saved.property.rooms.join(',') === '101,102,103', 'room names are trimmed and deduplicated');
  check(saved.property.room_types[0].name === '싱글' && saved.property.room_types[1].rooms[0] === '103', 'room type names and room numbers are saved together');
  check(saved.property.business_type === 'lodging' && saved.property.custom_report_fields[0].label === '로비 상태', 'business type and custom report fields are saved');

  const accountSaved = await rpc('save_employee_accounts', [ownerLogin.access_token, [
    ...ownerConfig.employees.map(employee => ({ employee_id: employee.employee_id, display_name: employee.display_name, pin: '' })),
    { employee_id: null, display_name: '신규직원', pin: '246813' }
  ]]);
  check(accountSaved.ok && accountSaved.employees.some(employee => employee.display_name === '신규직원'), 'owner adds a worker account with a PIN');
  const added = accountSaved.employees.find(employee => employee.display_name === '신규직원');
  check((await rpc('start_work_session', [added.employee_id, '246813', 'general'])).ok, 'new worker PIN can log in');

  const adminSaved = await rpc('save_admin_accounts', [ownerLogin.access_token, [
    ...ownerConfig.administrators.map(admin => ({ owner_id: admin.owner_id, display_name: admin.display_name, login_id: admin.login_id, pin: '' })),
    { owner_id: null, display_name: '보조 관리자', login_id: 'assistant.manager', pin: '314159' }
  ]]);
  check(adminSaved.ok && adminSaved.administrators.some(admin => admin.display_name === '보조 관리자'), 'owner adds an administrator account with a PIN');
  const addedAdmin = adminSaved.administrators.find(admin => admin.display_name === '보조 관리자');
  check((await rpc('start_admin_session', [addedAdmin.owner_id, '314159', 'omg', 'seoul-station'])).ok, 'new administrator PIN can log in');

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
  check((await rpc('save_property_settings', [staffLogin.access_token, '해킹', ['999'], {}, [{ name: '객실', rooms: ['999'] }], 'lodging', []])).code === 'owner_required', 'staff cannot change property settings');
  check((await rpc('save_employee_accounts', [staffLogin.access_token, [{ display_name: '침입자', pin: '123456' }]])).code === 'owner_required', 'staff cannot create worker accounts');
  check((await rpc('save_property_settings', [ownerLogin.access_token, '테스트 숙소', [], employeeConfigs, [], 'lodging', []])).code === 'invalid_room_types', 'lodging requires room types');
  check((await rpc('save_property_settings', [ownerLogin.access_token, '테스트 숙소', [], employeeConfigs, [], 'general', []])).ok, 'non-lodging properties do not require room types');
  check((await rpc('save_property_settings', [ownerLogin.access_token, '테스트 숙소', ['101'], { [staff.id]: { clock_in: ['unknown'], clock_out: [], reminder_cards: [] } }, [{ name: '객실', rooms: ['101'] }], 'lodging', []])).code === 'invalid_employee_config', 'unknown report fields are rejected');
  check((await rpc('save_property_settings', [ownerLogin.access_token, '테스트 숙소', ['101'], { [staff.id]: { clock_in: ['custom_missing'], clock_out: [], reminder_cards: [] } }, [{ name: '객실', rooms: ['101'] }], 'lodging', []])).code === 'invalid_employee_config', 'unregistered custom report fields are rejected');
  ownerConfig = await rpc('save_property_notice', [ownerLogin.access_token, '오늘 3층 소방 점검이 있습니다.']);
  check(ownerConfig.property.notice.includes('소방 점검'), 'owner saves a property announcement');
  check((await rpc('save_property_notice', [staffLogin.access_token, '변조 공지'])).code === 'owner_required', 'staff cannot change property announcement');

  const newMission = await rpc('save_mission', [ownerLogin.access_token, {
    title: '침구 확인', description: '오염 여부 확인', timing: 'today', priority: 'important',
    target_employee_ids: [staff.id], photo_required: true, estimated_minutes: 15, due_at: null,
    description_photo: 'data:image/jpeg;base64,dGVzdA=='
  }]);
  check(newMission.ok, 'owner creates a targeted mission');
  const editedMission = await rpc('save_mission', [ownerLogin.access_token, {
    id: newMission.mission_id, title: '침구 재확인', description: '오염 여부 재확인', timing: 'this_week', priority: 'urgent',
    target_employee_ids: [staff.id], photo_required: true, estimated_minutes: 20, due_at: null,
    description_photo: 'data:image/jpeg;base64,dGVzdA=='
  }]);
  check(editedMission.ok && editedMission.mission_id === newMission.mission_id, 'owner edits an existing mission');
  let staffMissions = await rpc('list_missions', [staffLogin.access_token]);
  check(staffMissions.missions.length === 1 && staffMissions.missions[0].title === '침구 재확인', 'target employee sees edited mission');
  check(staffMissions.missions[0].description_photo.startsWith('data:image/'), 'mission reference photo is returned');
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
  const attendanceDate = (await one('select work_date from public.work_sessions where id=$1', [staffLogin.session_id])).work_date;
  await db.query("update public.work_sessions set clock_out_at=clock_in_at+interval '7 hours 35 minutes',status='completed' where id=$1", [staffLogin.session_id]);
  const adjustment = await rpc('request_attendance_adjustment', [staffLogin.access_token, staffLogin.session_id, '09:00', '17:00']);
  check(adjustment.ok && adjustment.status === 'pending', 'staff submits an attendance adjustment for owner approval');
  inbox = await rpc('list_urgent_messages', [ownerLogin.access_token]);
  const approvalMessage = inbox.messages.find(item => item.attendance_request_id === adjustment.request_id);
  check(approvalMessage?.message_type === 'attendance_approval' && approvalMessage.approval_status === 'pending', 'attendance adjustment appears in the owner inbox as an approval');
  check((await rpc('approve_attendance_adjustment', [ownerLogin.access_token, adjustment.request_id])).status === 'approved', 'owner approves the attendance adjustment');
  const attendance = await rpc('list_attendance_statistics', [ownerLogin.access_token, attendanceDate, attendanceDate]);
  check(attendance.ok && attendance.sessions.some(item => item.employee_id === staff.id && item.duration_minutes === 480 && item.adjustment_status === 'approved'), 'approved attendance times replace the recorded duration');
  const staffAttendance = await rpc('list_attendance_statistics', [staffLogin.access_token, attendanceDate, attendanceDate]);
  check(staffAttendance.ok && staffAttendance.scope === 'self' && staffAttendance.sessions.every(item => item.employee_id === staff.id), 'staff attendance statistics return only the logged-in worker');

  const deleted = await rpc('delete_employee_account', [ownerLogin.access_token, added.employee_id]);
  check(deleted.ok && !deleted.employees.some(employee => employee.employee_id === added.employee_id), 'owner can remove a worker account');
  check(!(await rpc('start_work_session', [added.employee_id, '246813', 'general'])).ok, 'deleted worker cannot log in');
  const deletedAdmin = await rpc('delete_admin_account', [ownerLogin.access_token, addedAdmin.owner_id]);
  check(deletedAdmin.ok && !deletedAdmin.administrators.some(admin => admin.owner_id === addedAdmin.owner_id), 'owner can remove another administrator account');
  check(!(await rpc('start_admin_session', [addedAdmin.owner_id, '314159', 'omg', 'seoul-station'])).ok, 'deleted administrator cannot log in');

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
