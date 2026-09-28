import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const root=new URL('../../',import.meta.url);
const read=name=>readFile(new URL(name,root),'utf8');

test('cleanup UI includes attendance, custom ranges and confirmed execution',async()=>{
 const [ui,owner]=await Promise.all([read('platform-storage.js'),read('owner-settings.html')]);
 assert.match(ui,/출퇴근 기록/);
 assert.match(ui,/직접 기간 설정/);
 assert.match(ui,/>삭제실행</);
 assert.match(ui,/title:'내역을 삭제할까요\?'/);
 assert.match(owner,/>데이터 관리</);
 assert.match(owner,/PropertyDataManagement\.mount/);
});

test('owner cleanup is property-scoped and never removes an open attendance session',async()=>{
 const sql=await read('supabase/migrations/045_property_data_management.sql');
 assert.match(sql,/owner_message_storage/);
 assert.match(sql,/p_property_scope is not null and prop<>p_property_scope/);
 assert.match(sql,/clock_out_at is not null/);
 assert.match(sql,/range_start/);
});
