package com.oneminute.guesthousemanager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.content.SharedPreferences;
import java.time.Instant;
import java.util.Map;
final class GuestChatAlerts {
 static boolean accept(Context c,Map<String,String> data){
  String room=data.get("roomId"),recipient=data.get("recipientKey");
  if(room==null||!room.matches("[0-9a-fA-F-]{36}"))return false;
  SharedPreferences p=c.getSharedPreferences("omg_push",Context.MODE_PRIVATE);
  String role=p.getString("role","");String actor=("owner".equals(role)?"owner:":"employee:")+p.getString("member_id","");
  if(!actor.equals(recipient))return false;
  try{if(Long.parseLong(data.get("validUntil"))<System.currentTimeMillis())return false;
   if(Instant.parse(c.getSharedPreferences("omg_receipts",Context.MODE_PRIVATE).getString("expires","")).toEpochMilli()<=System.currentTimeMillis())return false;
  }catch(Exception e){return false;}
  return true;
 }
 static String url(String room){return "https://omgworks24.com/guest-chat.html?room="+Uri.encode(room);}
 static void remember(Context c,String id,String room){
  if(id==null||room==null)return;
  SharedPreferences p=c.getSharedPreferences("omg_guest_alerts",Context.MODE_PRIVATE);
  if(p.getAll().size()>150)p.edit().clear().apply();
  p.edit().putString(id,room).apply();
 }
 static String room(Context c,String id){return id==null?null:c.getSharedPreferences("omg_guest_alerts",Context.MODE_PRIVATE).getString(id,null);}
 static boolean open(Context c,String id){String room=room(c,id);if(room==null)return false;
  c.startActivity(new Intent(c,AttendanceActivity.class).setData(Uri.parse(url(room))).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_SINGLE_TOP));return true;
 }
}
