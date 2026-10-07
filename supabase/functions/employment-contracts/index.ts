import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.57.4';
import {PDFDocument,rgb} from 'https://esm.sh/pdf-lib@1.17.1';
import fontkit from 'https://esm.sh/@pdf-lib/fontkit@1.1.1';
import {createContractHandler} from './handler.mjs';
import {createContractPdfRenderer} from './pdf.mjs';
const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
Deno.serve(createContractHandler({db,pdf:createContractPdfRenderer({PDFDocument,rgb,fontkit})}));
