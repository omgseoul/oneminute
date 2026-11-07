package com.oneminute.guesthousemanager;
import android.app.*;
import android.content.*;
import android.os.*;
import android.text.InputType;
import android.view.inputmethod.*;
import android.widget.FrameLayout;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

final class LoginImeProbe {
 static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
 static void run(Instrumentation test){Bundle out=new Bundle();Activity activity=null;
  try{
   EditorInfo text=new EditorInfo();text.inputType=InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;text.imeOptions=EditorInfo.IME_FLAG_FORCE_ASCII;
   MultilingualWebView.configureLoginEditor(text);check((text.imeOptions&EditorInfo.IME_FLAG_FORCE_ASCII)==0,"username allows non-ASCII");check((text.inputType&InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS)==0,"username preserves composition");
   EditorInfo pin=new EditorInfo();pin.inputType=InputType.TYPE_CLASS_NUMBER|InputType.TYPE_NUMBER_VARIATION_PASSWORD;int original=pin.inputType;MultilingualWebView.configureLoginEditor(pin);check(pin.inputType==original,"PIN stays numeric/password");
   activity=test.startActivitySync(new Intent(test.getTargetContext(),AttendanceActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));final Activity screen=activity;
   AtomicReference<MultilingualWebView> ref=new AtomicReference<>();CountDownLatch loaded=new CountDownLatch(1);
   test.runOnMainSync(()->{MultilingualWebView web=new MultilingualWebView(screen);ref.set(web);web.getSettings().setJavaScriptEnabled(true);screen.setContentView(web);web.setWebViewClient(new android.webkit.WebViewClient(){@Override public void onPageFinished(android.webkit.WebView v,String url){v.requestFocus();v.evaluateJavascript("document.getElementById('employeeLoginId').focus()",x->loaded.countDown());}});web.loadDataWithBaseURL("https://omgworks24.com/login.html","<html lang='ko'><body><input id='employeeLoginId' type='text' inputmode='text' lang='ko' autocomplete='username'><input type='password' inputmode='numeric'></body></html>","text/html","UTF-8",null);});
   check(loaded.await(15,TimeUnit.SECONDS),"login fixture loaded");Thread.sleep(800);
   AtomicReference<InputConnection> connection=new AtomicReference<>();test.runOnMainSync(()->connection.set(ref.get().onCreateInputConnection(new EditorInfo())));check(connection.get()!=null,"first focus has input connection");
   CountDownLatch composed=new CountDownLatch(1);AtomicReference<Throwable> failure=new AtomicReference<>();InputConnection c=connection.get();Handler handler=c.getHandler();if(handler==null)handler=new Handler(Looper.getMainLooper());
   handler.post(()->{try{c.beginBatchEdit();for(String syllable:new String[]{"ㅎ","하","한"})c.setComposingText(syllable,1);c.commitText("한글아이디",1);c.endBatchEdit();}catch(Throwable e){failure.set(e);}finally{composed.countDown();}});
   check(composed.await(10,TimeUnit.SECONDS)&&failure.get()==null,"IME composition accepted");Thread.sleep(500);
   CountDownLatch valueReady=new CountDownLatch(1);AtomicReference<String> value=new AtomicReference<>();test.runOnMainSync(()->ref.get().evaluateJavascript("document.getElementById('employeeLoginId').value",v->{value.set(v);valueReady.countDown();}));check(valueReady.await(5,TimeUnit.SECONDS),"DOM value read");check("\"한글아이디\"".equals(value.get()),"first-focus Korean composition: "+value.get());
   out.putString("oms_login_ime","ok");test.finish(-1,out);
  }catch(Throwable e){out.putString("oms_login_ime","failed: "+e);test.finish(0,out);}finally{if(activity!=null){final Activity a=activity;test.runOnMainSync(a::finish);}}
 }
}
