const fs=require('node:fs');
const assert=require('node:assert/strict');
const {JSDOM}=require('jsdom');
const read=file=>fs.readFileSync(file,'utf8');
const tick=()=>new Promise(resolve=>setTimeout(resolve,30));
function page(file){const html=read(file),dom=new JSDOM(html.replace(/<script[\s\S]*?<\/script>/g,''),{url:`https://omgworks24.com/${file}`,runScripts:'outside-only',pretendToBeVisual:true});return {html,dom,w:dom.window};}
function inline(w,html){for(const match of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g))if(match[1].trim())w.eval(match[1]+(match[1].includes('employeeConfigs={}')?';window.testConfigs=()=>employeeConfigs;window.testSync=syncCurrent;':''));}
(async()=>{
 let {html,dom,w}=page('owner-settings.html');w.omgTransition={ready(){}};w.eval(read('work-config.js'));w.eval(read('property-selector.js'));w.eval(read('select-picker.js'));
 const card={id:'c1',title:'First',image:'test.png',text:'Reminder',report_types:['clock_in','clock_out'],report_weekdays:{clock_in:[1],clock_out:[2]},weekdays:[1,2]};
 const cfg={can_manage:true,property:{name:'Test',business_type:'general',room_types:[],custom_report_fields:[]},employees:[{employee_id:'e1',display_name:'One',report_config:{clock_in:['reminder_cards'],clock_out:['reminder_cards'],reminder_cards:[card]}}]};
 w.omgSession={require:async()=>({accessToken:'x',sessionKind:'owner'})};w.omgWorkConfig.load=async()=>cfg;w.omgSupabase={rpc:async()=>({data:{ok:true,properties:[]}})};inline(w,html);await tick();
 assert.equal(w.document.querySelector('.card-editor .remove').textContent,'카드 삭제');w.document.querySelector('.card-editor .remove').click();assert.equal(w.document.querySelectorAll('.card-editor').length,0);assert.equal(w.testConfigs().e1.reminder_cards.length,0);assert.equal(w.testConfigs().e1.clock_in.includes('reminder_cards'),false);assert.equal(w.testConfigs().e1.clock_out.includes('reminder_cards'),false);w.testSync();assert.equal(w.testConfigs().e1.reminder_cards.length,0);dom.window.close();
 ({html,dom,w}=page('staff-management.html'));
 w.omgTransition={ready(){}};w.eval(read('warning-targets.js'));w.AccountChatPreferences={mount:async()=>{}};
 w.omgSession={require:async()=>({accessToken:'x',sessionKind:'owner'})};
 const staff={can_manage:true,employees:[{employee_id:'e1',display_name:'One'}],administrators:[]};
 const writes=[];let stored=[];
 w.omgWorkConfig={load:async()=>staff,loadEmployeeAttendanceSettings:async()=>({settings:[]}),loadAttendanceWarnings:async()=>({rules:stored}),saveAttendanceWarnings:async(token,rules)=>{writes.push(rules);stored=rules.map((rule,index)=>({...rule,rule_id:rule.rule_id||`r${index+1}`}));return {rules:stored};}};
 inline(w,html);await tick();
 let rows=w.document.querySelectorAll('.warning-rule');assert.equal(rows.length,1);assert.equal(rows[0].querySelector('.warning-label').textContent,'경고 조건 1');
 assert(!rows[0].querySelector('.warning-delete'));assert.equal(rows[0].querySelector('.warning-save').textContent,'설정 저장');
 assert.equal(w.getComputedStyle(rows[0].querySelector('.warning-body')).display,'none');assert.equal(w.getComputedStyle(w.document.getElementById('addWarning')).borderTopWidth,'0px');
 assert.equal(w.getComputedStyle(w.document.querySelector('.warning-settings')).paddingRight,'28px');
 rows[0].querySelector('.warning-toggle').click();assert.equal(rows[0].querySelector('.warning-toggle').getAttribute('aria-expanded'),'true');
 assert.equal(rows[0].querySelectorAll('.warning-choice > .warning-target-trigger').length,2);assert.equal(rows[0].querySelectorAll('.select-picker').length,0);
 rows[0].querySelector('.warning-save').click();await tick();assert.equal(writes.length,1);assert.deepEqual(Array.from(writes[0][0].employee_ids),[]);assert.equal(writes[0][0].target_all,false);assert.equal(rows[0].querySelector('.warning-status').textContent,'저장되었습니다.');
 w.document.getElementById('addWarning').click();rows=w.document.querySelectorAll('.warning-rule');assert.equal(rows.length,2);assert.equal(rows[1].querySelector('.warning-label').textContent,'경고 조건 2');assert.equal(rows[1].querySelector('.warning-delete').textContent,'설정 삭제');
 rows[1].querySelector('.warning-delete').click();await tick();rows=w.document.querySelectorAll('.warning-rule');assert.equal(rows.length,1);assert.equal(writes.at(-1).length,1);assert(!rows[0].querySelector('.warning-delete'));dom.window.close();
 ({dom,w}=page('messages.html'));const css=w.document.createElement('style');css.textContent=read('message-hub.css');w.document.head.append(css);const filter=w.document.createElement('div');filter.id='approvalFilter';w.document.body.append(filter);assert.equal(w.getComputedStyle(filter).borderTopWidth,'0px');assert.equal(w.getComputedStyle(filter).paddingTop,'0px');dom.window.close();
 console.log('PASS reminder deletion, compact numbered warning rows, single warning pickers, shared filter frame');
})().catch(error=>{console.error(error);process.exitCode=1});
