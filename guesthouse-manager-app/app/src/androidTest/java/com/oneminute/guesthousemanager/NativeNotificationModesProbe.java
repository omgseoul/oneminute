package com.oneminute.guesthousemanager;

import android.app.*;
import android.content.*;
import android.media.AudioManager;
import android.media.AudioAttributes;
import android.service.notification.StatusBarNotification;
import com.google.firebase.messaging.RemoteMessage;
import java.util.*;

/** Synthetic FCM receipt: weak mode must survive the immediate unread refresh. */
final class NativeNotificationModesProbe {
    private static void check(boolean ok,String message){if(!ok)throw new AssertionError(message);}
    private static Notification active(NotificationManager manager,String channel,int count)throws Exception{
        long end=System.currentTimeMillis()+3000;
        while(System.currentTimeMillis()<end){for(StatusBarNotification n:manager.getActiveNotifications())if(n.getId()==NativeMessageBadge.ID&&channel.equals(n.getNotification().getChannelId())&&n.getNotification().number==count)return n.getNotification();Thread.sleep(25);}
        throw new AssertionError("Expected weak notification");
    }
    private static final class TestService extends GuesthouseMessagingService {TestService(Context context){attachBaseContext(context);}}
    static void verify(Context c,String token)throws Exception{
        NotificationManager manager=c.getSystemService(NotificationManager.class);
        AudioManager audio=c.getSystemService(AudioManager.class);int ringer=audio.getRingerMode();
        SharedPreferences push=c.getSharedPreferences("omg_push",0);Map<String,?> oldPush=new HashMap<>(push.getAll());
        String weak=GuesthouseMessagingService.WEAK_MESSAGE_CHANNEL_ID,legacy="property_messages_weak_status_v3";
        try{
            // All channels and sessions here belong to the isolated CI emulator.
            manager.deleteNotificationChannel(weak);manager.deleteNotificationChannel(legacy);
            NotificationChannel actual=GuesthouseMessagingService.ensureWeakChannel(c);
            check(actual.getImportance()==NotificationManager.IMPORTANCE_DEFAULT,"Weak has no heads-up importance");
            check(actual.shouldVibrate()&&Arrays.equals(actual.getVibrationPattern(),GuesthouseMessagingService.MESSAGE_VIBRATION),"Weak uses normal message vibration pattern");
            check(actual.getAudioAttributes().getUsage()==AudioAttributes.USAGE_NOTIFICATION,"Weak obeys notification audio policy");
            NotificationChannel old=new NotificationChannel("legacy-probe","Synthetic user preference",NotificationManager.IMPORTANCE_LOW);
            old.enableVibration(false);old.setSound(null,null);
            NotificationChannel migrated=GuesthouseMessagingService.weakChannelDefaults("oms_migration_probe_"+UUID.randomUUID(),old);
            manager.createNotificationChannel(migrated);migrated=manager.getNotificationChannel(migrated.getId());
            check(migrated.getImportance()==NotificationManager.IMPORTANCE_LOW&&!migrated.shouldVibrate()&&migrated.getSound()==null,"Migration preserves system-channel opt-outs");
            manager.deleteNotificationChannel(migrated.getId());
            push.edit().putString("role","owner").putString("member_id","synthetic-notification-owner").commit();
            audio.setRingerMode(AudioManager.RINGER_MODE_VIBRATE);
            NativeMessageBadge.fromWeb(c,token,7);
            String id="probe-"+UUID.randomUUID();
            new TestService(c).onMessageReceived(new RemoteMessage.Builder("synthetic")
                .addData("mode","weak").addData("alertId",id).addData("senderLabel","검사")
                .addData("message","합성 약함 알림").build());
            Notification received=active(manager,weak,8);
            check(weak.equals(received.getChannelId()),"FCM weak mode selects weak channel");
            check(received.fullScreenIntent==null,"Weak never opens popup");
            check((received.flags&Notification.FLAG_ONLY_ALERT_ONCE)==0,"A fresh message may alert");
            NativeMessageBadge.fromWeb(c,token,8);Thread.sleep(150);
            Notification refreshed=active(manager,weak,8);
            check(weak.equals(refreshed.getChannelId()),"Same-count read refresh must not move real alert to silent badge channel");
            check((refreshed.flags&Notification.FLAG_ONLY_ALERT_ONCE)==0,"Same-count refresh preserves active alert behavior");
            check(manager.getActiveNotifications().length==1,"One message, one notification");
            check(audio.getRingerMode()==AudioManager.RINGER_MODE_VIBRATE,"Weak respects the phone vibration mode");
            NativeMessageBadge.fromWeb(c,token,2);Thread.sleep(100);
            check(active(manager,NativeMessageBadge.CHANNEL,2).number==2,"Actual count change stays quiet");
            NativeMessageBadge.fromWeb(c,token,0);Thread.sleep(100);check(manager.getActiveNotifications().length==0,"Read clears notification");
            android.util.Log.i("OMSProbe","weak vibration pattern, phone mode, migration, silent-refresh race and single alert: PASS");
        }finally{
            audio.setRingerMode(ringer);SharedPreferences.Editor edit=push.edit().clear();
            for(Map.Entry<String,?> entry:oldPush.entrySet()){Object v=entry.getValue();String k=entry.getKey();if(v instanceof String)edit.putString(k,(String)v);else if(v instanceof Boolean)edit.putBoolean(k,(Boolean)v);else if(v instanceof Integer)edit.putInt(k,(Integer)v);else if(v instanceof Long)edit.putLong(k,(Long)v);}
            edit.commit();NativeMessageBadge.fromWeb(c,token,7);
        }
    }
}
