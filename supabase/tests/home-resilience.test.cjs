const {test}=require('node:test'),assert=require('node:assert/strict'),{JSDOM,VirtualConsole}=require('jsdom'),fs=require('fs'),path=require('path');
const html=fs.readFileSync(process.env.HOME_TEST_HTML||path.join(__dirname,'../../app.html'),'utf8');
async function boot(mode){const d=new JSDOM(html.replace(/<script[\s\S]*?<\/script>/g,''),{url:'https://omgworks24.com/app.html',runScripts:'outside-only',virtualConsole:new VirtualConsole()}),w=d.window;
w.omgTransition={ready(){}};w.omgSession={require:async()=>({accessToken:'test',sessionKind:'owner',employeeName:'Owner',ownerId:'o'})};w.omgWorkConfig={load:async()=>({can_manage:true,property:{name:'Test',management_number:1}})};
w.omgSupabase={rpc:async()=>{if(mode==='summary')throw Error('summary failed');return{data:{ok:true,employees:[],messages:[],missions:[],properties:[]}}}};
w.omgPropertySelector={mount:async()=>{if(mode==='lookup')throw Error('lookup failed');if(mode==='hang')return new Promise(()=>{});return{selectedIds:()=>[]}}};if(mode==='native')w.OMGNative={registerPush(){throw Error('native bridge failed')}};
for(const m of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g))if(m[1].includes('let homeMessageTimer'))w.eval(m[1]);await new Promise(r=>setTimeout(r,40));return d;}
for(const mode of ['lookup','hang','native','summary'])test('owner navigation survives '+mode,async()=>{const d=await boot(mode),doc=d.window.document;try{assert(doc.querySelector('#appShell').classList.contains('ready'));assert.equal(doc.querySelector('#mainMenu').hasAttribute('inert'),false);for(const id of ['settings','accountManagement','attendanceManagement'])assert.equal(doc.getElementById(id).style.display,'flex');assert.equal(doc.querySelector('#messageMenu').getAttribute('href'),'messages.html');}finally{d.window.close()}});

test('owner home menu adds unread reports and shows weak arrival without sound',async()=>{
 const d=await boot('normal'),w=d.window;try{
  let reportCount=0,vibrations=[];w.HomeGuestCount={load:async()=>1};w.navigator.vibrate=pattern=>vibrations.push(pattern);
  w.omgSupabase.rpc=async name=>({data:name==='work_report_inbox'?{ok:true,unread_count:reportCount,reports:reportCount?[{report_id:'report',report_type:'clock_in',employee_name:'Worker',unread:true}]:[]}:{ok:true,can_manage:true,unread_count:2,messages:[]}});
  await w.loadMessageSummary('test',false);assert.equal(w.document.getElementById('messageCounter').textContent,'3');
  reportCount=1;await w.loadMessageSummary('test',true);assert.equal(w.document.getElementById('messageCounter').textContent,'4');assert.equal(w.document.querySelector('#messageArrival strong').textContent,'새 보고 도착');assert.equal(JSON.stringify(vibrations),"[[180]]");
 }finally{w.close();}
});

test('platform menu permission resolves before any home reveal',async()=>{
 const d=new JSDOM(html.replace(/<script[\s\S]*?<\/script>/g,''),{url:'https://omgworks24.com/app.html',runScripts:'outside-only',virtualConsole:new VirtualConsole()}),w=d.window;
 let resolvePermission,reveals=0;const permission=new Promise(r=>resolvePermission=r);
 w.omgTransition={ready(){reveals++;assert.equal(w.document.getElementById('platformAdmin').style.display,'flex');}};
 w.omgSession={require:async()=>({accessToken:'test',sessionKind:'owner',employeeName:'Owner',ownerId:'o'})};
 w.omgWorkConfig={load:async()=>({can_manage:true,property:{name:'Test',management_number:1}})};
 w.omgSupabase={rpc:async name=>name==='is_platform_administrator'?permission:{data:{ok:true,employees:[],messages:[],missions:[],properties:[]}}};
 w.omgPropertySelector={mount:async()=>({selectedIds:()=>[]})};
 for(const m of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g))if(m[1].includes('let homeMessageTimer'))w.eval(m[1]);
 await new Promise(r=>setTimeout(r,20));assert.equal(reveals,0);assert(!w.document.getElementById('appShell').classList.contains('ready'));
 resolvePermission({data:true});await new Promise(r=>setTimeout(r,30));assert.equal(reveals,1);assert(w.document.getElementById('appShell').classList.contains('ready'));w.close();
});
