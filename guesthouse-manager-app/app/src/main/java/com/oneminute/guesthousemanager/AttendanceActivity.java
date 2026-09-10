package com.oneminute.guesthousemanager;
import android.os.Bundle; import android.webkit.*; import androidx.appcompat.app.AppCompatActivity;
public class AttendanceActivity extends AppCompatActivity {
 private WebView webView;
 @Override protected void onCreate(Bundle b){super.onCreate(b); webView=new WebView(this); setContentView(webView); webView.getSettings().setJavaScriptEnabled(true); webView.getSettings().setDomStorageEnabled(true); webView.setWebViewClient(new WebViewClient()); webView.setWebChromeClient(new WebChromeClient()); webView.loadUrl("https://omgseoul.github.io/oneminute/index.html");}
 @Override public void onBackPressed(){if(webView!=null&&webView.canGoBack())webView.goBack();else super.onBackPressed();}
}
