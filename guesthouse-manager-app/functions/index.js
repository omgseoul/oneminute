const {onDocumentCreated}=require("firebase-functions/v2/firestore");
const {initializeApp}=require("firebase-admin/app");
const {getFirestore}=require("firebase-admin/firestore");
const {getMessaging}=require("firebase-admin/messaging");
initializeApp();
exports.sendUrgentAlert=onDocumentCreated({document:"alerts/{alertId}",region:"asia-northeast3"},async event=>{
 const alert=event.data.data(); const snap=await getFirestore().collection("deviceTokens").where("role","==",alert.targetRole||"owner").get();
 const tokens=snap.docs.map(d=>d.data().token).filter(Boolean); if(!tokens.length)return;
 await getMessaging().sendEachForMulticast({tokens,data:{alertId:event.params.alertId,message:String(alert.message||"긴급 메시지")},android:{priority:"high"}});
});
