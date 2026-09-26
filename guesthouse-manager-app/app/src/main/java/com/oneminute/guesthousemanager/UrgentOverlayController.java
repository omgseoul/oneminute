package com.oneminute.guesthousemanager;

import android.content.Context;
import android.content.Intent;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * Displays an urgent alert above any currently visible app. Android blocks
 * background activity launches while the screen is already unlocked, so the
 * notification full-screen intent alone is not enough for this use case.
 */
final class UrgentOverlayController {
    private static final int NAVY = Color.rgb(24, 49, 83);
    private static final int RED = Color.rgb(217, 54, 62);
    private final Context context;
    private final WindowManager windowManager;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private View overlay;
    private Runnable tick;

    UrgentOverlayController(Context context) {
        this.context = context;
        windowManager = (WindowManager) context.getSystemService(Context.WINDOW_SERVICE);
    }

    boolean show(String alertId, String message, String mode, String senderLabel,
                 long deadlineEpochMs) {
        if (!Settings.canDrawOverlays(context) || windowManager == null) return false;
        dismiss();

        FrameLayout shade = new FrameLayout(context);
        shade.setBackgroundColor(Color.argb(218, 21, 34, 52));
        shade.setPadding(dp(22), dp(34), dp(22), dp(34));

        ScrollView scroll = new ScrollView(context);
        scroll.setFillViewport(true);
        scroll.setVerticalScrollBarEnabled(false);

        LinearLayout outer = new LinearLayout(context);
        outer.setOrientation(LinearLayout.VERTICAL);
        outer.setGravity(Gravity.CENTER);
        scroll.addView(outer, new ScrollView.LayoutParams(-1, -1));

        LinearLayout card = new LinearLayout(context);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        card.setPadding(dp(24), dp(25), dp(24), dp(24));
        card.setBackground(rounded(Color.WHITE, 28));
        outer.addView(card, new LinearLayout.LayoutParams(-1, -2));

        ImageView dog = new ImageView(context);
        dog.setImageBitmap(UrgentAlertActivity.dogBitmap());
        dog.setScaleType(ImageView.ScaleType.CENTER_INSIDE);
        card.addView(dog, new LinearLayout.LayoutParams(dp(108), dp(108)));

        TextView title = label("test".equals(mode) ? "긴급알림 테스트" : "긴급 메세지 도착",
                26, NAVY, true);
        LinearLayout.LayoutParams titleParams = new LinearLayout.LayoutParams(-1, -2);
        titleParams.setMargins(0, dp(4), 0, dp(5));
        card.addView(title, titleParams);

        String sender = senderLabel == null || senderLabel.trim().isEmpty()
                ? "사장님" : senderLabel.trim();
        String senderText = "사장님".equals(sender)
                ? "사장님이 보냈습니다." : sender + "님이 보냈습니다.";
        TextView senderCopy = label(senderText, 17, Color.rgb(104, 113, 126), true);
        LinearLayout.LayoutParams senderParams = new LinearLayout.LayoutParams(-1, -2);
        senderParams.setMargins(0, 0, 0, dp(16));
        card.addView(senderCopy, senderParams);

        TextView messageBox = label(message, 20, Color.rgb(32, 50, 76), true);
        messageBox.setMinHeight(dp(82));
        messageBox.setPadding(dp(16), dp(15), dp(16), dp(15));
        messageBox.setGravity(Gravity.CENTER);
        messageBox.setBackground(rounded(Color.rgb(247, 249, 253), 18));
        card.addView(messageBox, new LinearLayout.LayoutParams(-1, -2));

        CountdownCircle counter = new CountdownCircle(context);
        LinearLayout.LayoutParams counterParams = new LinearLayout.LayoutParams(dp(142), dp(142));
        counterParams.setMargins(0, dp(17), 0, dp(7));
        card.addView(counter, counterParams);

        TextView countdownCopy = label("60초 안에 확인해주세요.", 17, RED, true);
        LinearLayout.LayoutParams countdownParams = new LinearLayout.LayoutParams(-1, -2);
        countdownParams.setMargins(0, 0, 0, dp(16));
        card.addView(countdownCopy, countdownParams);

        Button acknowledge = new Button(context);
        acknowledge.setAllCaps(false);
        acknowledge.setText(GuestChatAlerts.room(context,alertId)!=null ? "채팅방 열기" : "확인했습니다");
        acknowledge.setTextSize(19);
        acknowledge.setTextColor(Color.WHITE);
        acknowledge.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        acknowledge.setBackground(rounded(NAVY, 16));
        acknowledge.setOnClickListener(view -> {
            GuestChatAlerts.open(context,alertId);
            context.sendBroadcast(
                new Intent(context, AcknowledgeReceiver.class)
                        .setPackage(context.getPackageName())
                        .putExtra("alertId", alertId));
        });
        card.addView(acknowledge, new LinearLayout.LayoutParams(-1, dp(60)));

        shade.addView(scroll, new FrameLayout.LayoutParams(-1, -1));
        WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                        | WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                        | WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                        | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
                PixelFormat.TRANSLUCENT);
        params.gravity = Gravity.CENTER;
        if (Build.VERSION.SDK_INT >= 28) {
            params.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        }

        try {
            windowManager.addView(shade, params);
            overlay = shade;
        } catch (RuntimeException error) {
            overlay = null;
            return false;
        }

        tick = new Runnable() {
            @Override public void run() {
                long remainingMs = Math.max(0L, deadlineEpochMs - System.currentTimeMillis());
                int remaining = (int) Math.ceil(remainingMs / 1000.0);
                counter.setRemaining(remaining);
                countdownCopy.setText(remaining > 0
                        ? remaining + "초 안에 확인해주세요."
                        : "미확인 · 알람이 울리는 중입니다.");
                handler.postDelayed(this, remaining > 0 ? 250L : 1000L);
            }
        };
        handler.post(tick);
        return true;
    }

    void dismiss() {
        if (tick != null) handler.removeCallbacks(tick);
        tick = null;
        if (overlay != null && windowManager != null) {
            try { windowManager.removeViewImmediate(overlay); } catch (RuntimeException ignored) {}
        }
        overlay = null;
    }

    private TextView label(String text, int sizeSp, int color, boolean bold) {
        TextView view = new TextView(context);
        view.setText(text == null || text.trim().isEmpty()
                ? "사장님이 보낸 메세지입니다." : text);
        view.setTextSize(sizeSp);
        view.setTextColor(color);
        view.setGravity(Gravity.CENTER);
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
        return Math.round(value * context.getResources().getDisplayMetrics().density);
    }

    private static final class CountdownCircle extends View {
        private final Paint track = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint progress = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint number = new Paint(Paint.ANTI_ALIAS_FLAG);
        private int remaining = 60;

        CountdownCircle(Context context) {
            super(context);
            track.setStyle(Paint.Style.STROKE);
            track.setStrokeCap(Paint.Cap.ROUND);
            track.setStrokeWidth(dp(context, 11));
            track.setColor(Color.rgb(255, 220, 222));
            progress.setStyle(Paint.Style.STROKE);
            progress.setStrokeCap(Paint.Cap.ROUND);
            progress.setStrokeWidth(dp(context, 11));
            progress.setColor(RED);
            number.setColor(RED);
            number.setTypeface(Typeface.create(Typeface.DEFAULT, Typeface.BOLD));
            number.setTextAlign(Paint.Align.CENTER);
            number.setTextSize(dp(context, 46));
        }

        void setRemaining(int seconds) {
            remaining = Math.max(0, Math.min(60, seconds));
            invalidate();
        }

        @Override protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            float inset = dp(getContext(), 13);
            android.graphics.RectF oval = new android.graphics.RectF(
                    inset, inset, getWidth() - inset, getHeight() - inset);
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
