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

        String baseTopic = getSharedPreferences("omg_push", MODE_PRIVATE)
                .getString("base_topic", "");
        String memberTopic = getSharedPreferences("omg_push", MODE_PRIVATE)
                .getString("member_topic", "");
        if (!baseTopic.isEmpty()) FirebaseMessaging.getInstance().subscribeToTopic(baseTopic);
        if (!memberTopic.isEmpty()) FirebaseMessaging.getInstance().subscribeToTopic(memberTopic);
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
            service.putExtra("senderLabel", message.getData().get("senderLabel"));
        }
        ContextCompat.startForegroundService(this, service);
    }
}
