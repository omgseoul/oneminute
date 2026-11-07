package com.oneminute.guesthousemanager;
import android.webkit.WebView;
import java.io.*;
import java.nio.charset.StandardCharsets;
public class LoginImeTestActivity extends AttendanceActivity {
 @Override protected void loadInitialAppPage(WebView web,String url){try(InputStream in=getAssets().open("login-ime-fixture.html")){ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] b=new byte[8192];int n;while((n=in.read(b))>0)out.write(b,0,n);web.loadDataWithBaseURL("https://omgworks24.com/login.html",out.toString("UTF-8"),"text/html","UTF-8",null);}catch(Exception e){throw new RuntimeException(e);}}
}
