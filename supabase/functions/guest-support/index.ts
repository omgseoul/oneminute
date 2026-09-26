import { createGuestSupportHandler } from './handler.mjs';
Deno.serve(createGuestSupportHandler({env:(name:string)=>Deno.env.get(name)}));
