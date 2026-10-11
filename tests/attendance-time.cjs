const assert=require('node:assert/strict'),fs=require('node:fs');
const vm=require('node:vm'),time=require('../attendance-time.js');
const now=new Date('2026-10-11T09:48:00Z');
assert.equal(time.range('2026-10-10T09:52Z','2026-10-11T08:44Z','Asia/Seoul','2026-10-10'),'10/10 18:52 ~ 10/11 17:44');
assert.equal(time.range('2026-10-10T00:00Z','2026-10-10T08:00Z','Asia/Seoul','2026-10-10'),'09:00 ~ 17:00');
assert.equal(time.range('2026-12-31T14:00Z','2026-12-31T16:00Z','Asia/Seoul','2026-12-31'),'2026/12/31 23:00 ~ 2027/01/01 01:00');
assert.equal(time.range('2026-10-10T09:52Z',null,'Asia/Seoul','2026-10-10'),'18:52 ~ -');
assert.equal(time.future('2026-10-11','09:00','18:49','Asia/Seoul',now),true);
assert.equal(time.future('2026-10-11','18:52','17:44','Asia/Seoul',now),true);
assert.equal(time.future('2026-10-10','18:52','17:44','Asia/Seoul',now),false);
assert.equal(time.future('2026-10-11','09:00','18:48','Asia/Seoul',now),false);
assert.equal(time.future('2026-10-11','09:00','09:00','Asia/Seoul',now),true);
assert.equal(time.future('2026-10-11','09:00','19:00','Australia/Melbourne',now),false);
(async()=>{
 const html=fs.readFileSync('attendance.html','utf8'),nodes={submitEdit:{disabled:false},editStart:{value:'09:00'},editEnd:{value:'18:00'},editError:{textContent:''}},calls=[];
 const context={document:{getElementById:id=>nodes[id]},OMSAttendanceTime:time,payload:{timezone:'Asia/Seoul'},editingItem:{work_date:time.nextDate(time.parts(new Date()).date),session_id:'test'},session:{accessToken:'test'},isOwner:true,message:{textContent:''},confirmOvernight:async()=>true,window:{omgSupabase:{rpc:async(name)=>{calls.push(name);return{data:{ok:true}};}}},closeEdit(){},load:async()=>{},pushApprovalMessage(){},Error};
 vm.createContext(context);
 const handler=html.match(/document.getElementById\("submitEdit"\).onclick=(async\(\)=>\{[\s\S]*?\});\n/)[1];
 vm.runInContext('submit='+handler,context);
 for(const owner of [true,false]){context.isOwner=owner;await context.submit();assert.match(nodes.editError.textContent,/현재 시각 이후/);assert.equal(calls.length,0);assert.equal(nodes.submitEdit.disabled,false);}
 context.isOwner=true;context.editingItem.work_date='2026-01-01';nodes.editStart.value='18:52';nodes.editEnd.value='17:44';await context.submit();assert.deepEqual(calls,['owner_update_attendance']);
 for(const name of ['attendance.html','messages.html'])for(const m of fs.readFileSync(name,'utf8').matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/g))if(!m[1].includes('src='))new vm.Script(m[2]);
 console.log('10 time/date checks, owner/staff future-block, past overnight submit and inline script syntax passed');
})().catch(e=>{console.error(e);process.exitCode=1;});
