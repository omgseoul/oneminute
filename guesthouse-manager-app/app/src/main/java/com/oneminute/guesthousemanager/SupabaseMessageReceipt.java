package com.oneminute.guesthousemanager;
import android.content.Context;
import android.content.SharedPreferences;
import org.json.JSONObject;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Shares the WebView's short-lived Supabase work-session authorization. */
final class SupabaseMessageReceipt {
 private static final ExecutorService worker=Executors.newSingleThreadExecutor();
 private static final String API="https://rfcozgyvupvachhhblzn.supabase.co/rest/v1/rpc/mark_property_message_read";
 private static final String KEY="sb_publishable_Gy0_TtIcJ6xKDEiGWEnXAg_f4_eyXPI";
 private static SharedPreferences prefs(Context c){return c.getSharedPreferences("omg_receipts",Context.MODE_PRIVATE);}
 static synchronized void bind(Context c,String token,String expires){
  if(token==null||!token.matches("[0-9a-fA-F-]{36}"))return;
  try{if(Instant.parse(expires).toEpochMilli()<=System.currentTimeMillis())return;}catch(Exception e){return;}
  SharedPreferences p=prefs(c);
  if(!token.equals(p.getString("token","")))p.edit().clear().apply();
  p.edit().putString("token",token).putString("expires",expires).apply();flush(c.getApplicationContext());
 }
 static synchronized void clear(Context c){prefs(c).edit().clear().apply();}
 static synchronized void acknowledge(Context c,String id){
  if(id==null||!id.matches("[0-9a-fA-F-]{36}"))return;
  SharedPreferences p=prefs(c);Set<String> pending=new HashSet<>(p.getStringSet("pending",new HashSet<>()));
  pending.add(id);p.edit().putStringSet("pending",pending).apply();flush(c.getApplicationContext());
 }
 private static void flush(Context c){worker.execute(()->{
  SharedPreferences p=prefs(c);String token=p.getString("token",""),expires=p.getString("expires","");
  try{if(token.isEmpty()||Instant.parse(expires).toEpochMilli()<=System.currentTimeMillis())return;}catch(Exception e){return;}
  for(String id:new HashSet<>(p.getStringSet("pending",new HashSet<>()))) {
   if(!token.equals(p.getString("token","")))return;
   HttpURLConnection connection=null;
   try{
    connection=(HttpURLConnection)new URL(API).openConnection();connection.setRequestMethod("POST");connection.setDoOutput(true);
    connection.setConnectTimeout(3000);connection.setReadTimeout(3000);connection.setRequestProperty("apikey",KEY);
    connection.setRequestProperty("Content-Type","application/json");
    byte[] body=new JSONObject().put("p_access_token",token).put("p_message_id",id).toString().getBytes(StandardCharsets.UTF_8);
    try(java.io.OutputStream output=connection.getOutputStream()){output.write(body);}
    if(connection.getResponseCode()!=200)continue;
    StringBuilder response=new StringBuilder();
    try(java.io.BufferedReader reader=new java.io.BufferedReader(new java.io.InputStreamReader(connection.getInputStream(),StandardCharsets.UTF_8))){String line;while((line=reader.readLine())!=null)response.append(line);}
    if(new JSONObject(response.toString()).optBoolean("ok")) synchronized(SupabaseMessageReceipt.class){
     if(token.equals(p.getString("token",""))){Set<String> pending=new HashSet<>(p.getStringSet("pending",new HashSet<>()));pending.remove(id);p.edit().putStringSet("pending",pending).apply();}
    }
   }catch(Exception ignored){/* Retry after the next validated WebView session; keep unread on failure. */}
   finally{if(connection!=null)connection.disconnect();}
  }
 });}
}
