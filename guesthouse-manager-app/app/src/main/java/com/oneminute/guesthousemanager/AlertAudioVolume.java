package com.oneminute.guesthousemanager;

import android.content.Context;
import android.content.SharedPreferences;
import android.media.AudioManager;

/** Shared lease prevents a short message tone from restoring volume during an urgent alarm. */
final class AlertAudioVolume {
 static synchronized void acquire(Context c,boolean urgent){
  AudioManager audio=(AudioManager)c.getSystemService(Context.AUDIO_SERVICE);
  if(audio==null||audio.isVolumeFixed())return;
  SharedPreferences p=c.getSharedPreferences("omg_alert_audio",Context.MODE_PRIVATE);
  try{
   SharedPreferences.Editor edit=p.edit().putBoolean(urgent?"urgent":"normal",true);
   if(!p.contains("original"))edit.putInt("original",audio.getStreamVolume(AudioManager.STREAM_ALARM));
   edit.commit();
   int max=audio.getStreamMaxVolume(AudioManager.STREAM_ALARM);
   if(urgent)audio.setStreamVolume(AudioManager.STREAM_ALARM,max,0);
   else if(audio.getStreamVolume(AudioManager.STREAM_ALARM)==0)audio.setStreamVolume(AudioManager.STREAM_ALARM,Math.max(1,max/2),0);
  }catch(SecurityException ignored){}
 }
 static synchronized void release(Context c,boolean urgent){
  SharedPreferences p=c.getSharedPreferences("omg_alert_audio",Context.MODE_PRIVATE);
  p.edit().remove(urgent?"urgent":"normal").commit();
  if(p.getBoolean("urgent",false)||p.getBoolean("normal",false)||!p.contains("original"))return;
  try{AudioManager audio=(AudioManager)c.getSystemService(Context.AUDIO_SERVICE);if(audio!=null)audio.setStreamVolume(AudioManager.STREAM_ALARM,p.getInt("original",0),0);}
  catch(SecurityException ignored){}finally{p.edit().clear().apply();}
 }
}
