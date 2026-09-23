package com.oneminute.guesthousemanager;

import android.app.NotificationManager;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.BitmapFactory;
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
import android.util.Base64;
import androidx.appcompat.app.AppCompatActivity;

public class MessageAlertActivity extends AppCompatActivity {
    private static final int NAVY = Color.rgb(24, 49, 83);
    private static final int BLUE = Color.rgb(36, 103, 189);
    private static final String MESSAGE_DOG_BASE64 = "/9j/4AAQSkZJRgABAQAAAAAAAAD/2wBDAAYEBAUEBAYFBQUGBgYHCQ4JCQgICRINDQoOFRIWFhUSFBQXGiEcFxgfGRQUHScdHyIjJSUlFhwpLCgkKyEkJST/2wBDAQYGBgkICREJCREkGBQYJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCT/wAARCAFoAWgDASIAAhEBAxEB/8QAHQABAAEFAQEBAAAAAAAAAAAAAAYCAwQFBwEICf/EAD4QAAEDAwIEBAMECQQDAAMAAAEAAgMEBREGIRITMUEHUWFxIjKBFFKRoQgVIzNCYrHB0RZDcpIkU+Fzg9L/xAAbAQEAAgMBAQAAAAAAAAAAAAAAAwUBAgYEB//EADMRAAICAgAEAwUHBQEBAAAAAAABAgMEEQUSITETQVEiMmFxwQYUM5GhseEjJEKB0fDx/9oADAMBAAIRAxEAPwD6pREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAERW6qpjpKeSeZ3CyMZJWJSUVt9jKTb0jFu93p7RTGWY5cdmMHVxUKq9XV1TISKn7O3sxnb6rTahv01yq3TfES48McY7DsFl27SQkjElynkErt+XGcBv17lcRk8RyuIWuGL0gv9fm/odTj4FGLWp5HvP/AGZtJq+5UbuJ0wqY+7X/AOVMbJqCkvcRMLuCVvzRu6hc7uliqLQDPFIZ6TuT8zPf0WBBWTUU7KulkdG9pyCFBj8WysC3w8jbj6P90yW7htGVXzU9H6/Ro7Mi1Gm9QQ36iEjcNnZtIzyPn7LbruqboXQVlb2mcpbVKqbhNaaCIilIwiIgCIiAIiIAiIgCIiAIiIAiIgCIiAIiIAiIgCIiAIiIAiIgCIiAIiIAiIgCIiAIiIAoVr68gFltjd0+OXH5BTCqqGUlNLPIcNjaXFcirJZrvcXY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0eh6qbrl3hU2d10lkYx3JEZD3dgewXUV9F4PY54sW/I4bi1ahlS15hERWZWhERAEREAREQBERAEREAREQBERAEREAREQBERAEREBo75o61X3L5oeVOf96LZ3181DK/wvuNMS6iqYqlnYO+B3+F09FW5XCcbIe5x0/VdD343E8ihajLa9H1Ob6ftFxtkcrKyklidxbZGQR7hbcSb4UxVqSlgl+eGN3u1bUYCprVcH0Ri7Nds3OS7kT5o80Euc7qRvslC//Z4f+JIVh+m6V3yvlb9crd0TNFdE0gmTnbraO0wzfhqXD3arbtLy9qpp92rXwZ+hlWw9TWmb1Xhl26rYf6Yqf/fEfoVT/pmrP+9F+ax4U/Qz4kPU15l2zlW3SjHVbM6YrMfvofzVP+lKp3WoiH0KeFP0M+JD1NU6XqrLpc7ZW8GkJiPiq2D2aVU3Rjf46x30YseDP0HjQXmRO4y/+JNv0aVzKtk4+MrvUmhaGeN0c1RUOa4YOCB/ZY8HhbpeLd9E+b/8krj/AEVXn8KvyZR5dJL1LTA4pRjxfNtt+h87aekzcqkfzj+i6DQUFZWANp6WaXP3WErrlu0bp21OLqKzUULjuXCIEn6lbdrGsHC1oaPIDChX2acnuyz8kTW/aJP8OH5s5TR6AvlZu+FlO095Xb/gFv7b4WUMThJcamSpd3Yz4W/5U4RWWPwLEq6tcz+P/OxWXcZybOiel8CxR0NNb4G09JBHDE3o1gwFfRFcJJLSKttt7YREWTAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQBERAEREAREQH//2Q==";
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
        byte[] dogBytes = Base64.decode(MESSAGE_DOG_BASE64, Base64.DEFAULT);
        dog.setImageBitmap(BitmapFactory.decodeByteArray(dogBytes, 0, dogBytes.length));
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

        LinearLayout actions = new LinearLayout(this);
        actions.setOrientation(LinearLayout.HORIZONTAL);

        Button open = actionButton("메세지 보기", BLUE, Color.WHITE);
        open.setOnClickListener(view -> openMessages());
        LinearLayout.LayoutParams openParams = new LinearLayout.LayoutParams(0, dp(58), 3f);
        openParams.setMargins(0, 0, dp(5), 0);
        actions.addView(open, openParams);

        Button close = actionButton("닫기", Color.rgb(234, 241, 250), NAVY);
        close.setOnClickListener(view -> closePopup());
        LinearLayout.LayoutParams closeParams = new LinearLayout.LayoutParams(0, dp(58), 1f);
        closeParams.setMargins(dp(5), 0, 0, 0);
        actions.addView(close, closeParams);

        LinearLayout.LayoutParams actionsParams = new LinearLayout.LayoutParams(-1, dp(58));
        actionsParams.setMargins(0, dp(18), 0, 0);
        card.addView(actions, actionsParams);

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
