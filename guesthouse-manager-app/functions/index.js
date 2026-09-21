const {onDocumentCreated}=require("firebase-functions/v2/firestore");
const {onRequest}=require("firebase-functions/v2/https");
const {defineSecret}=require("firebase-functions/params");
const {initializeApp}=require("firebase-admin/app");
const {getFirestore}=require("firebase-admin/firestore");
const {getMessaging}=require("firebase-admin/messaging");
initializeApp();
const telegramUrgentSecret=defineSecret("TELEGRAM_URGENT_SECRET");
exports.sendUrgentAlert=onDocumentCreated({document:"alerts/{alertId}",region:"asia-northeast3"},async event=>{
 const alert=event.data.data(); const snap=await getFirestore().collection("deviceTokens").where("role","==",alert.targetRole||"owner").get();
 const tokens=snap.docs.map(d=>d.data().token).filter(Boolean); if(!tokens.length)return;
 await getMessaging().sendEachForMulticast({tokens,data:{alertId:event.params.alertId,message:String(alert.message||"긴급 메시지")},android:{priority:"high"}});
});

exports.telegramUrgent=onRequest({region:"asia-northeast3",secrets:[telegramUrgentSecret]},async(req,res)=>{
 if(req.method!=="POST"){res.status(405).json({ok:false,message:"POST only"});return;}
 if(req.get("x-omg-secret")!==telegramUrgentSecret.value()){res.status(401).json({ok:false,message:"Unauthorized"});return;}
 const body=req.body||{};
 const source=typeof body.message==="object"?body.message:{};
 const raw=String(body.text||body.message_text||source.text||"").trim();
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
