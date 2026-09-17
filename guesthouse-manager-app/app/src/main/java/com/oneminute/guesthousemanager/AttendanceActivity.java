package com.oneminute.guesthousemanager;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;
import androidx.appcompat.app.AppCompatActivity;

public class AttendanceActivity extends AppCompatActivity {
    private static final String LOGIN_URL = "https://omgseoul.github.io/oneminute/login.html";
    private static final int FILE_CHOOSER_REQUEST = 2201;
    private WebView webView;
    private ValueCallback<Uri[]> fileCallback;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        webView = new WebView(this);
        setContentView(webView);

        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        WebView.setWebContentsDebuggingEnabled(false);

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
        webView.loadUrl(LOGIN_URL);
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
                webView.loadUrl("https://omgseoul.github.io/oneminute/mission.html");
            } else if ("inbox".equals(action)) {
                startActivity(new Intent(this, OwnerInboxActivity.class));
            }
            return true;
        }

        boolean isAppPage = "https".equals(uri.getScheme())
                && "omgseoul.github.io".equals(uri.getHost())
                && uri.getPath() != null
                && uri.getPath().startsWith("/oneminute/");
        if (isAppPage) return false;

        if ("http".equals(uri.getScheme()) || "https".equals(uri.getScheme())) {
            startActivity(new Intent(Intent.ACTION_VIEW, uri));
        }
        return true;
    }

    @Override
    public void onBackPressed() {
        if (webView != null && webView.canGoBack()) webView.goBack();
        else super.onBackPressed();
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
