import { Webhook } from 'npm:svix@2.6.0';
import { createGuestEmailHandler } from './handler.mjs';
Deno.serve(createGuestEmailHandler({
 env:(name:string)=>Deno.env.get(name),
 verifyWebhook:(raw:string,headers:Record<string,string>,secret:string)=>{
  new Webhook(secret).verify(raw,headers);
  return JSON.parse(raw);
 },
}));
