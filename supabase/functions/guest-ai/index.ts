import {createGuestAIHandler} from './handler.mjs';
Deno.serve(createGuestAIHandler({env:(name:string)=>Deno.env.get(name),waitUntil:(promise:Promise<unknown>)=>EdgeRuntime.waitUntil(promise)}));
