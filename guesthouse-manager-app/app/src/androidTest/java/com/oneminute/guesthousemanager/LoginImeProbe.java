package com.oneminute.guesthousemanager;
import android.app.*;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.content.*;
import android.os.*;
import android.view.*;
import android.view.accessibility.*;
import android.webkit.WebView;
import android.widget.EditText;
import java.io.*;
import java.lang.reflect.Field;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

final class LoginImeProbe {
 static void check(boolean v,String m){if(!v)throw new AssertionError(m);}
 static String shell(Instrumentation t,String cmd)throws Exception{try(InputStream in=new ParcelFileDescriptor.AutoCloseInputStream(t.getUiAutomation().executeShellCommand(cmd))){ByteArrayOutputStream b=new ByteArrayOutputStream();byte[] chunk=new byte[1024];int n;while((n=in.read(chunk))>0)b.write(chunk,0,n);return b.toString("UTF-8").trim();}}
 static Object field(Object o,String name)throws Exception{Field f=AttendanceActivity.class.getDeclaredField(name);f.setAccessible(true);return f.get(o);}
 static String js(Instrumentation t,WebView web,String code)throws Exception{CountDownLatch done=new CountDownLatch(1);AtomicReference<String> result=new AtomicReference<>();t.runOnMainSync(()->web.evaluateJavascript(code,v->{result.set(v);done.countDown();}));check(done.await(8,TimeUnit.SECONDS),"JS timeout");return result.get();}
 static void tap(Instrumentation t,View view)throws Exception{int[] p=new int[2];t.runOnMainSync(()->view.getLocationOnScreen(p));long now=SystemClock.uptimeMillis();float x=p[0]+view.getWidth()/2f,y=p[1]+view.getHeight()/2f;t.sendPointerSync(MotionEvent.obtain(now,now,MotionEvent.ACTION_DOWN,x,y,0));t.sendPointerSync(MotionEvent.obtain(now,now+80,MotionEvent.ACTION_UP,x,y,0));}
 static void key(Instrumentation t,String text)throws Exception{for(int attempt=0;attempt<60;attempt++){for(AccessibilityWindowInfo window:t.getUiAutomation().getWindows()){AccessibilityNodeInfo root=window.getRoot();if(root==null)continue;for(AccessibilityNodeInfo n:root.findAccessibilityNodeInfosByText(text)){if(text.contentEquals(n.getText())&&n.performAction(AccessibilityNodeInfo.ACTION_CLICK)){Thread.sleep(250);return;}}}Thread.sleep(100);}throw new AssertionError("IME key missing: "+text);}
 static void run(Instrumentation test){Bundle out=new Bundle();Activity activity=null;String previous="";
  try{
   previous=shell(test,"settings get secure default_input_method");String ime=test.getContext().getPackageName()+"/com.oneminute.guesthousemanager.TestHangulIme";shell(test,"ime enable "+ime);shell(test,"ime set "+ime);shell(test,"settings put secure show_ime_with_hard_keyboard 1");
   AccessibilityServiceInfo info=test.getUiAutomation().getServiceInfo();info.flags|=AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;test.getUiAutomation().setServiceInfo(info);
   activity=test.startActivitySync(new Intent().setClassName(test.getTargetContext(),"com.oneminute.guesthousemanager.LoginImeTestActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
   WebView web=(WebView)field(activity,"webView");NativeLoginInput control=(NativeLoginInput)field(activity,"loginInput");EditText editor=control.editorForTest();
   for(int i=0;i<80&&editor.getVisibility()!=View.VISIBLE;i++)Thread.sleep(100);check(editor.getVisibility()==View.VISIBLE,"native username visible: "+js(test,web,"JSON.stringify({url:location.href,bridge:typeof OMSLoginInput,adapter:typeof OMSNativeLoginInput,ready:document.getElementById('loginShell')?.className,message:document.getElementById('message')?.textContent,rect:document.getElementById('employeeLoginId')?.getBoundingClientRect().toJSON()})"));
   // First user tap, then the real Android IME connection sends composing syllables.
   tap(test,editor);key(test,"한글 조합 입력");key(test,"영문 입력");check("\"한글abc\"".equals(js(test,web,"document.getElementById('employeeLoginId').value")),"first-focus Hangul/Latin reaches real form");
   key(test,"다음 입력칸");check("\"pin\"".equals(js(test,web,"document.activeElement.id")),"Next moves to PIN");
   js(test,web,"setRole('admin')");Thread.sleep(300);check(editor.getVisibility()==View.GONE,"native username hidden in admin tab");js(test,web,"setRole('staff')");Thread.sleep(300);check(editor.getVisibility()==View.VISIBLE,"staff tab restores native username");
   check("\"한글abc\"".equals(js(test,web,"document.getElementById('employeeLoginId').value")),"switching tabs preserves entered ID");
   js(test,web,"document.getElementById('pin').value='123456';document.getElementById('loginForm').requestSubmit()");Thread.sleep(300);check("\"한글abc\"".equals(js(test,web,"window.testSubmittedLoginId")),"real submit receives composed username");
   try(FileOutputStream f=test.getTargetContext().openFileOutput("native-login-ime.png",0)){test.getUiAutomation().takeScreenshot().compress(android.graphics.Bitmap.CompressFormat.PNG,100,f);}
   out.putString("oms_login_ime","ok");test.finish(-1,out);
  }catch(Throwable e){try{if(activity!=null){WebView w=(WebView)field(activity,"webView");test.runOnMainSync(()->out.putString("web_url",w.getUrl()));}try(FileOutputStream f=test.getTargetContext().openFileOutput("native-login-ime.png",0)){test.getUiAutomation().takeScreenshot().compress(android.graphics.Bitmap.CompressFormat.PNG,100,f);}}catch(Exception ignored){}out.putString("oms_login_ime","failed: "+e);test.finish(0,out);}finally{try{if(!previous.isEmpty()&&!previous.equals("null"))shell(test,"ime set "+previous);}catch(Exception ignored){}if(activity!=null){final Activity a=activity;test.runOnMainSync(a::finish);}}
 }
}
