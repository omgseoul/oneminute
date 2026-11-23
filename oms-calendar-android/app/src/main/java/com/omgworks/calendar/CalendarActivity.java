package com.omgworks.calendar;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.TimePickerDialog;
import android.os.Bundle;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.webkit.JavascriptInterface;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.LinearLayout;
import android.widget.Switch;
import android.widget.Button;
import android.widget.Toast;
import java.util.Locale;
import java.util.regex.Pattern;

public final class CalendarActivity extends Activity {
    static final String ORIGIN = "https://omgworks24.com";
    static final String HOME = ORIGIN + "/calendar.html?app=calendar";
    private static final Pattern UUID = Pattern.compile("[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}");
    private WebView web;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        web = new WebView(this);
        web.getSettings().setJavaScriptEnabled(true);
        web.getSettings().setDomStorageEnabled(true);
        web.getSettings().setAllowFileAccess(false);
        web.getSettings().setAllowContentAccess(false);
        web.addJavascriptInterface(new Bridge(), "OMSCalendarAndroid");
        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri url = request.getUrl();
                if (!request.isForMainFrame()) return true;
                if (!trusted(url)) {
                    if ("https".equals(url.getScheme())) {
                        try { startActivity(new Intent(Intent.ACTION_VIEW, url)); }
                        catch (android.content.ActivityNotFoundException ignored) { }
                    }
                    return true;
                }
                if ("/app.html".equals(url.getPath())) { view.loadUrl(HOME); return true; }
                return false;
            }
        });
        setContentView(web);
        web.loadUrl(getIntent().getBooleanExtra("tasks", false) ? ORIGIN + "/mission.html?scope=mine" : HOME);
    }

    private boolean trusted(Uri uri) {
        return uri != null && "https".equals(uri.getScheme()) && "omgworks24.com".equals(uri.getHost())
                && (uri.getPort() == -1 || uri.getPort() == 443);
    }

    private boolean trustedCurrentPage() {
        String url = web.getUrl();
        return url != null && trusted(Uri.parse(url));
    }

    private final class Bridge {
        @JavascriptInterface public void setSession(String token, String role, String id, String property, String timezone) {
            runOnUiThread(() -> {
                if (!trustedCurrentPage() || token == null || !UUID.matcher(token).matches()
                        || id == null || !UUID.matcher(id).matches() || property == null || !UUID.matcher(property).matches()) return;
                CalendarRefresh.bind(CalendarActivity.this, token, role, id, property, timezone);
            });
        }
        @JavascriptInterface public void clearSession() {
            runOnUiThread(() -> { if (trustedCurrentPage()) CalendarRefresh.clear(CalendarActivity.this); });
        }
        @JavascriptInterface public void openSettings() {
            runOnUiThread(() -> { if (trustedCurrentPage()) settings(); });
        }
    }

    private void settings() {
        SharedPreferences prefs = CalendarRefresh.preferences(this);
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        int pad = (int)(22 * getResources().getDisplayMetrics().density);
        content.setPadding(pad, 0, pad, 0);
        addReminder(content, prefs, "events", "오늘 일정 알림", 9 * 60);
        addReminder(content, prefs, "tasks", "지연 To do 알림", 10 * 60);
        new AlertDialog.Builder(this).setTitle("OMS Calendar 알림 설정").setView(content)
                .setPositiveButton("닫기", null).show();
    }

    private void addReminder(LinearLayout content, SharedPreferences prefs, String kind, String label, int defaultTime) {
        Switch enabled = new Switch(this);
        enabled.setText(label);
        enabled.setChecked(prefs.getBoolean(kind + "_enabled", false));
        enabled.setOnCheckedChangeListener((button, on) -> {
            prefs.edit().putBoolean(kind + "_enabled", on).apply();
            if (on && android.os.Build.VERSION.SDK_INT >= 33
                    && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS}, 1);
            }
            CalendarRefresh.schedule(this, true);
        });
        content.addView(enabled);
        Button time = new Button(this);
        int minutes = prefs.getInt(kind + "_time", defaultTime);
        time.setText(formatTime(minutes));
        time.setOnClickListener(view -> {
            int current = prefs.getInt(kind + "_time", defaultTime);
            new TimePickerDialog(this, (picker, hour, minute) -> {
                int value = hour * 60 + minute;
                prefs.edit().putInt(kind + "_time", value).apply();
                time.setText(formatTime(value));
                CalendarRefresh.schedule(this, true);
                Toast.makeText(this, "알림 시각을 저장했습니다.", Toast.LENGTH_SHORT).show();
            }, current / 60, current % 60, true).show();
        });
        content.addView(time);
    }

    private static String formatTime(int minutes) {
        return String.format(Locale.KOREA, "%02d:%02d", minutes / 60, minutes % 60);
    }

    @Override public void onBackPressed() {
        if (web.canGoBack()) web.goBack(); else super.onBackPressed();
    }
}
