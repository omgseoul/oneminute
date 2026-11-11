const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const pages=['index.html','feature-staff.html','feature-tasks.html','feature-cleaning.html','feature-messenger.html'];
const tick=()=>new Promise(r=>setTimeout(r,10));
const text=w=>{const walker=w.document.createTreeWalker(w.document.body,w.NodeFilter.SHOW_TEXT);let out='';while(walker.nextNode()){const n=walker.currentNode;if(!n.parentElement.closest('script,style,[data-site-language]'))out+=n.nodeValue;}return out;};
(async()=>{for(const file of pages){
 const dom=new JSDOM(fs.readFileSync(file,'utf8'),{url:'https://omgworks24.com/'+file,runScripts:'outside-only'}),w=dom.window;
 const original=text(w);w.eval(fs.readFileSync('site-language.js','utf8'));await tick();
 const picker=w.document.querySelector('[data-site-language]');assert.deepEqual([...picker.options].map(o=>o.textContent),['한국어','English']);
 picker.value='en';picker.dispatchEvent(new w.Event('change',{bubbles:true}));await tick();
 assert.equal(w.document.documentElement.lang,'en');assert(!/[가-힣]/.test(text(w)),file+' must translate all visible copy');
 for(const el of w.document.querySelectorAll('[aria-label],img[alt],meta[name=description],title')){if(el.matches('[data-site-language]'))continue;assert(!/[가-힣]/.test([el.getAttribute('aria-label'),el.getAttribute('alt'),el.getAttribute('content'),el.tagName==='TITLE'?el.textContent:''].join('')),file+' accessible copy');}
 assert.equal(w.localStorage.getItem('oms.public.language'),'en');
 assert(w.document.querySelector('a[href*="index.html"],a[href*="feature-staff.html"]').href.includes('lang=en'));
 picker.value='ko';picker.dispatchEvent(new w.Event('change',{bubbles:true}));await tick();assert.equal(text(w),original,file+' restores exact Korean text');assert(!w.location.search.includes('lang=en'));
 dom.window.close();
}
 const dom=new JSDOM('<select data-site-language><option value="ko">한국어</option><option value="en">English</option></select><b id="state">미확인</b>',{url:'https://omgworks24.com/feature-messenger.html?lang=en',runScripts:'outside-only'}),w=dom.window;
 Object.defineProperty(w,'localStorage',{get(){throw Error('blocked')}});w.eval(fs.readFileSync('site-language.js','utf8'));await tick();assert.equal(w.document.querySelector('#state').textContent,'Unconfirmed');w.document.querySelector('#state').textContent='확인 완료';await tick();assert.equal(w.document.querySelector('#state').textContent,'Acknowledged');const p=w.document.querySelector('select');p.value='ko';p.dispatchEvent(new w.Event('change',{bubbles:true}));await tick();assert.equal(w.document.querySelector('#state').textContent,'확인 완료');w.close();console.log('PASS all 5 public pages: complete English and accessible copy, exact Korean restoration, persisted selection, links, live demo updates and blocked storage');
})().catch(e=>{console.error(e);process.exit(1)});
