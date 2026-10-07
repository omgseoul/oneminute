import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4';
import { createDocumentHandler } from './handler.mjs';
const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
Deno.serve(createDocumentHandler(db));
