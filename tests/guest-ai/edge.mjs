import assert from 'node:assert/strict';
import {createGuestAIHandler,buildRequest,validateAnswer,emergencyHint,MODEL} from '../../supabase/functions/guest-ai/handler.mjs';
const job={id:'fixture-job',lease_id:'fixture-lease',prompt:'정중한 말투',data:[{id:'1',title:'위치',answer:'종로8길15 4층'},{id:'2',title:'체크인',answer:'15시'}],history:[{role:'user',content:'거기가 어디예요? 체크인은 언제 가능한가요?'}]};
const answer={reply:'종로8길15 4층에 있으며, 체크인은 오후 3시부터 가능합니다.',disposition:'answer',reason:'위치와 체크인 안내',parts:[{question:'위치',sources:['1'],needs_human:false},{question:'체크인',sources:['2'],needs_human:false}]};
const request=buildRequest(job);assert.equal(request.model,MODEL);assert.equal(request.store,false);assert.equal(request.text.format.strict,true);assert(request.input[0].content.includes('EACH question'));assert(request.input[1].content.includes('체크인'));assert.equal(validateAnswer(answer,job).reply,answer.reply);
const partial={...answer,disposition:'handoff',reply:'위치는 종로8길15 4층입니다. 주차는 직원 확인이 필요합니다.',parts:[answer.parts[0],{question:'주차',sources:[],needs_human:true}]};assert.equal(validateAnswer(partial,job).disposition,'handoff');assert.throws(()=>validateAnswer({...partial,disposition:'answer'},job));assert.throws(()=>validateAnswer({...answer,parts:[{question:'위치',sources:['other-property'],needs_human:false}]},job));assert.throws(()=>validateAnswer(answer,{...job,has_attachment:true}));assert(emergencyHint('가스 냄새가 나요'));assert(!emergencyHint('체크인은 몇 시인가요?'));
const env=n=>({SUPABASE_URL:'https://fixture.supabase.co',SUPABASE_SERVICE_ROLE_KEY:'server-only-fixture',PUSH_ADMIN_SECRET:'internal-fixture'}[n]);
function setup({provider='ok',jobOverride={},output=answer,operator=true}={}){let claimed=false,calls=[],settled,background;const fetcher=async(url,options={})=>{calls.push({url,options});const body=options.body?JSON.parse(options.body):{};const res=(v,status=200)=>new Response(JSON.stringify(v),{status});
 if(url.endsWith('/auth/v1/user'))return res({id:'00000000-0000-0000-0000-000000000001'});
 if(url.endsWith('/guest_ai_platform'))return operator?res({ok:true,provider:{ready:true}}):res({code:'P0001',message:'운영센터 권한이 필요합니다.'},400);
 if(url.includes('/v1/models/'))return res({id:MODEL});
 if(url.endsWith('/guest_ai_claim')){if(claimed)return res({empty:true});claimed=true;return res({...job,...jobOverride});}
 if(url.endsWith('/guest_ai_credentials'))return res({enabled:true,key:'sk-fixture_not_real_secret'});
 if(url==='https://api.openai.com/v1/responses'){if(provider==='timeout')throw Error('network timeout');if(provider==='rejected')return res({},429);if(provider==='truncated')return new Response('{',{status:200});return res({id:'resp-fixture',status:'completed',usage:{input_tokens:1000,output_tokens:100,input_tokens_details:{cached_tokens:100,cache_write_tokens:200}},output:[{type:'message',content:[{type:'output_text',text:JSON.stringify(output)}]}]});}
 if(url.endsWith('/guest_ai_finish')){settled=body.p_result;return res({ok:true,event_id:body.p_result.disposition==='answer'?null:'event-fixture'});}
 if(url.endsWith('/guest_ai_pending_alerts'))return res([]);
 if(url.includes('/dispatch-notification/'))return res({ok:true});
 if(url.endsWith('/guest_ai_verify_worker'))return res(false);
 throw Error('Unexpected mock path '+url);
 };const handler=createGuestAIHandler({env,fetcher,waitUntil:p=>background=p});return {handler,calls,get settled(){return settled;},async run(){const r=await handler(new Request('https://fixture.supabase.co/functions/v1/guest-ai/worker',{method:'POST',headers:{'x-webhook-secret':'internal-fixture'}}));assert.equal(r.status,202);await background;}};}
let t=setup();await t.run();assert.equal(t.settled.reply,answer.reply);assert.equal(t.settled.cache_write_tokens,200);assert.equal(t.calls.filter(c=>c.url==='https://api.openai.com/v1/responses').length,1);
t=setup({output:partial});await t.run();assert.equal(t.settled.disposition,'handoff');assert(t.calls.some(c=>c.url.includes('/dispatch-notification/')));
t=setup({provider:'timeout'});await t.run();assert(t.settled.estimated);assert.equal(t.settled.disposition,'handoff');
t=setup({provider:'truncated'});await t.run();assert(t.settled.estimated,'truncated successful body cannot silently release reserved cost');
t=setup({provider:'rejected'});await t.run();assert.equal(t.settled.estimated,false);
t=setup({jobOverride:{history:[{role:'user',content:'방에 불이 났어요'}]}});await t.run();assert.equal(t.settled.disposition,'urgent');assert(!t.calls.some(c=>c.url==='https://api.openai.com/v1/responses'),'obvious emergency escalates without paid call');
t=setup();assert.equal((await t.handler(new Request('https://fixture.supabase.co/functions/v1/guest-ai/worker',{method:'POST'}))).status,401);assert(!t.calls.length);
const connect=()=>new Request('https://fixture.supabase.co/functions/v1/guest-ai',{method:'POST',headers:{'Content-Type':'application/json',origin:'https://omgworks24.com'},body:JSON.stringify({action:'connect',platform_token:'fixture-jwt',data:{key:'sk-test_only_not_real_api_key'}})});
t=setup({operator:false});assert.equal((await t.handler(connect())).status,400);assert(!t.calls.some(c=>c.url.includes('api.openai.com')),'nonoperator must not trigger provider verification');
t=setup();assert.equal((await t.handler(connect())).status,200);assert(t.calls.some(c=>c.url.includes('/v1/models/')));assert(!t.calls.some(c=>c.url.endsWith('/v1/responses')),'connecting key is not a billable generation');
console.log('PASS edge: multi-question and partial grounding, source validation, emergency, one paid call, token accounting, timeout handling, worker auth, operator-only API connection');
