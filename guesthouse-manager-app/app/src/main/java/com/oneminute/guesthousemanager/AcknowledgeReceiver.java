package com.oneminute.guesthousemanager;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import androidx.core.content.ContextCompat;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.firestore.FieldValue;
import com.google.firebase.firestore.FirebaseFirestore;
import java.util.HashMap;
import java.util.Map;

public class AcknowledgeReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String id = intent.getStringExtra("alertId");
        if (id != null && !id.isEmpty()) {
            Map<String, Object> update = new HashMap<>();
            update.put("acknowledged", true);
            update.put("acknowledgedBy", FirebaseAuth.getInstance().getUid());
            update.put("acknowledgedAt", FieldValue.serverTimestamp());
            FirebaseFirestore.getInstance().collection("alerts").document(id).update(update);
        }
        Intent stop = new Intent(context, EmergencyAlarmService.class)
                .setAction(EmergencyAlarmService.ACTION_STOP);
        ContextCompat.startForegroundService(context, stop);
    }
}
