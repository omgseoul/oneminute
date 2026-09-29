const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const {JSDOM,VirtualConsole}=require('jsdom');
const source=fs.readFileSync('home-navigation.js','utf8');
function setup(native=true){
 const dom=new JSDOM('<nav id="mainMenu"><a href="messages.html"><span>메세지</span></a></nav>',{url:'https://omgworks24.com/app.html',runScripts:'outside-only',virtualConsole:new VirtualConsole()});
 const w=dom.window,jobs=new Map();let id=0;
 w.setTimeout=fn=>{jobs.set(++id,fn);return id;};w.clearTimeout=id=>jobs.delete(id);
 if(native)w.OMGNative={};w.eval(source);
 const fire=(type,props={})=>{const e=new w.MouseEvent(type,{bubbles:true,cancelable:true,button:0,clientX:20,clientY:20,...props});w.document.querySelector('span').dispatchEvent(e);return e;};
 const tick=()=>{const current=[...jobs.values()];jobs.clear();current.forEach(fn=>fn());};
 return {w,fire,tick,jobs,dom};
}
test('normal click is not cancelled and successful page departure cancels recovery',()=>{
 const c=setup();assert.equal(c.fire('click').defaultPrevented,false);c.w.dispatchEvent(new c.w.Event('pagehide'));c.tick();assert.equal(c.jobs.size,0);assert.equal(c.w.document.querySelector('[role=dialog]'),null);c.dom.window.close();
});
test('blocked navigation retries then reports a path without query secrets',()=>{
 const c=setup();c.w.document.querySelector('a').href='messages.html?token=private';c.fire('click');c.tick();assert.equal(c.w.document.querySelector('[role=dialog]'),null);c.tick();const text=c.w.document.querySelector('[data-nav-code]').textContent;assert.match(text,/클릭 후 이동 미완료/);assert(!text.includes('private'));c.dom.window.close();
});
test('tap without a click reports independently, while cancelled scroll does not',()=>{
 const c=setup();c.fire('pointerdown');c.fire('pointercancel');c.fire('pointerup');c.tick();assert.equal(c.w.document.querySelector('[role=dialog]'),null);c.fire('pointerdown');c.fire('pointerup');c.tick();assert.match(c.w.document.querySelector('[data-nav-code]').textContent,/터치 후 클릭 없음/);c.dom.window.close();
});
test('ordinary browser has no recovery handlers',()=>{const c=setup(false);c.fire('click');assert.equal(c.jobs.size,0);c.dom.window.close();});
test('deployed inline code matches tested source and menu is not initially inert',()=>{const html=fs.readFileSync('app.html','utf8');assert(html.includes('<script id="nativeNavigationRecovery">\n'+source+'</script>'));assert(!/<nav[^>]+\binert\b/.test(html));});
