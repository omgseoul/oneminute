package com.oneminute.guesthousemanager;
import android.content.*;import com.google.firebase.auth.FirebaseAuth;import com.google.firebase.firestore.*;import java.util.*;
public class AcknowledgeReceiver extends BroadcastReceiver {
 @Override public void onReceive(Context c,Intent i){String id=i.getStringExtra("alertId");if(id!=null){Map<String,Object> u=new HashMap<>();u.put("acknowledged",true);u.put("acknowledgedBy",FirebaseAuth.getInstance().getUid());u.put("acknowledgedAt",FieldValue.serverTimestamp());FirebaseFirestore.getInstance().collection("alerts").document(id).update(u);}c.stopService(new Intent(c,EmergencyAlarmService.class));}
}
