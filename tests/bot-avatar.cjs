const {JSDOM}=require('jsdom'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{webcrypto}=require('node:crypto'),{TextEncoder}=require('node:util');
const previous='data:image/webp;base64,'+fs.readFileSync(path.join(__dirname,'fixtures/bot-avatar-butler-v1.webp')).toString('base64');
const currentBytes=fs.readFileSync('bot-avatar-butler.webp'),current='data:image/webp;base64,'+currentBytes.toString('base64');
function setup(){
 const w=new JSDOM('',{url:'https://omgworks24.com/',runScripts:'outside-only'}).window;
 Object.defineProperty(w.crypto,'subtle',{value:webcrypto.subtle});w.TextEncoder=TextEncoder;
 let calls=0,fail=false;
 w.fetch=async url=>{calls++;assert.match(url,/bot-avatar-butler.webp\?v=20261021-logo$/);return {ok:!fail,blob:async()=>new w.Blob([currentBytes],{type:'image/webp'})};};
 w.eval(fs.readFileSync('bot-avatar.js','utf8'));
 return {avatar:w.OMSBotAvatar,calls:()=>calls,fail:value=>fail=value};
}
(async()=>{
 const {avatar,calls}=setup();
 assert.equal(await avatar.upgrade(null),null);assert.equal(await avatar.upgrade(''),'', 'no portrait keeps default semantics');
 assert.equal(await avatar.upgrade('data:image/jpeg;base64,custom'),'data:image/jpeg;base64,custom');
 assert.equal(await avatar.upgrade('data:image/webp;base64,custom'),'data:image/webp;base64,custom','custom uploads are never replaced');
 assert.equal(await avatar.upgrade(current),current);assert.equal(calls(),0);
 assert.deepEqual(await Promise.all([avatar.upgrade(previous),avatar.upgrade(previous)]),[current,current]);assert.equal(calls(),1,'concurrent upgrades share one asset read');
 assert.equal(await avatar.butlerImage(),current);assert.equal(calls(),1,'picker and upgraded profiles use identical bytes');
 const retry=setup();retry.fail(true);assert.equal(await retry.avatar.upgrade(previous),previous,'network failure keeps the existing photo');retry.fail(false);assert.equal(await retry.avatar.upgrade(previous),current);assert.equal(retry.calls(),2,'failed asset loads can retry');
 console.log('PASS: exact legacy butler upgrade, custom/default preservation, shared picker bytes, failed-load fallback and retry.');
})().catch(error=>{console.error(error);process.exitCode=1;});
