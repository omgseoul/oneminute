package com.oneminute.guesthousemanager;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.graphics.Color;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import androidx.core.app.NotificationCompat;
import androidx.core.content.ContextCompat;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.firestore.FirebaseFirestore;
import com.google.firebase.messaging.FirebaseMessaging;
import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

public class GuesthouseMessagingService extends FirebaseMessagingService {
    private static final String MESSAGE_CHANNEL_ID = "property_messages_popup_v2";
    private static final String NORMAL_MESSAGE_PREFIX = "[[OMG_NORMAL_MESSAGE]]";
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
        String body = message.getData().get("message");
        if ("message".equals(mode) || (body != null && body.startsWith(NORMAL_MESSAGE_PREFIX))) {
            showMessageNotification(message);
            return;
        }
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

    private void showMessageNotification(RemoteMessage remote) {
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager == null) return;
        Uri sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION);
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel channel = new NotificationChannel(MESSAGE_CHANNEL_ID,
                    "새 메세지", NotificationManager.IMPORTANCE_HIGH);
            channel.setDescription("사장님과 직원이 주고받는 새 메세지 알림");
            channel.enableVibration(true);
            channel.setVibrationPattern(new long[]{0, 220, 100, 260});
            channel.setSound(sound, new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build());
            channel.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
            manager.createNotificationChannel(channel);
        }

        String alertId = remote.getData().get("alertId");
        String sender = remote.getData().get("senderLabel");
        String body = remote.getData().get("message");
        if (body != null && body.startsWith(NORMAL_MESSAGE_PREFIX))
            body = body.substring(NORMAL_MESSAGE_PREFIX.length());
        if (sender == null || sender.trim().isEmpty()) sender = "새 메세지";
        if (body == null || body.trim().isEmpty()) body = "메세지 메뉴에서 확인해주세요.";

        int requestCode = (alertId == null ? body : alertId).hashCode();
        Intent screen = new Intent(this, MessageAlertActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                        | Intent.FLAG_ACTIVITY_CLEAR_TOP
                        | Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra("alertId", alertId)
                .putExtra("senderLabel", sender)
                .putExtra("message", body)
                .putExtra("notificationId", requestCode);
        PendingIntent fullScreen = PendingIntent.getActivity(this, requestCode, screen,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Intent open = new Intent(this, AttendanceActivity.class)
                .setData(Uri.parse("https://omgworks24.com/messages.html"))
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent content = PendingIntent.getActivity(this, requestCode, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification notification = new NotificationCompat.Builder(this, MESSAGE_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_email)
                .setColor(Color.rgb(36, 103, 189))
                .setContentTitle("새 메세지 도착")
                .setContentText(sender + " · " + body)
                .setStyle(new NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setSound(sound)
                .setVibrate(new long[]{0, 220, 100, 260})
                .setAutoCancel(true)
                .setFullScreenIntent(fullScreen, true)
                .setContentIntent(content)
                .build();
        manager.notify(requestCode, notification);

        // A full-screen notification wakes the lock screen. Direct launches also
        // guarantee the same dog popup while the phone is already unlocked.
        Handler handler = new Handler(Looper.getMainLooper());
        Runnable showScreen = () -> {
            try { startActivity(screen); } catch (Exception ignored) {}
        };
        handler.post(showScreen);
        handler.postDelayed(showScreen, 350L);

        Vibrator vibrator = (Vibrator) getSystemService(VIBRATOR_SERVICE);
        if (vibrator != null && vibrator.hasVibrator() && Build.VERSION.SDK_INT >= 26)
            vibrator.vibrate(VibrationEffect.createWaveform(new long[]{0, 220, 100, 260}, -1));
    }
}
