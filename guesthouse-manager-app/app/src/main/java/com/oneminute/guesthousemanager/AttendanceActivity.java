package com.oneminute.guesthousemanager;

import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;
import androidx.appcompat.app.AppCompatActivity;

public class AttendanceActivity extends AppCompatActivity {
    private static final String LOGIN_URL = "https://omgseoul.github.io/oneminute/login.html";
    private WebView webView;

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
        webView.setWebChromeClient(new WebChromeClient());
        webView.loadUrl(LOGIN_URL);
    }

    private boolean handleNavigation(Uri uri) {
        if ("guesthouse".equals(uri.getScheme())) {
            String action = uri.getHost();
            if ("emergency".equals(action)) {
                startActivity(new Intent(this, EmergencyReportActivity.class));
            } else if ("mission".equals(action)) {
                Toast.makeText(this, "미션 기능은 다음 버전에 추가됩니다.", Toast.LENGTH_SHORT).show();
            } else if ("inbox".equals(action)) {
                Toast.makeText(this, "사장님 확인함은 사장 계정에서 이용해주세요.", Toast.LENGTH_SHORT).show();
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
