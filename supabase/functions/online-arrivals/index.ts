import {createArrivalHandler} from './handler.mjs';
Deno.serve(createArrivalHandler({env:(name:string)=>Deno.env.get(name),waitUntil:(p:Promise<unknown>)=>EdgeRuntime.waitUntil(p)}));
