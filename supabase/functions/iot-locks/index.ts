import {createIotHandler} from './handler.mjs';
Deno.serve(createIotHandler({env:(name:string)=>Deno.env.get(name),waitUntil:(p:Promise<unknown>)=>EdgeRuntime.waitUntil(p)}));
