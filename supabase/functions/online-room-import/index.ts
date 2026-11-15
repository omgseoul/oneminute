import {createRoomImportHandler} from './handler.mjs';
Deno.serve(createRoomImportHandler({env:(name:string)=>Deno.env.get(name)}));
