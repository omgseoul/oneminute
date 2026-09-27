package com.oneminute.guesthousemanager;

import android.app.Notification;
import android.app.Service;
import android.content.Intent;
import android.content.SharedPreferences;
import android.media.AudioAttributes;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;

/** Finite ordinary-message sound; never replaces the urgent countdown service. */
public class MessageSoundService extends Service {
 private final Handler handler=new Handler(Looper.getMainLooper());
 private MediaPlayer player;

 private final Runnable finish=()->{stopForeground(STOP_FOREGROUND_DETACH);stopSelf();};
 @Override public int onStartCommand(Intent intent,int flags,int startId){
  if(intent==null){stopSelf();return START_NOT_STICKY;}
  Notification notification=intent.getParcelableExtra("notification");
  if(notification==null){stopSelf();return START_NOT_STICKY;}
  startForeground(intent.getIntExtra("notificationId",9010),notification);
  handler.removeCallbacks(finish);releasePlayer();
  AudioAttributes attributes=new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build();
  Vibrator vibrator=(Vibrator)getSystemService(VIBRATOR_SERVICE);
  if(vibrator!=null&&vibrator.hasVibrator())vibrator.vibrate(VibrationEffect.createWaveform(new long[]{0,250,120,350},-1),attributes);
  try{
   AudioManager audio=(AudioManager)getSystemService(AUDIO_SERVICE);
   SharedPreferences urgent=getSharedPreferences("omg_urgent_volume",MODE_PRIVATE);
   // An active urgent alarm owns the audio stream and must not be interrupted.
   if(!urgent.contains("original")){
    AlertAudioVolume.acquire(this,false);
    Uri tone=RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION);
    if(tone==null)tone=RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM);
    player=new MediaPlayer();player.setAudioAttributes(attributes);player.setDataSource(this,tone);player.setVolume(1,1);player.setOnCompletionListener(p->finish.run());player.setOnErrorListener((p,w,e)->{finish.run();return true;});player.prepare();player.start();
   }
  }catch(Exception ignored){/* The visible notification and vibration remain available. */}
  handler.postDelayed(finish,4000);
  return START_NOT_STICKY;
 }
 private void releasePlayer(){if(player!=null){try{player.stop();}catch(Exception ignored){}player.release();player=null;}}
 @Override public void onDestroy(){handler.removeCallbacks(finish);releasePlayer();AlertAudioVolume.release(this,false);super.onDestroy();}
 @Override public IBinder onBind(Intent intent){return null;}
}
