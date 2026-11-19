import {createBriefingHandler} from './handler.mjs';
Deno.serve(createBriefingHandler({env:(name:string)=>Deno.env.get(name),waitUntil:(p:Promise<unknown>)=>EdgeRuntime.waitUntil(p)}));
