const vm=require('node:vm'),fs=require('node:fs'),assert=require('node:assert/strict');
const source=fs.readFileSync('supabase-client.js','utf8');
const token='00000000-0000-0000-0000-000000000001',other='00000000-0000-0000-0000-000000000002';
function setup(storage=new Map()){
 const redirects=[],binds=[],calls=[];let reply=async()=>({data:{ok:true,session_kind:'owner',status:'active',expires_at:'9999-12-31T23:59:59Z'}});
 const client={auth:{getSession:async()=>({data:{session:{}}}),signOut:async()=>{calls.push('signOut');}},rpc:(name,args)=>{calls.push(name);return reply(name,args);}};
 const window={OMG_SUPABASE:{url:'fixture',publishableKey:'fixture'},supabase:{createClient:()=>client},OMGNative:{bindAppSession:(...v)=>binds.push(v),clearPushSession:()=>calls.push('clearPush')}};
 const localStorage={getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)};
 vm.runInNewContext(source,{window,localStorage,location:{replace:v=>redirects.push(v)}});
 return {s:window.omgSession,a:window.omgAccount,storage,redirects,binds,calls,reply:fn=>reply=fn};
}
(async()=>{
 const t=setup();t.s.set({accessToken:token,sessionKind:'owner'});
 assert.equal((await t.s.require()).expiresAt,'9999-12-31T23:59:59Z');
 assert(Number.isFinite(Date.parse(t.binds.at(-1)[1])));
 const restart=setup(t.storage);assert.equal((await restart.s.require()).accessToken,token,'app restart retains login');
 for(const response of [{error:{message:'network'}},{data:null},{data:{ok:false,code:'temporary_failure'}},{data:{ok:true}}]){
  t.reply(async()=>response);await assert.rejects(()=>t.s.require(),/로그인 상태/);assert.equal(t.s.get().accessToken,token);assert.equal(t.redirects.length,0);
 }
 t.reply(async()=>{throw Error('offline')});await assert.rejects(()=>t.s.require());assert.equal(t.s.get().accessToken,token);
 let resolve; t.reply(()=>new Promise(r=>resolve=r));const pending=t.s.require();
 t.reply(async()=>({data:{ok:true}}));await t.s.logout();
 resolve({data:{ok:true,session_kind:'owner',status:'active'}});assert.equal(await pending,null);assert.equal(t.s.get(),null,'late success cannot undo explicit logout');
 t.s.set({accessToken:token});t.reply(()=>new Promise(r=>resolve=r));const old=t.s.require();t.s.set({accessToken:other});resolve({data:{ok:false,code:'invalid_session'}});assert.equal(await old,null);assert.equal(t.s.get().accessToken,other,'stale failure cannot log out new account');
 t.reply(async()=>({data:{ok:false,code:'invalid_session'}}));await t.s.require();assert.equal(t.s.get(),null);assert.equal(t.redirects.at(-1),'login.html');
 t.s.set({accessToken:token});t.reply(async()=>({data:{ok:true}}));await t.a.logout();assert(t.calls.indexOf('end_app_session')<t.calls.indexOf('signOut'),'account logout also revokes app session');
 const staff=setup();staff.s.set({accessToken:token});staff.reply(async()=>({data:{ok:true,session_kind:'staff',status:'completed'}}));assert(await staff.s.require({allowCompleted:true}));assert.equal(await staff.s.require(),null);
 console.log('PASS: restart/native expiry, offline and incomplete response preservation, explicit logout, delayed response/account-switch races, server revocation and completed staff handling');
})().catch(e=>{console.error(e);process.exitCode=1});
