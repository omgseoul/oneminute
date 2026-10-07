const cors={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'apikey, authorization, content-type','Access-Control-Allow-Methods':'POST, OPTIONS'};
const reply=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,'Content-Type':'application/json','Cache-Control':'no-store'}});
const uuid=(x)=>typeof x==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(x);
export const createDocumentHandler = (db) => async req=>{
 if(req.method==='OPTIONS')return new Response(null,{headers:cors});
 if(req.method!=='POST')return reply({ok:false,message:'허용되지 않는 요청입니다.'},405);
 try{
  if(Number(req.headers.get('content-length')||0)>11*1024*1024)return reply({ok:false,message:'10MB 이하의 PDF만 보관할 수 있습니다.'},413);
  const multipart=req.headers.get('content-type')?.includes('multipart/form-data');
  const form=multipart?await req.formData():null;
  const body=form?Object.fromEntries(form):await req.json();
  if(!uuid(body.access_token)||!uuid(body.employee_id))return reply({ok:false,message:'관리자 로그인이 필요합니다.'},401);
  const {data:property,error:authError}=await db.rpc('authorize_employee_documents',{p_access_token:body.access_token,p_employee_id:body.employee_id});
  if(authError||!property)return reply({ok:false,message:'해당 근무자의 문서에 접근할 권한이 없습니다.'},403);
  const bucket=db.storage.from('employee-documents');
  if(body.action==='list'){
   const {data,error}=await db.from('employee_documents').select('id,filename,size,created_at').eq('employee_id',body.employee_id).order('created_at',{ascending:false});
   if(error)throw error;return reply({ok:true,documents:data});
  }
  if(body.action==='upload'){
   const file=form?.get('file');
   if(!(file instanceof File)||file.size<5||file.size>10485760||!file.name.toLowerCase().endsWith('.pdf'))return reply({ok:false,message:'10MB 이하의 PDF를 선택해주세요.'},400);
   const bytes=new Uint8Array(await file.arrayBuffer());
   if(new TextDecoder().decode(bytes.slice(0,5))!=='%PDF-')return reply({ok:false,message:'올바른 PDF 파일이 아닙니다.'},400);
   const path=`${property}/${body.employee_id}/${crypto.randomUUID()}.pdf`;
   const filename=file.name.replace(/[\x00-\x1f/\\]/g,'_').slice(0,200);
   const {error:uploadError}=await bucket.upload(path,bytes,{contentType:'application/pdf',upsert:false});if(uploadError)throw uploadError;
   const {error}=await db.from('employee_documents').insert({employee_id:body.employee_id,filename,object_path:path,size:file.size});
   if(error){await bucket.remove([path]);throw error;}return reply({ok:true});
  }
  if(!['open','delete'].includes(body.action)||!uuid(body.document_id))return reply({ok:false,message:'문서 요청을 확인해주세요.'},400);
  const {data:doc,error}=await db.from('employee_documents').select('id,object_path').eq('id',body.document_id).eq('employee_id',body.employee_id).maybeSingle();
  if(error)throw error;if(!doc)return reply({ok:false,message:'문서를 찾을 수 없습니다.'},404);
  if(body.action==='open'){const {data,error}=await bucket.createSignedUrl(doc.object_path,60);if(error)throw error;return reply({ok:true,url:data.signedUrl});}
  const removed=await bucket.remove([doc.object_path]);if(removed.error)throw removed.error;
  const deleted=await db.from('employee_documents').delete().eq('id',doc.id).eq('employee_id',body.employee_id);if(deleted.error)throw deleted.error;
  return reply({ok:true});
 }catch(error){console.error('employee-documents operation failed',error instanceof Error?error.name:'storage');return reply({ok:false,message:'문서 처리에 실패했습니다. 잠시 후 다시 시도해주세요.'},500);}
};
