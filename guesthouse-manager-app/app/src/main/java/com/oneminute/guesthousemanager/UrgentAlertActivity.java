package com.oneminute.guesthousemanager;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Canvas;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import androidx.appcompat.app.AppCompatActivity;

public class UrgentAlertActivity extends AppCompatActivity {
    // The approved barking Shiba artwork is embedded so the APK build remains
    // self-contained even when GitHub's web uploader cannot create a new folder.
    private static final String BARKING_SHIBA_BASE64 = "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";
    private static final int RED = Color.rgb(217, 54, 62);
    private static final int NAVY = Color.rgb(24, 49, 83);
    private final Handler handler = new Handler(Looper.getMainLooper());
    private CountdownView countdownView;
    private TextView countdownCopy;
    private TextView modeCopy;
    private String alertId;
    private String mode;
    private long deadlineEpochMs;
    private boolean receiverRegistered;

    private final BroadcastReceiver closeReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            finishAndRemoveTask();
        }
    };

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            long remainingMs = Math.max(0L, deadlineEpochMs - System.currentTimeMillis());
            int remainingSeconds = (int) Math.ceil(remainingMs / 1000.0);
            if (countdownView != null) countdownView.setRemaining(remainingSeconds);
            if (remainingSeconds > 0) {
                countdownCopy.setText(remainingSeconds + "초 안에 미확인 시 알람이 울립니다.");
                handler.postDelayed(this, 250L);
            } else if ("test".equals(mode)) {
                countdownCopy.setText("테스트가 완료되었습니다.");
                modeCopy.setText("테스트 모드에서는 지속 알람이 울리지 않습니다.");
            } else {
                countdownCopy.setText("미확인 · 긴급 알람이 울리고 있습니다.");
                modeCopy.setText("아래 버튼을 눌러 확인하면 알람이 멈춥니다.");
            }
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        showOverLockScreen();
        readIntent(getIntent());
        buildDogCountdownScreen(getIntent().getStringExtra("message"));
        registerCloseReceiver();
        handler.post(tick);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handler.removeCallbacks(tick);
        readIntent(intent);
        buildDogCountdownScreen(intent.getStringExtra("message"));
        handler.post(tick);
    }

    private void showOverLockScreen() {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true);
            setTurnScreenOn(true);
        }
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_ALLOW_LOCK_WHILE_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD);
    }

    private void readIntent(Intent intent) {
        alertId = intent.getStringExtra("alertId");
        mode = intent.getStringExtra("mode");
        if (!"test".equals(mode)) mode = "urgent";
        deadlineEpochMs = intent.getLongExtra("deadlineEpochMs",
                System.currentTimeMillis() + 60_000L);
    }

    private void buildDogCountdownScreen(String incomingMessage) {
        String message = incomingMessage == null || incomingMessage.trim().isEmpty()
                ? "사장님이 보낸 메시지입니다." : incomingMessage.trim();

        FrameLayout shade = new FrameLayout(this);
        shade.setBackgroundColor(Color.argb(95, 13, 25, 42));
        int outer = dp(22);
        shade.setPadding(outer, dp(32), outer, dp(32));

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackground(rounded(Color.WHITE, 28));

        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        card.setPadding(dp(26), dp(25), dp(26), dp(24));
        scroll.addView(card, new ScrollView.LayoutParams(-1, -2));

        ImageView dog = new ImageView(this);
        byte[] dogBytes = Base64.decode(BARKING_SHIBA_BASE64, Base64.DEFAULT);
        dog.setImageBitmap(BitmapFactory.decodeByteArray(dogBytes, 0, dogBytes.length));
        dog.setScaleType(ImageView.ScaleType.CENTER_INSIDE);
        card.addView(dog, new LinearLayout.LayoutParams(dp(112), dp(112)));

        TextView title = label("test".equals(mode) ? "긴급알림 테스트" : "사장님 긴급메시지",
                27, RED, true, Gravity.CENTER);
        LinearLayout.LayoutParams titleParams = new LinearLayout.LayoutParams(-1, -2);
        titleParams.setMargins(0, dp(4), 0, dp(18));
        card.addView(title, titleParams);

        TextView messageBox = label(message, 20, Color.rgb(55, 58, 64), true, Gravity.CENTER);
        messageBox.setMinHeight(dp(95));
        messageBox.setPadding(dp(18), dp(18), dp(18), dp(18));
        messageBox.setBackground(rounded(Color.rgb(255, 239, 240), 18));
        card.addView(messageBox, new LinearLayout.LayoutParams(-1, -2));

        countdownView = new CountdownView(this);
        LinearLayout.LayoutParams counterParams = new LinearLayout.LayoutParams(dp(178), dp(178));
        counterParams.setMargins(0, dp(22), 0, dp(12));
        card.addView(countdownView, counterParams);

        countdownCopy = label("60초 안에 미확인 시 알람이 울립니다.",
                19, RED, true, Gravity.CENTER);
        card.addView(countdownCopy, new LinearLayout.LayoutParams(-1, -2));

        modeCopy = label("test".equals(mode)
                        ? "테스트 모드 · 지속 알람은 울리지 않습니다."
                        : "사장메세지는 언제나 즉시 확인하세요.",
                15, Color.rgb(96, 103, 115), false, Gravity.CENTER);
        modeCopy.setPadding(0, dp(8), 0, dp(18));
        card.addView(modeCopy, new LinearLayout.LayoutParams(-1, -2));

        Button acknowledge = new Button(this);
        acknowledge.setAllCaps(false);
        acknowledge.setText("확인했습니다");
        acknowledge.setTextSize(20);
        acknowledge.setTextColor(Color.WHITE);
        acknowledge.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        acknowledge.setBackground(rounded(NAVY, 16));
        acknowledge.setOnClickListener(view -> acknowledgeAlert());
        card.addView(acknowledge, new LinearLayout.LayoutParams(-1, dp(62)));

        FrameLayout.LayoutParams cardParams = new FrameLayout.LayoutParams(
                -1, -2, Gravity.CENTER);
        shade.addView(scroll, cardParams);
        setContentView(shade);
    }

    private TextView label(String text, int sizeSp, int color, boolean bold, int gravity) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(sizeSp);
        view.setTextColor(color);
        view.setGravity(gravity);
        view.setLineSpacing(0, 1.12f);
        if (bold) view.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        return view;
    }

    private GradientDrawable rounded(int color, int radiusDp) {
        GradientDrawable background = new GradientDrawable();
        background.setColor(color);
        background.setCornerRadius(dp(radiusDp));
        return background;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private void acknowledgeAlert() {
        Intent acknowledge = new Intent(this, AcknowledgeReceiver.class)
                .putExtra("alertId", alertId);
        PendingIntent pendingIntent = PendingIntent.getBroadcast(this,
                (alertId == null ? 0 : alertId.hashCode()), acknowledge,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        try { pendingIntent.send(); } catch (PendingIntent.CanceledException ignored) {}
        finishAndRemoveTask();
    }

    private void registerCloseReceiver() {
        IntentFilter filter = new IntentFilter(EmergencyAlarmService.ACTION_SCREEN_CLOSE);
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(closeReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(closeReceiver, filter);
        }
        receiverRegistered = true;
    }

    @Override
    public void onBackPressed() {
        // Urgent alerts require explicit acknowledgement.
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacks(tick);
        if (receiverRegistered) unregisterReceiver(closeReceiver);
        super.onDestroy();
    }

    private static final class CountdownView extends View {
        private final Paint track = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint progress = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint number = new Paint(Paint.ANTI_ALIAS_FLAG);
        private int remaining = 60;

        CountdownView(Context context) {
            super(context);
            track.setStyle(Paint.Style.STROKE);
            track.setStrokeCap(Paint.Cap.ROUND);
            track.setStrokeWidth(dp(context, 12));
            track.setColor(Color.rgb(255, 220, 222));
            progress.setStyle(Paint.Style.STROKE);
            progress.setStrokeCap(Paint.Cap.ROUND);
            progress.setStrokeWidth(dp(context, 12));
            progress.setColor(RED);
            number.setColor(RED);
            number.setTypeface(Typeface.create(Typeface.DEFAULT, Typeface.BOLD));
            number.setTextAlign(Paint.Align.CENTER);
            number.setTextSize(dp(context, 52));
        }

        void setRemaining(int seconds) {
            remaining = Math.max(0, Math.min(60, seconds));
            invalidate();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            float inset = dp(getContext(), 13);
            RectF oval = new RectF(inset, inset, getWidth() - inset, getHeight() - inset);
            canvas.drawArc(oval, -90, 360, false, track);
            canvas.drawArc(oval, -90, 360f * remaining / 60f, false, progress);
            Paint.FontMetrics metrics = number.getFontMetrics();
            float baseline = getHeight() / 2f - (metrics.ascent + metrics.descent) / 2f;
            canvas.drawText(String.valueOf(remaining), getWidth() / 2f, baseline, number);
        }

        private static float dp(Context context, int value) {
            return value * context.getResources().getDisplayMetrics().density;
        }
    }
}
