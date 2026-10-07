package com.oneminute.guesthousemanager;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.util.Base64;
import android.webkit.ValueCallback;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceError;
import android.webkit.WebResourceResponse;
import android.graphics.Bitmap;
import android.widget.FrameLayout;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;
import androidx.appcompat.app.AppCompatActivity;
import com.google.firebase.messaging.FirebaseMessaging;
import java.io.OutputStream;

public class AttendanceActivity extends AppCompatActivity {
    private static final String APP_URL = "https://omgworks24.com/app.html";
    private static final String MISSION_URL = "https://omgworks24.com/mission.html";
    private static final int FILE_CHOOSER_REQUEST = 2201;
    private static final int EXCEL_SAVE_REQUEST = 2202;
    private WebView webView;
    private WebViewRecovery recovery;
    private ValueCallback<Uri[]> fileCallback;
    private byte[] pendingExcel;

    private String safeTopicPart(String value) {
        return value == null ? "" : value.trim().replaceAll("[^A-Za-z0-9_.~-]", "_");
    }

    private void subscribeTopic(String preferenceKey, String topic) {
        if (topic == null || topic.isEmpty()) return;
        String previous = getSharedPreferences("omg_push", MODE_PRIVATE)
                .getString(preferenceKey, "");
        getSharedPreferences("omg_push", MODE_PRIVATE).edit()
                .putString(preferenceKey, topic).apply();
        if (!previous.isEmpty() && !topic.equals(previous))
            FirebaseMessaging.getInstance().unsubscribeFromTopic(previous);
        FirebaseMessaging.getInstance().subscribeToTopic(topic)
                        .addOnFailureListener(error -> runOnUiThread(() ->
                                Toast.makeText(AttendanceActivity.this,
                                        "긴급 알림 연결에 실패했습니다. 앱을 다시 열어주세요.",
                                        Toast.LENGTH_LONG).show()));
    }

    private void subscribeToUrgentTopic(String propertyId, String role) {
        String safeProperty = safeTopicPart(propertyId);
        if (safeProperty.isEmpty()) return;
        String safeRole = "owner".equals(role) ? "owner" : "staff";
        getSharedPreferences("omg_push", MODE_PRIVATE).edit()
                .putString("property_id", safeProperty)
                .putString("role", safeRole).apply();
        String staffTopic = "property_" + safeProperty + "_staff";
        if ("staff".equals(safeRole)) {
            // Telegram !! alerts belong only to the employee currently logged in.
            subscribeTopic("base_topic", staffTopic);
            return;
        }

        // Topic subscriptions survive role changes and app restarts. An owner
        // login must therefore explicitly remove the previous employee topic.
        String previous = getSharedPreferences("omg_push", MODE_PRIVATE)
                .getString("base_topic", "");
        getSharedPreferences("omg_push", MODE_PRIVATE).edit()
                .remove("base_topic").apply();
        if (!previous.isEmpty()) unsubscribeOwnerTopicSafely(previous, staffTopic);
        if (!staffTopic.equals(previous)) unsubscribeOwnerTopicSafely(staffTopic, staffTopic);
    }

    private void unsubscribeOwnerTopicSafely(String topic, String staffTopic) {
        FirebaseMessaging.getInstance().unsubscribeFromTopic(topic).addOnCompleteListener(task -> {
            // Switching from owner to staff can happen while this asynchronous
            // unsubscribe is still running. If staff is now the active session,
            // make the final operation a subscription so the employee never
            // loses urgent alerts because of that race.
            String currentRole = getSharedPreferences("omg_push", MODE_PRIVATE)
                    .getString("role", "");
            String currentProperty = getSharedPreferences("omg_push", MODE_PRIVATE)
                    .getString("property_id", "");
            String expectedTopic = "property_" + currentProperty + "_staff";
            if ("staff".equals(currentRole) && staffTopic.equals(expectedTopic)) {
                getSharedPreferences("omg_push", MODE_PRIVATE).edit()
                        .putString("base_topic", staffTopic).apply();
                FirebaseMessaging.getInstance().subscribeToTopic(staffTopic);
            }
        });
    }

    private void clearPushSession() {
        NativePushRegistration.clear(this);
        SupabaseMessageReceipt.clear(this);
        String baseTopic = getSharedPreferences("omg_push", MODE_PRIVATE)
                .getString("base_topic", "");
        String memberTopic = getSharedPreferences("omg_push", MODE_PRIVATE)
                .getString("member_topic", "");
        getSharedPreferences("omg_push", MODE_PRIVATE).edit().clear().apply();
        if (!baseTopic.isEmpty()) FirebaseMessaging.getInstance().unsubscribeFromTopic(baseTopic);
        if (!memberTopic.isEmpty()) FirebaseMessaging.getInstance().unsubscribeFromTopic(memberTopic);
        stopService(new Intent(this, EmergencyAlarmService.class));
    }

    private void subscribeToMemberTopic(String propertyId, String role, String memberId) {
        String safeProperty = safeTopicPart(propertyId);
        String safeMember = safeTopicPart(memberId);
        if (safeProperty.isEmpty() || safeMember.isEmpty()) return;
        String safeRole = "owner".equals(role) ? "owner" : "employee";
        getSharedPreferences("omg_push", MODE_PRIVATE).edit()
                .putString("member_id", safeMember).apply();
        subscribeTopic("member_topic",
                "property_" + safeProperty + "_" + safeRole + "_" + safeMember);
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        webView = new WebView(this);
        FrameLayout root = new FrameLayout(this);
        root.addView(webView, new FrameLayout.LayoutParams(-1, -1));
        setContentView(root);
        recovery = new WebViewRecovery(this, webView, root, appUrlFromIntent(getIntent()));

        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setCacheMode(WebSettings.LOAD_NO_CACHE);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        WebView.setWebContentsDebuggingEnabled(false);
        webView.addJavascriptInterface(new PushBridge(), "OMGNative");

        webView.setWebViewClient(new WebViewClient() {
            @Override public void onPageStarted(WebView view, String url, Bitmap icon) { recovery.started(url); }
            @Override public void onPageFinished(WebView view, String url) { recovery.finished(url); }
            @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) recovery.fail(request.getUrl().toString());
            }
            @Override public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse response) {
                if (request.isForMainFrame() && response.getStatusCode() >= 400) recovery.fail(request.getUrl().toString());
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return handleNavigation(view, request.getUrl());
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return handleNavigation(view, Uri.parse(url));
            }
        });
        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (fileCallback != null) fileCallback.onReceiveValue(null);
                fileCallback = callback;
                try {
                    startActivityForResult(params.createIntent(), FILE_CHOOSER_REQUEST);
                } catch (Exception error) {
                    fileCallback = null;
                    Toast.makeText(AttendanceActivity.this, "사진 선택기를 열지 못했습니다.", Toast.LENGTH_SHORT).show();
                    return false;
                }
                return true;
            }
        });
        // Always request the current page. Restoring WebView state can revive an old
        // document whose click handlers no longer match the deployed site.
        webView.loadUrl(appUrlFromIntent(getIntent()));
    }

    private String appUrlFromIntent(Intent intent) {
        Uri data = intent == null ? null : intent.getData();
        if (data == null || !"https".equals(data.getScheme())) return APP_URL;
        String host = data.getHost();
        if ("omgworks24.com".equals(host) || "www.omgworks24.com".equals(host))
            return data.toString();
        return APP_URL;
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (webView != null) webView.loadUrl(appUrlFromIntent(intent));
    }

    private final class PushBridge {
        @JavascriptInterface
        public void saveAttendanceExcel(String filename, String content) {
            runOnUiThread(() -> {
                Uri current = Uri.parse(webView == null || webView.getUrl() == null ? "" : webView.getUrl());
                boolean trusted = "https".equals(current.getScheme())
                        && ("omgworks24.com".equals(current.getHost()) || "www.omgworks24.com".equals(current.getHost())
                            || ("omgseoul.github.io".equals(current.getHost()) && "/oneminute/attendance.html".equals(current.getPath())))
                        && current.getPath() != null && current.getPath().endsWith("/attendance.html");
                if (!trusted || pendingExcel != null || content == null || content.length() > 16 * 1024 * 1024) return;
                try {
                    byte[] bytes = Base64.decode(content, Base64.DEFAULT);
                    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b || bytes[2] != 3 || bytes[3] != 4)
                        throw new IllegalArgumentException("Invalid workbook");
                    pendingExcel = bytes;
                    String safeName = filename == null ? "출퇴근기록.xlsx" : filename.replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]", "_");
                    if (!safeName.endsWith(".xlsx")) safeName += ".xlsx";
                    Intent save = new Intent(Intent.ACTION_CREATE_DOCUMENT);
                    save.addCategory(Intent.CATEGORY_OPENABLE);
                    save.setType("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
                    save.putExtra(Intent.EXTRA_TITLE, safeName);
                    startActivityForResult(save, EXCEL_SAVE_REQUEST);
                } catch (Exception error) {
                    pendingExcel = null;
                    Toast.makeText(AttendanceActivity.this, "엑셀 저장 화면을 열지 못했습니다. 다시 눌러주세요.", Toast.LENGTH_LONG).show();
                }
            });
        }

        @JavascriptInterface
        public void bindAppSession(String accessToken, String expiresAt) {
            SupabaseMessageReceipt.bind(AttendanceActivity.this, accessToken, expiresAt);
            NativePushRegistration.refresh(AttendanceActivity.this);
        }

        @JavascriptInterface
        public void registerPush(String propertyId, String role) {
            subscribeToUrgentTopic(propertyId, role);
        }

        @JavascriptInterface
        public void registerMemberPush(String propertyId, String role, String memberId) {
            subscribeToMemberTopic(propertyId, role, memberId);
        }

        @JavascriptInterface
        public void clearPushSession() {
            AttendanceActivity.this.clearPushSession();
        }
    }

    @Override
    protected void onStart() {
        super.onStart();
        NativePushRegistration.refresh(this);
        String propertyId = getSharedPreferences("omg_push", MODE_PRIVATE)
                .getString("property_id", "");
        String role = getSharedPreferences("omg_push", MODE_PRIVATE)
                .getString("role", "staff");
        String memberId = getSharedPreferences("omg_push", MODE_PRIVATE)
                .getString("member_id", "");
        if (!propertyId.isEmpty()) subscribeToUrgentTopic(propertyId, role);
        if (!propertyId.isEmpty() && !memberId.isEmpty())
            subscribeToMemberTopic(propertyId, role, memberId);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == EXCEL_SAVE_REQUEST) {
            final byte[] bytes = pendingExcel;
            pendingExcel = null;
            if (resultCode == Activity.RESULT_OK && data != null && data.getData() != null && bytes != null) {
                final Uri destination = data.getData();
                new Thread(() -> {
                    try (OutputStream output = getContentResolver().openOutputStream(destination)) {
                        if (output == null) throw new IllegalStateException("No destination");
                        output.write(bytes);
                        runOnUiThread(() -> Toast.makeText(this, "엑셀 파일을 저장했습니다.", Toast.LENGTH_SHORT).show());
                    } catch (Exception error) {
                        runOnUiThread(() -> Toast.makeText(this, "엑셀 저장에 실패했습니다. 다시 눌러주세요.", Toast.LENGTH_LONG).show());
                    }
                }).start();
            }
            return;
        }
        if (requestCode == FILE_CHOOSER_REQUEST && fileCallback != null) {
            Uri[] result = resultCode == Activity.RESULT_OK
                    ? WebChromeClient.FileChooserParams.parseResult(resultCode, data) : null;
            fileCallback.onReceiveValue(result);
            fileCallback = null;
            return;
        }
        super.onActivityResult(requestCode, resultCode, data);
    }

    private boolean handleNavigation(WebView view, Uri uri) {
        if ("mailto".equals(uri.getScheme())) {
            try {
                startActivity(new Intent(Intent.ACTION_SENDTO, uri));
            } catch (Exception error) {
                Toast.makeText(this, "메일 앱을 열 수 없습니다.", Toast.LENGTH_SHORT).show();
            }
            return true;
        }
        if ("guesthouse".equals(uri.getScheme())) {
            String action = uri.getHost();
            if ("emergency".equals(action)) {
                startActivity(new Intent(this, EmergencyReportActivity.class));
            } else if ("mission".equals(action)) {
                webView.loadUrl(MISSION_URL);
            } else if ("inbox".equals(action)) {
                startActivity(new Intent(this, OwnerInboxActivity.class));
            }
            return true;
        }

        String host = uri.getHost();
        String path = uri.getPath();
        boolean isCustomDomain = "omgworks24.com".equals(host) || "www.omgworks24.com".equals(host);
        boolean isLegacyDomain = "omgseoul.github.io".equals(host)
                && path != null && path.startsWith("/oneminute/");
        boolean isAppPage = "https".equals(uri.getScheme()) && (isCustomDomain || isLegacyDomain);
        if (isAppPage) {
            // Explicit loading is more reliable than returning false on Samsung
            // Android WebView, where a consumed DOM click can otherwise stop here.
            view.loadUrl(uri.toString());
            return true;
        }

        if ("http".equals(uri.getScheme()) || "https".equals(uri.getScheme())) {
            startActivity(new Intent(Intent.ACTION_VIEW, uri));
        }
        return true;
    }

    @Override
    public void onBackPressed() {
        if (webView == null) {
            moveTaskToBack(true);
            return;
        }
        Uri current = Uri.parse(webView.getUrl() == null ? APP_URL : webView.getUrl());
        String path = current.getPath();
        boolean isMainPage = path == null || "/".equals(path) || path.endsWith("/app.html");
        if (!isMainPage && webView.canGoBack()) webView.goBack();
        else moveTaskToBack(true);
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        if (webView != null) webView.saveState(outState);
        super.onSaveInstanceState(outState);
    }

    @Override
    protected void onResume() { super.onResume(); if (recovery != null) recovery.resume(); }

    @Override
    protected void onPause() { if (recovery != null) recovery.pause(); super.onPause(); }

    @Override
    protected void onDestroy() {
        if (recovery != null) recovery.destroy();
        if (webView != null) {
            webView.stopLoading();
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }
}
