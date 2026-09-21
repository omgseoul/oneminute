package com.oneminute.guesthousemanager;

import android.content.Intent;
import androidx.core.content.ContextCompat;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.firestore.FirebaseFirestore;
import com.google.firebase.messaging.FirebaseMessaging;
import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

public class GuesthouseMessagingService extends FirebaseMessagingService {
    @Override
    public void onNewToken(String token) {
        String uid = FirebaseAuth.getInstance().getUid();
        if (uid != null) FirebaseFirestore.getInstance().collection("deviceTokens")
                .document(uid).update("token", token);

        String topic = getSharedPreferences("omg_push", MODE_PRIVATE).getString("topic", "");
        if (!topic.isEmpty()) FirebaseMessaging.getInstance().subscribeToTopic(topic);
    }

    @Override
    public void onMessageReceived(RemoteMessage message) {
        String mode = message.getData().get("mode");
        Intent service = new Intent(this, EmergencyAlarmService.class);
        if ("stop".equals(mode)) {
            service.setAction(EmergencyAlarmService.ACTION_STOP);
        } else {
            service.setAction(EmergencyAlarmService.ACTION_START);
            service.putExtra("alertId", message.getData().get("alertId"));
            service.putExtra("message", message.getData().get("message"));
            service.putExtra("mode", mode == null ? "urgent" : mode);
        }
        ContextCompat.startForegroundService(this, service);
    }
}
