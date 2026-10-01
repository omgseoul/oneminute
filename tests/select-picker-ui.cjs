const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const dom=new JSDOM('<label for="employeeSelect">근무자</label><select id="employeeSelect"><option value="">전체</option></select>',{runScripts:'outside-only',url:'https://omgworks24.com'});
const w=dom.window;w.eval(fs.readFileSync('property-selector.js','utf8'));w.eval(fs.readFileSync('select-picker.js','utf8'));
const select=w.document.getElementById('employeeSelect'),control=w.omgSelectPicker.mount(select,{title:'근무자 선택',placeholder:'전체'});let changed=0;select.addEventListener('change',()=>changed++);
(async()=>{
 select.add(new w.Option('문정국','worker-1'));select.add(new w.Option('변지훈','worker-2'));await Promise.resolve();
 assert.equal(w.document.querySelectorAll('#employeeSelectPickerHost input[type=radio]').length,3);
 const choice=w.document.querySelector('#employeeSelectPickerHost input[value="worker-2"]');choice.checked=true;choice.dispatchEvent(new w.Event('change',{bubbles:true}));
 assert.equal(select.value,'worker-2');assert.equal(changed,1);assert.equal(w.document.querySelector('#employeeSelectPickerButton').textContent,'변지훈');
 select.value='worker-1';control.refresh();assert.equal(w.document.querySelector('#employeeSelectPickerButton').textContent,'문정국');
 const all=w.document.querySelector('#employeeSelectPickerHost input[value=""]');all.checked=true;all.dispatchEvent(new w.Event('change',{bubbles:true}));assert.equal(select.value,'');assert.equal(w.document.querySelector('#employeeSelectPickerButton').textContent,'전체');
 assert.equal(w.document.querySelector('label').htmlFor,'employeeSelectPickerButton');
 w.close();console.log('PASS modern selection keeps dynamic options, native change handlers and empty filter');
})().catch(error=>{console.error(error);w.close();process.exitCode=1});
