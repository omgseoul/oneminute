const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
(async()=>{
 const w=new JSDOM('<div id="employees"><div data-employee-id="staff"><div class="employee-fields"></div></div></div>',{runScripts:'outside-only'}).window;
 const host=w.document.getElementById('employees'),row=host.firstElementChild,calls=[];let selected=['home'];
 w.omgSupabase={rpc:async(name,args)=>{assert.equal(name,'employee_cleaning_config');calls.push(args);if(args.p_action==='save')selected=args.p_property_ids;return {data:{ok:true,properties:[{id:'home',name:'One Minute'},{id:'other',name:'<img src=x>'}].map(p=>({...p,selected:selected.includes(p.id)}))}};}};
 w.eval(fs.readFileSync('employee-cleaning-settings.js','utf8'));const ui=w.EmployeeCleaningSettings;
 ui.mount(row,{});await ui.load(host,'owner');assert.equal(row.querySelectorAll('input:checked').length,1);assert.equal(row.querySelectorAll('img').length,0);
 const inputs=[...row.querySelectorAll('input')];inputs[1].click();await ui.save(host,'owner');assert.deepEqual([...selected],['home','other']);assert.equal(calls.at(-1).p_employee_id,'staff');
 await ui.save(host,'owner');assert.equal(calls.filter(x=>x.p_action==='save').length,1,'unchanged preferences do not write');
 const next=row.cloneNode(false);next.innerHTML='<div class="employee-fields"></div>';host.replaceChildren(next);ui.mount(next,{});await ui.load(host,'owner');assert.equal(next.querySelectorAll('input:checked').length,2,'saved choices survive a fresh render');
 for(const input of next.querySelectorAll('input'))input.click();await assert.rejects(()=>ui.save(host,'owner'),/1개 이상/);
 next.querySelector('input').click();w.omgSupabase.rpc=async()=>({error:{message:'권한이 없습니다.'}});await assert.rejects(()=>ui.save(host,'owner'),/권한/);
 w.close();console.log('Employee cleaning UI: safe labels, scoped persistence, fresh render, empty-selection validation and save failures passed');
})().catch(e=>{console.error(e);process.exit(1)});
