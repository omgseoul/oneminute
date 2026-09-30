import nodemailer from 'npm:nodemailer@10.0.13';
import {createGuestEmailHandler} from './handler.mjs';
const env=(name:string)=>Deno.env.get(name);
Deno.serve(createGuestEmailHandler({env,sendMail:async(payload:Record<string,unknown>)=>{
 const port=Number(env('SMTP_PORT')||465);
 if(![465,587,2525].includes(port))throw Error('unsupported_smtp_port');
 const transport=nodemailer.createTransport({
  host:env('SMTP_HOST'),port,secure:port===465,requireTLS:true,
  auth:{user:env('SMTP_USER'),pass:env('SMTP_PASSWORD')},
  connectionTimeout:10000,greetingTimeout:10000,socketTimeout:20000,dnsTimeout:10000,
  disableFileAccess:true,disableUrlAccess:true,logger:false,debug:false,
 });
 try{return await transport.sendMail(payload);}finally{transport.close();}
}}));
