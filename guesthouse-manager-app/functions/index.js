const {onDocumentCreated}=require("firebase-functions/v2/firestore");
const {onRequest}=require("firebase-functions/v2/https");
const {defineSecret}=require("firebase-functions/params");
const {initializeApp}=require("firebase-admin/app");
const {getFirestore}=require("firebase-admin/firestore");
const {getMessaging}=require("firebase-admin/messaging");
initializeApp();
const telegramUrgentSecret=defineSecret("TELEGRAM_URGENT_SECRET");
const SUPABASE_RPC_URL="https://rfcozgyvupvachhhblzn.supabase.co/rest/v1/rpc/get_message_push_dispatch";
const SUPABASE_PUBLISHABLE_KEY="sb_publishable_Gy0_TtIcJ6xKDEiGWEnXAg_f4_eyXPI";
const APP_ORIGINS=new Set(["https://omgworks24.com","https://www.omgworks24.com","https://omgseoul.github.io"]);
function setAppCors(req,res){const origin=req.get("origin");if(APP_ORIGINS.has(origin))res.set("Access-Control-Allow-Origin",origin);res.set("Vary","Origin");res.set("Access-Control-Allow-Headers","Content-Type");res.set("Access-Control-Allow-Methods","POST, OPTIONS");}
function safeTopicPart(value){return String(value||"").replace(/[^A-Za-z0-9_.~-]/g,"_");}
exports.sendUrgentAlert=onDocumentCreated({document:"alerts/{alertId}",region:"asia-northeast3"},async event=>{
 const alert=event.data.data(); const snap=await getFirestore().collection("deviceTokens").where("role","==",alert.targetRole||"owner").get();
 const tokens=snap.docs.map(d=>d.data().token).filter(Boolean); if(!tokens.length)return;
 await getMessaging().sendEachForMulticast({tokens,data:{alertId:event.params.alertId,message:String(alert.message||"긴급 메시지")},android:{priority:"high"}});
});

exports.telegramUrgent=onRequest({region:"asia-northeast3",secrets:[telegramUrgentSecret]},async(req,res)=>{
 if(req.method!=="POST"){res.status(405).json({ok:false,message:"POST only"});return;}
 if(req.get("x-webhook-secret")!==telegramUrgentSecret.value()){res.status(401).json({ok:false,message:"Unauthorized"});return;}
 const body=req.body||{};
 const source=typeof body.message==="object"?body.message:{};
  const raw=String(body.text||body.message_text||(typeof body.message==="string"?body.message:source.text)||"").trim();
  const propertyId=String(body.property_id||body.propertyId||"").trim();
 if(!raw.startsWith("!!")){res.status(200).json({ok:true,ignored:true});return;}
 if(!propertyId){res.status(400).json({ok:false,message:"property_id is required"});return;}
 const safeProperty=propertyId.replace(/[^A-Za-z0-9_.~-]/g,"_");
 let mode="urgent",message=raw.slice(2).trim();
 if(raw.startsWith("!!테스트")){mode="test";message=message||"긴급알림 테스트";}
 if(raw.startsWith("!!정지")){mode="stop";message="긴급알림을 중지합니다.";}
 const alertId=String(body.update_id||source.message_id||Date.now());
 await getMessaging().send({topic:`property_${safeProperty}_staff`,data:{alertId,message:message||"사장님 긴급메시지",mode},android:{priority:"high"}});
 res.status(200).json({ok:true,mode});
});

exports.appUrgent=onRequest({region:"asia-northeast3"},async(req,res)=>{
 setAppCors(req,res);
 if(req.method==="OPTIONS"){res.status(204).send("");return;}
 if(req.method!=="POST"){res.status(405).json({ok:false,message:"POST only"});return;}
 const accessToken=String(req.body?.access_token||"").trim();
 const messageId=String(req.body?.message_id||"").trim();
 if(!/^[0-9a-f-]{36}$/i.test(accessToken)||!/^[0-9a-f-]{36}$/i.test(messageId)){
  res.status(400).json({ok:false,message:"잘못된 긴급 메세지 요청입니다."});return;
 }
 try{
  const rpcResponse=await fetch(SUPABASE_RPC_URL,{method:"POST",headers:{apikey:SUPABASE_PUBLISHABLE_KEY,"Content-Type":"application/json"},body:JSON.stringify({p_access_token:accessToken,p_message_id:messageId})});
  const dispatch=await rpcResponse.json().catch(()=>null);
  if(!rpcResponse.ok||!dispatch?.ok){res.status(rpcResponse.status||400).json({ok:false,message:dispatch?.message||"긴급 메세지를 확인하지 못했습니다."});return;}
  if(dispatch.ignored){res.status(200).json({ok:true,ignored:true});return;}
  const property=safeTopicPart(dispatch.management_number);
  const topics=[];
  for(const employeeId of dispatch.recipient_employee_ids||[])topics.push(`property_${property}_employee_${safeTopicPart(employeeId)}`);
  for(const ownerId of dispatch.recipient_owner_ids||[])topics.push(`property_${property}_owner_${safeTopicPart(ownerId)}`);
  const uniqueTopics=[...new Set(topics)];
  await Promise.all(uniqueTopics.map(topic=>getMessaging().send({topic,data:{alertId:String(dispatch.message_id),message:String(dispatch.message||"긴급 메세지"),mode:"urgent",senderLabel:String(dispatch.sender_label||"사장님")},android:{priority:"high"}})));
  res.status(200).json({ok:true,sent:uniqueTopics.length});
 }catch(error){console.error("appUrgent failed",error);res.status(500).json({ok:false,message:"긴급 알림 전송 중 오류가 발생했습니다."});}
});
