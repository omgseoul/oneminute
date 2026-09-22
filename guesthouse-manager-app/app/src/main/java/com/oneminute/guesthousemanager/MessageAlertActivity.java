package com.oneminute.guesthousemanager;

import android.app.NotificationManager;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import androidx.appcompat.app.AppCompatActivity;

public class MessageAlertActivity extends AppCompatActivity {
    private static final int NAVY = Color.rgb(24, 49, 83);
    private static final int BLUE = Color.rgb(36, 103, 189);
    private int notificationId;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        showOverLockScreen();
        buildMessageScreen(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        buildMessageScreen(intent);
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

    private void buildMessageScreen(Intent intent) {
        String sender = intent.getStringExtra("senderLabel");
        String message = intent.getStringExtra("message");
        notificationId = intent.getIntExtra("notificationId", 9102);
        if (sender == null || sender.trim().isEmpty()) sender = "새 메세지";
        if (message == null || message.trim().isEmpty()) message = "메세지 메뉴에서 확인해주세요.";

        FrameLayout shade = new FrameLayout(this);
        shade.setBackgroundColor(Color.argb(120, 13, 25, 42));
        shade.setPadding(dp(22), dp(32), dp(22), dp(32));

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackground(rounded(Color.WHITE, 28));

        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        card.setPadding(dp(25), dp(25), dp(25), dp(24));
        scroll.addView(card, new ScrollView.LayoutParams(-1, -2));

        ImageView dog = new ImageView(this);
        dog.setImageResource(R.mipmap.message_shiba_wave);
        dog.setScaleType(ImageView.ScaleType.CENTER_INSIDE);
        dog.setPadding(dp(8), dp(8), dp(8), dp(8));
        dog.setBackground(oval(Color.rgb(237, 245, 255)));
        card.addView(dog, new LinearLayout.LayoutParams(dp(158), dp(158)));

        TextView title = label("새 메세지 도착", 28, NAVY, true, Gravity.CENTER);
        LinearLayout.LayoutParams titleParams = new LinearLayout.LayoutParams(-1, -2);
        titleParams.setMargins(0, dp(5), 0, dp(7));
        card.addView(title, titleParams);

        TextView from = label(sender + "님이 보냈습니다.", 14,
                Color.rgb(112, 128, 149), false, Gravity.CENTER);
        LinearLayout.LayoutParams fromParams = new LinearLayout.LayoutParams(-1, -2);
        fromParams.setMargins(0, 0, 0, dp(16));
        card.addView(from, fromParams);

        TextView messageBox = label(message, 18, Color.rgb(38, 58, 86),
                true, Gravity.CENTER);
        messageBox.setMinHeight(dp(105));
        messageBox.setPadding(dp(18), dp(18), dp(18), dp(18));
        messageBox.setBackground(rounded(Color.rgb(244, 247, 252), 18));
        card.addView(messageBox, new LinearLayout.LayoutParams(-1, -2));

        Button open = actionButton("메세지 보기", BLUE, Color.WHITE);
        open.setOnClickListener(view -> openMessages());
        LinearLayout.LayoutParams openParams = new LinearLayout.LayoutParams(-1, dp(58));
        openParams.setMargins(0, dp(18), 0, dp(9));
        card.addView(open, openParams);

        Button close = actionButton("닫기", Color.rgb(234, 241, 250), NAVY);
        close.setOnClickListener(view -> closePopup());
        card.addView(close, new LinearLayout.LayoutParams(-1, dp(52)));

        FrameLayout.LayoutParams cardParams = new FrameLayout.LayoutParams(-1, -2, Gravity.CENTER);
        shade.addView(scroll, cardParams);
        setContentView(shade);
    }

    private Button actionButton(String text, int background, int foreground) {
        Button button = new Button(this);
        button.setAllCaps(false);
        button.setText(text);
        button.setTextSize(18);
        button.setTextColor(foreground);
        button.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        button.setBackground(rounded(background, 16));
        return button;
    }

    private TextView label(String text, int sizeSp, int color, boolean bold, int gravity) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(sizeSp);
        view.setTextColor(color);
        view.setGravity(gravity);
        view.setLineSpacing(0, 1.15f);
        if (bold) view.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        return view;
    }

    private GradientDrawable rounded(int color, int radiusDp) {
        GradientDrawable background = new GradientDrawable();
        background.setColor(color);
        background.setCornerRadius(dp(radiusDp));
        return background;
    }

    private GradientDrawable oval(int color) {
        GradientDrawable background = new GradientDrawable();
        background.setShape(GradientDrawable.OVAL);
        background.setColor(color);
        return background;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private void cancelNotification() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager != null) manager.cancel(notificationId);
    }

    private void closePopup() {
        cancelNotification();
        finishAndRemoveTask();
    }

    private void openMessages() {
        cancelNotification();
        Intent open = new Intent(this, AttendanceActivity.class)
                .setData(Uri.parse("https://omgworks24.com/messages.html"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                        | Intent.FLAG_ACTIVITY_CLEAR_TOP
                        | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        startActivity(open);
        finish();
    }

    @Override
    public void onBackPressed() {
        closePopup();
    }
}
