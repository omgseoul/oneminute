package com.oneminute.guesthousemanager;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.graphics.Color;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.speech.tts.TextToSpeech;
import androidx.core.app.NotificationCompat;
import java.util.Locale;

public class EmergencyAlarmService extends Service {
    public static final String ACTION_START = "com.oneminute.guesthousemanager.START_URGENT_ALERT";
    public static final String ACTION_STOP = "com.oneminute.guesthousemanager.STOP_URGENT_ALERT";
    public static final String ACTION_SCREEN_CLOSE = "com.oneminute.guesthousemanager.URGENT_SCREEN_CLOSE";

    private static final String CHANNEL_ID = "urgent_alerts_countdown_v4";
    private static final int NOTIFICATION_ID = 9001;
    private static final long COUNTDOWN_MS = 60_000L;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private MediaPlayer alarmPlayer;
    private MediaPlayer fallbackTonePlayer;
    private TextToSpeech speech;
    private Vibrator vibrator;
    private PowerManager.WakeLock wakeLock;
    private Runnable startPersistentAlarm;
    private String alertId;
    private String message;
    private String mode;
    private String senderLabel;
    private long deadlineEpochMs;

    @Override
    public void onCreate() {
        super.onCreate();
        vibrator = (Vibrator) getSystemService(VIBRATOR_SERVICE);
        createNotificationChannel();
    }

    private void createNotificationChannel() {
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID, "긴급 메세지", NotificationManager.IMPORTANCE_HIGH);
        channel.setDescription("잠금화면을 깨우고 확인할 때까지 표시되는 긴급 알림");
        channel.enableVibration(false);
        channel.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
        channel.setBypassDnd(true);
        channel.setSound(null, null);
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager != null) manager.createNotificationChannel(channel);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) {
            stopSelf();
            return START_NOT_STICKY;
        }
        if (ACTION_STOP.equals(intent.getAction())) {
            stopAlert(true);
            return START_NOT_STICKY;
        }

        stopOutputs();
        if (startPersistentAlarm != null) handler.removeCallbacks(startPersistentAlarm);

        alertId = intent.getStringExtra("alertId");
        message = intent.getStringExtra("message");
        mode = intent.getStringExtra("mode");
        senderLabel = intent.getStringExtra("senderLabel");
        if (senderLabel == null || senderLabel.trim().isEmpty()) senderLabel = "사장님";
        if (message == null || message.trim().isEmpty()) message = "사장님이 보낸 메시지입니다.";
        if (!"test".equals(mode)) mode = "urgent";
        deadlineEpochMs = System.currentTimeMillis() + COUNTDOWN_MS;

        Intent screen = buildScreenIntent();
        PendingIntent fullScreen = PendingIntent.getActivity(
                this, requestCode("screen"), screen,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        PendingIntent acknowledge = buildAcknowledgePendingIntent();

        startForeground(NOTIFICATION_ID, buildNotification(fullScreen, acknowledge, false));
        acquireWakeLock();
        playFirstStage();

        // Full-screen intent wakes the lock screen. Direct launch also displays the
        // same dog countdown immediately while the employee is already in the app.
        try {
            startActivity(screen);
        } catch (Exception ignored) {
            // The full-screen notification remains as fallback.
        }

        if ("urgent".equals(mode)) {
            startPersistentAlarm = () -> {
                playPersistentAlarm();
                NotificationManager manager = getSystemService(NotificationManager.class);
                if (manager != null) manager.notify(NOTIFICATION_ID,
                        buildNotification(fullScreen, acknowledge, true));
            };
            handler.postDelayed(startPersistentAlarm, COUNTDOWN_MS);
        }
        return START_STICKY;
    }

    private Intent buildScreenIntent() {
        return new Intent(this, UrgentAlertActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                        | Intent.FLAG_ACTIVITY_CLEAR_TOP
                        | Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra("alertId", alertId)
                .putExtra("message", message)
                .putExtra("mode", mode)
                .putExtra("senderLabel", senderLabel)
                .putExtra("deadlineEpochMs", deadlineEpochMs);
    }

    private PendingIntent buildAcknowledgePendingIntent() {
        Intent acknowledge = new Intent(this, AcknowledgeReceiver.class)
                .putExtra("alertId", alertId);
        return PendingIntent.getBroadcast(this, requestCode("ack"), acknowledge,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private int requestCode(String suffix) {
        return ((alertId == null ? "urgent" : alertId) + suffix).hashCode();
    }

    private String senderIntro() {
        return "사장님".equals(senderLabel)
                ? "사장님이 보낸 메세지입니다"
                : senderLabel + "님이 보낸 메세지입니다";
    }

    private Notification buildNotification(PendingIntent fullScreen,
                                           PendingIntent acknowledge,
                                           boolean ringing) {
        boolean test = "test".equals(mode);
        String title = test ? "긴급알림 테스트" :
                (ringing ? "미확인 긴급 메세지" : senderIntro());
        String content = ringing ? "확인할 때까지 긴급 알람이 계속 울립니다." : message;
        return new NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setColor(Color.rgb(217, 54, 62))
                .setContentTitle(title)
                .setContentText(content)
                .setStyle(new NotificationCompat.BigTextStyle().bigText(content))
                .setOngoing(!test)
                .setAutoCancel(test)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setFullScreenIntent(fullScreen, true)
                .setContentIntent(fullScreen)
                .addAction(0, "확인했습니다", acknowledge)
                .build();
    }

    private void acquireWakeLock() {
        PowerManager manager = (PowerManager) getSystemService(POWER_SERVICE);
        if (manager == null) return;
        releaseWakeLock();
        wakeLock = manager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "guesthouse-manager:urgent-countdown");
        wakeLock.acquire(2 * 60_000L);
    }

    private void playFirstStage() {
        if (vibrator != null && vibrator.hasVibrator()) {
            vibrator.vibrate(VibrationEffect.createWaveform(
                    new long[]{0, 650, 180, 650}, -1));
        }
        // !!테스트는 조용한 장소에서 동작 여부만 확인하는 모드다.
        // 진동과 동일한 강아지 카운터 화면만 표시하고 어떤 소리도 내지 않는다.
        if ("test".equals(mode)) return;

        speech = new TextToSpeech(this, status -> {
            if (status != TextToSpeech.SUCCESS || speech == null) {
                playFallbackNotificationTone();
                return;
            }
            int language = speech.setLanguage(Locale.KOREAN);
            if (language == TextToSpeech.LANG_MISSING_DATA
                    || language == TextToSpeech.LANG_NOT_SUPPORTED) {
                playFallbackNotificationTone();
                return;
            }
            speech.setAudioAttributes(new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build());
            Bundle parameters = new Bundle();
            parameters.putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1.0f);
            speech.speak(senderIntro() + ".", TextToSpeech.QUEUE_FLUSH,
                    parameters, "owner_message_intro");
        });
    }

    private void playFallbackNotificationTone() {
        Uri tone = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION);
        fallbackTonePlayer = MediaPlayer.create(this, tone);
        if (fallbackTonePlayer != null) {
            fallbackTonePlayer.setOnCompletionListener(player -> {
                player.release();
                if (fallbackTonePlayer == player) fallbackTonePlayer = null;
            });
            fallbackTonePlayer.start();
        }
    }

    private void playPersistentAlarm() {
        Uri tone = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM);
        alarmPlayer = MediaPlayer.create(this, tone);
        if (alarmPlayer != null) {
            alarmPlayer.setLooping(true);
            alarmPlayer.start();
        }
        if (vibrator != null && vibrator.hasVibrator()) {
            vibrator.vibrate(VibrationEffect.createWaveform(
                    new long[]{0, 1000, 500, 1000, 500}, 0));
        }
    }

    private void stopAlert(boolean closeScreen) {
        if (startPersistentAlarm != null) handler.removeCallbacks(startPersistentAlarm);
        stopOutputs();
        releaseWakeLock();
        stopForeground(true);
        if (closeScreen) {
            sendBroadcast(new Intent(ACTION_SCREEN_CLOSE).setPackage(getPackageName()));
        }
        stopSelf();
    }

    private void stopOutputs() {
        if (alarmPlayer != null) {
            try { alarmPlayer.stop(); } catch (Exception ignored) {}
            alarmPlayer.release();
            alarmPlayer = null;
        }
        if (fallbackTonePlayer != null) {
            try { fallbackTonePlayer.stop(); } catch (Exception ignored) {}
            fallbackTonePlayer.release();
            fallbackTonePlayer = null;
        }
        if (speech != null) {
            speech.stop();
            speech.shutdown();
            speech = null;
        }
        if (vibrator != null) vibrator.cancel();
    }

    private void releaseWakeLock() {
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        wakeLock = null;
    }

    @Override
    public void onDestroy() {
        if (startPersistentAlarm != null) handler.removeCallbacks(startPersistentAlarm);
        stopOutputs();
        releaseWakeLock();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
