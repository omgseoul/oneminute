package com.oneminute.guesthousemanager;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import android.widget.Toast;
import com.google.firebase.messaging.FirebaseMessaging;
import org.json.JSONObject;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;

/** A device binding independent of WebView visibility or topic propagation. */
final class NativePushRegistration {
 private static final ExecutorService worker=Executors.newSingleThreadExecutor();
 private static final Handler main=new Handler(Looper.getMainLooper());
 private static final String API="https://rfcozgyvupvachhhblzn.supabase.co/rest/v1/rpc/";
 private static final String KEY="sb_publishable_Gy0_TtIcJ6xKDEiGWEnXAg_f4_eyXPI";
 private static SharedPreferences prefs(Context c){return c.getSharedPreferences("omg_device_push",Context.MODE_PRIVATE);}
 static synchronized void refresh(Context context){refresh(context,0);}
 private static synchronized void refresh(Context context,int attempt){
  Context c=context.getApplicationContext();SharedPreferences p=prefs(c),session=c.getSharedPreferences("omg_receipts",Context.MODE_PRIVATE);
  String access=session.getString("token",""),expiry=session.getString("expires","");
  try{if(access.isEmpty()||Instant.parse(expiry).toEpochMilli()<=System.currentTimeMillis())return;}catch(Exception e){return;}
  if(access.equals(p.getString("registered_session",""))&&System.currentTimeMillis()-p.getLong("registered_at",0)<600000)return;
  String device=p.getString("device_id","");if(device.isEmpty()){device=UUID.randomUUID().toString();p.edit().putString("device_id",device).apply();}
  final String deviceId=device;
  FirebaseMessaging.getInstance().getToken().addOnSuccessListener(token->worker.execute(()->{
   if(!access.equals(session.getString("token","")))return;
   try{
    JSONObject result=call("register_native_push",new JSONObject().put("p_access_token",access).put("p_device_id",deviceId).put("p_fcm_token",token));
    if(!result.optBoolean("ok"))throw new Exception("registration_failed");
    if(access.equals(session.getString("token","")))p.edit().putString("registered_session",access).putString("actor_key",result.getString("actor_key")).putLong("registered_at",System.currentTimeMillis()).apply();
   }catch(Exception error){retry(c,attempt,access);}
  })).addOnFailureListener(error->retry(c,attempt,access));
 }
 private static void retry(Context c,int attempt,String access){
  if(!access.equals(c.getSharedPreferences("omg_receipts",Context.MODE_PRIVATE).getString("token","")))return;
  if(attempt<3)main.postDelayed(()->refresh(c,attempt+1),5000L*(attempt+1));
  else main.post(()->Toast.makeText(c,"휴대폰 알림 연결에 실패했습니다. 인터넷 연결 후 앱을 다시 열어주세요.",Toast.LENGTH_LONG).show());
 }
 static void tokenChanged(Context c){prefs(c).edit().remove("registered_at").apply();refresh(c);}
 static void clear(Context context){
  Context c=context.getApplicationContext();SharedPreferences p=prefs(c);
  String access=c.getSharedPreferences("omg_receipts",Context.MODE_PRIVATE).getString("token",""),device=p.getString("device_id","");
  p.edit().remove("registered_session").remove("registered_at").remove("actor_key").apply();
  if(access.isEmpty()||device.isEmpty())return;
  worker.execute(()->{try{call("unregister_native_push",new JSONObject().put("p_access_token",access).put("p_device_id",device));}catch(Exception ignored){/* Expired sessions are also excluded by server routing. */}});
 }
 private static JSONObject call(String rpc,JSONObject body)throws Exception{
  HttpURLConnection connection=(HttpURLConnection)new URL(API+rpc).openConnection();
  try{
   connection.setRequestMethod("POST");connection.setDoOutput(true);connection.setConnectTimeout(5000);connection.setReadTimeout(5000);
   connection.setRequestProperty("apikey",KEY);connection.setRequestProperty("Content-Type","application/json");
   try(java.io.OutputStream out=connection.getOutputStream()){out.write(body.toString().getBytes(StandardCharsets.UTF_8));}
   if(connection.getResponseCode()!=200)throw new Exception("registration_http_error");
   StringBuilder response=new StringBuilder();try(java.io.BufferedReader reader=new java.io.BufferedReader(new java.io.InputStreamReader(connection.getInputStream(),StandardCharsets.UTF_8))){String line;while((line=reader.readLine())!=null)response.append(line);}
   return new JSONObject(response.toString());
  }finally{connection.disconnect();}
 }
}
