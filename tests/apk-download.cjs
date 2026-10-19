const {JSDOM}=require('jsdom'),fs=require('fs'),assert=require('node:assert/strict');
async function check(apk_url,version_name='0.16.6'){
 const dom=new JSDOM('<a data-apk-download href="downloads/OMS-latest.apk">Install <span data-apk-version>old</span></a>',{url:'https://omgworks24.com/',runScripts:'outside-only'}),w=dom.window;
 w.fetch=async()=>({ok:true,json:async()=>({apk_url,version_name,version_code:1143})});w.eval(fs.readFileSync('apk-download.js','utf8'));await new Promise(setImmediate);const a=w.document.querySelector('a'),value={href:a.href,download:a.download,version:w.document.querySelector('span').textContent};w.close();return value;
}
(async()=>{
 const good=await check('https://omgworks24.com/downloads/OMS-0.16.6.apk');assert.equal(good.download,'OMS-0.16.6.apk');assert.equal(good.version,'0.16.6');assert.match(good.href,/OMS-0\.16\.6\.apk\?v=1143$/);
 for(const [url,version] of [['https://example.invalid/downloads/app.apk','0.16.6'],['https://omgworks24.com/elsewhere/app.apk','0.16.6'],['https://omgworks24.com/downloads/app.apk','../unsafe']]){const bad=await check(url,version);assert.equal(bad.download,'');assert.equal(bad.version,'old');}
 console.log('PASS: same-origin versioned APK link, visible version, download filename and unsafe manifest rejection');
})().catch(error=>{console.error(error);process.exitCode=1});
