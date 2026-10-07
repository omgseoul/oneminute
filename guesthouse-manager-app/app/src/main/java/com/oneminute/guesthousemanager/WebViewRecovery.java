package com.oneminute.guesthousemanager;

import android.app.Activity;
import android.graphics.Color;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.View;
import android.webkit.WebView;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Native UI remains available even when DNS cannot load a single web asset. */
final class WebViewRecovery {
    private static final long[] DELAYS = {2000, 5000, 10000, 20000};
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final WebView web;
    private final LinearLayout panel;
    private final TextView message;
    private final Button retry;
    private final ConnectivityManager connectivity;
    private String target;
    private boolean failed, loading, resumed, destroyed, registered;
    private int attempts;
    private boolean networkValidated;
    private long lastAttempt;
    private final Runnable scheduledRetry = () -> reconnect(false);
    private final Runnable timeout = () -> { if (loading) { web.stopLoading(); fail(target); } };
    private final ConnectivityManager.NetworkCallback networkCallback = new ConnectivityManager.NetworkCallback() {
        @Override public void onCapabilitiesChanged(Network network, NetworkCapabilities caps) {
            final boolean valid = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
            handler.post(() -> {
                boolean restored = valid && !networkValidated;
                networkValidated = valid;
                if (restored && failed && resumed) { attempts = 0; scheduleRetry(1000); }
            });
        }
        @Override public void onLost(Network network) { handler.post(() -> networkValidated = false); }
    };
    WebViewRecovery(Activity activity, WebView webView, FrameLayout root, String initialUrl) {
        web = webView; target = initialUrl;
        panel = new LinearLayout(activity); panel.setOrientation(LinearLayout.VERTICAL);
        panel.setGravity(Gravity.CENTER); panel.setPadding(40, 40, 40, 40);
        panel.setBackgroundColor(Color.rgb(244,247,252));
        TextView title = new TextView(activity); title.setText("OMS에 연결하지 못했습니다");
        title.setTextSize(22); title.setTextColor(Color.rgb(24,49,83)); title.setGravity(Gravity.CENTER);
        message = new TextView(activity); message.setTextSize(15); message.setGravity(Gravity.CENTER);
        message.setTextColor(Color.rgb(109,123,144)); message.setPadding(0,28,0,28);
        retry = new Button(activity); retry.setText("다시 연결"); retry.setOnClickListener(v -> reconnect(true));
        panel.addView(title); panel.addView(message); panel.addView(retry);
        root.addView(panel, new FrameLayout.LayoutParams(-1,-1)); panel.setVisibility(View.GONE);
        connectivity = (ConnectivityManager) activity.getSystemService(Activity.CONNECTIVITY_SERVICE);
        try { connectivity.registerDefaultNetworkCallback(networkCallback); registered = true; }
        catch (SecurityException ignored) { /* Manual/resume/timer recovery still works. */ }
    }
    private boolean trusted(String url) {
        if (url == null) return false;
        Uri uri = Uri.parse(url); String host = uri.getHost();
        return "https".equals(uri.getScheme()) && ("omgworks24.com".equals(host)
                || "www.omgworks24.com".equals(host)
                || ("omgseoul.github.io".equals(host) && uri.getPath()!=null && uri.getPath().startsWith("/oneminute/")));
    }
    void started(String url) {
        if (destroyed || !trusted(url)) return;
        target = url; loading = true; failed = false;
        handler.removeCallbacks(scheduledRetry); handler.removeCallbacks(timeout);
        handler.postDelayed(timeout, 25000);
    }
    void finished(String url) {
        if (destroyed || failed || !loading || !target.equals(url)) return;
        loading = false; attempts = 0; handler.removeCallbacks(timeout);
        panel.setVisibility(View.GONE); web.setVisibility(View.VISIBLE); retry.setEnabled(true);
    }
    void fail(String url) {
        if (destroyed || !trusted(url) || !target.equals(url)) return;
        failed = true; loading = false; handler.removeCallbacks(timeout);
        web.setVisibility(View.INVISIBLE); panel.setVisibility(View.VISIBLE); retry.setEnabled(true);
        message.setText(attempts < DELAYS.length ? "인터넷 연결을 확인해주세요.\n잠시 후 자동으로 다시 연결합니다." : "자동 연결을 잠시 멈췄습니다.\n연결 상태를 확인한 뒤 다시 연결을 눌러주세요.");
        if (resumed && attempts < DELAYS.length) scheduleRetry(DELAYS[attempts]);
    }
    private void scheduleRetry(long delay) {
        if (destroyed || !failed || loading || !resumed || attempts >= DELAYS.length) return;
        handler.removeCallbacks(scheduledRetry);
        handler.postDelayed(scheduledRetry, Math.max(delay, 2000 - (SystemClock.elapsedRealtime()-lastAttempt)));
    }
    private void reconnect(boolean manual) {
        if (destroyed || !resumed || loading || !failed) return;
        if (manual) attempts = 0;
        if (attempts >= DELAYS.length) return;
        attempts++; lastAttempt = SystemClock.elapsedRealtime(); loading = true; failed = false;
        handler.removeCallbacks(scheduledRetry); retry.setEnabled(false);
        message.setText("OMS에 다시 연결하는 중…"); web.loadUrl(target);
    }
    void resume() { resumed = true; if (failed) { attempts = 0; scheduleRetry(500); } }
    void pause() { resumed = false; handler.removeCallbacks(scheduledRetry); }
    void destroy() {
        destroyed = true; handler.removeCallbacksAndMessages(null);
        if (registered) { connectivity.unregisterNetworkCallback(networkCallback); registered = false; }
    }
}
