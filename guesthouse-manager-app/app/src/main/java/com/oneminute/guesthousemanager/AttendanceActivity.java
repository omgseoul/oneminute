package com.oneminute.guesthousemanager;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.webkit.ValueCallback;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;
import androidx.appcompat.app.AppCompatActivity;
import com.google.firebase.messaging.FirebaseMessaging;

public class AttendanceActivity extends AppCompatActivity {
    private static final String APP_URL = "https://omgworks24.com/app.html";
    private static final String MISSION_URL = "https://omgworks24.com/mission.html";
    private static final int FILE_CHOOSER_REQUEST = 2201;
    private WebView webView;
    private ValueCallback<Uri[]> fileCallback;

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
        FirebaseMessaging.getInstance().getToken().addOnSuccessListener(token ->
                FirebaseMessaging.getInstance().subscribeToTopic(topic)
                        .addOnFailureListener(error -> runOnUiThread(() ->
                                Toast.makeText(AttendanceActivity.this,
                                        "긴급 알림 연결에 실패했습니다. 앱을 다시 열어주세요.",
                                        Toast.LENGTH_LONG).show())));
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
        setContentView(webView);

        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setCacheMode(WebSettings.LOAD_NO_CACHE);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        WebView.setWebContentsDebuggingEnabled(false);
        webView.addJavascriptInterface(new PushBridge(), "OMGNative");

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return handleNavigation(request.getUrl());
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return handleNavigation(Uri.parse(url));
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
        if (state == null || webView.restoreState(state) == null) {
            // app.html validates the persisted work session and only returns to login
            // after an explicit logout or a successful checkout report.
            webView.loadUrl(appUrlFromIntent(getIntent()));
        }
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
        public void bindAppSession(String accessToken, String expiresAt) {
            SupabaseMessageReceipt.bind(AttendanceActivity.this, accessToken, expiresAt);
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
        if (requestCode == FILE_CHOOSER_REQUEST && fileCallback != null) {
            Uri[] result = resultCode == Activity.RESULT_OK
                    ? WebChromeClient.FileChooserParams.parseResult(resultCode, data) : null;
            fileCallback.onReceiveValue(result);
            fileCallback = null;
            return;
        }
        super.onActivityResult(requestCode, resultCode, data);
    }

    private boolean handleNavigation(Uri uri) {
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
        if (isAppPage) return false;

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
    protected void onDestroy() {
        if (webView != null) {
            webView.stopLoading();
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }
}
