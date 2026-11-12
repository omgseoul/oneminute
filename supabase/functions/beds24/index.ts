import {createBedsHandler} from './handler.mjs';
Deno.serve(createBedsHandler({env:(name:string)=>Deno.env.get(name),waitUntil:(p:Promise<unknown>)=>EdgeRuntime.waitUntil(p)}));
