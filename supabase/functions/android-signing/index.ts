import { createRemoteJWKSet, jwtVerify } from 'npm:jose@6.1.0';
import { allowedBuild } from './authorization.mjs';
const issuer='https://token.actions.githubusercontent.com';
const keys=createRemoteJWKSet(new URL(issuer+'/.well-known/jwks'));
const headers={'Content-Type':'application/json','Cache-Control':'no-store'};
Deno.serve(async req=>{
 if(req.method!=='POST')return new Response(JSON.stringify({ok:false}),{status:405,headers});
 try{
  const token=req.headers.get('authorization')?.replace(/^Bearer /,'')||'';
  if(token.length>16000)throw Error('invalid token');
  const {payload}=await jwtVerify(token,keys,{issuer,audience:'https://omgworks24.com/android-signing',algorithms:['RS256'],maxTokenAge:'10m',clockTolerance:5});
  if(!allowedBuild(payload))return new Response(JSON.stringify({ok:false,message:'Approved OMS build required.'}),{status:403,headers});
  const secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,url=Deno.env.get('SUPABASE_URL')!;
  const result=await fetch(url+'/rest/v1/rpc/android_signing_material',{method:'POST',headers:{'Content-Type':'application/json',apikey:secret,Authorization:'Bearer '+secret},body:JSON.stringify({p_jti:payload.jti,p_run_id:String(payload.run_id),p_commit_sha:payload.sha})});
  if(!result.ok)throw Error('signing unavailable');
  const material=await result.json();if(!material?.store_base64)throw Error('signing unavailable');
  return new Response(JSON.stringify(material),{headers});
 }catch{return new Response(JSON.stringify({ok:false,message:'Signing authorization failed.'}),{status:401,headers});}
});
