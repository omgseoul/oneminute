package com.oneminute.guesthousemanager;

import android.webkit.WebView;
import java.io.*;
import java.nio.charset.StandardCharsets;

/** Debug-only offline fixture: the actual host, bridge and WebViewClient are used. */
public final class ChatHandoffProbeActivity extends AttendanceActivity {
    @Override protected void checkAppUpdate() {}
    @Override protected void loadInitialAppPage(WebView view,String ignored) {
        try(InputStream in=getAssets().open("chat-handoff.html")) {
            ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] bytes=new byte[4096];int n;
            while((n=in.read(bytes))!=-1)out.write(bytes,0,n);
            String url="https://omgworks24.com/messages.html?tab=staff";
            view.loadDataWithBaseURL(url,new String(out.toByteArray(),StandardCharsets.UTF_8),"text/html","UTF-8",url);
        }catch(IOException e){throw new IllegalStateException(e);}
    }
}
