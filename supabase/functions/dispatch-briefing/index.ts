import {createBriefingDispatch} from './handler.mjs';
Deno.serve(createBriefingDispatch({env:(name:string)=>Deno.env.get(name)}));
