package com.oneminute.guesthousemanager;
import android.content.Intent; import com.google.firebase.messaging.*; import com.google.firebase.auth.FirebaseAuth; import com.google.firebase.firestore.FirebaseFirestore; import java.util.*;
public class GuesthouseMessagingService extends FirebaseMessagingService {
 @Override public void onNewToken(String token){String uid=FirebaseAuth.getInstance().getUid();if(uid!=null)FirebaseFirestore.getInstance().collection("deviceTokens").document(uid).update("token",token);}
 @Override public void onMessageReceived(RemoteMessage m){Intent i=new Intent(this,EmergencyAlarmService.class);i.putExtra("alertId",m.getData().get("alertId"));i.putExtra("message",m.getData().get("message"));startForegroundService(i);}
}
