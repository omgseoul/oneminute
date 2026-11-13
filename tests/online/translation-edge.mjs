import assert from 'node:assert/strict';
import {createBedsHandler} from '../../supabase/functions/beds24/handler.mjs';
const p='00000000-0000-0000-0000-000000000001',token='00000000-0000-0000-0000-000000000002',id='00000000-0000-0000-0000-000000000003';
let calls=[],valid=true,operator=true,blocked=false;
const res=(v,status=200)=>new Response(JSON.stringify(v),{status});
const h=createBedsHandler({env:n=>({SUPABASE_URL:'https://test.supabase.co',SUPABASE_SERVICE_ROLE_KEY:'service'})[n],waitUntil:()=>{},fetcher:async(url,o={})=>{
 const b=o.body?JSON.parse(o.body):{};calls.push({url,b});
 if(url.endsWith('/auth/v1/user'))return res({id:'operator'});
 if(url.endsWith('/rpc/online_owner'))return res({ok:true,property_id:p});
 if(url.endsWith('/rpc/translation_control')){
  if(b.p_action==='platform_status'&&!operator)return res({code:'P0001',message:'운영센터 권한'},400);
  if(b.p_action==='latest_guest')return res({message_id:10});
  if(b.p_action==='claim')return res(blocked?{limit_reached:true}:{id,lease:id,key:'private-key',body:b.p_data.direction==='incoming'?'Bonjour':b.p_data.body,target:b.p_data.target||'ko'});
  if(b.p_action==='personal_key')return res({key:'old-secret-key-for-test',fingerprint:'hash'});
  return res({ok:true,usage:{limit:50000,used:10}});
 }
 if(url==='https://translation.googleapis.com/language/translate/v2')return valid?res({data:{translations:[{translatedText:'You&#39;re welcome &amp; safe',detectedSourceLanguage:'fr'}]}}):res({},403);
 throw Error('Unexpected request '+url);
}});
const request=(action,data={},platform=false)=>h(new Request('https://test.supabase.co/functions/v1/beds24',{method:'POST',body:JSON.stringify({action,data,...(platform?{platform_token:'jwt'}:{access_token:token})})}));
operator=false;await request('translation_save',{key:'new-secret-key-for-test'},true);assert(!calls.some(x=>x.url.includes('googleapis')),'platform authority checked before secret validation');
operator=true;calls=[];valid=false;await request('save_translation',{key:'new-secret-key-for-test'});assert(!calls.some(x=>x.b.p_action==='save_key'),'invalid candidate never replaces valid stored key');
valid=true;calls=[];let result=await(await request('translate_reply',{booking_id:20,body:'안녕하세요',target:'auto'})).json();assert.equal(result.target,'fr');assert.equal(result.text,"You're welcome & safe");assert.equal(calls.filter(x=>x.url.includes('googleapis')).length,2,'detect guest language by incoming translation then translate outgoing');assert(!calls.some(x=>x.url.includes('beds24.com')),'preview never sends a guest message');assert(!JSON.stringify(result).includes('private-key'));
blocked=true;calls=[];result=await(await request('translate',{message_id:10})).json();assert.equal(result.ok,false);assert(!calls.some(x=>x.url.includes('googleapis')),'quota denial never calls billed provider');
valid=false;calls=[];await request('check_translation');assert(calls.some(x=>x.b.p_action==='personal_check_result'&&x.b.p_data.status==='invalid'));
console.log('Translation Edge: operator auth, actual key validation, allowance denial, detected target and preview-only flow passed');
