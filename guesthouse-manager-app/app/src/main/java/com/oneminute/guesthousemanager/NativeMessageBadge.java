package com.oneminute.guesthousemanager;

import android.app.*;
import android.content.*;
import android.net.Uri;
import android.service.notification.StatusBarNotification;
import androidx.core.app.NotificationCompat;
import org.json.*;
import java.util.concurrent.*;

/** One standalone badge-bearing notification represents the same total as the home menu.
 * Alert channels remain separate so their sounds and user settings are preserved.
 * Only the standalone notification contributes a count; three alert modes cannot count one item three times.
 */
final class NativeMessageBadge {
    static final String GROUP="oms_unread_messages";
    static final String CHANNEL="oms_unread_count_v1";
    static final int ID=0x4f4d5301;
    interface Loader { int load(Context context) throws Exception; }
    static Loader loader=NativeMessageBadge::loadCount;
    private static final ExecutorService worker=Executors.newSingleThreadExecutor();
    private static long revision;
    private static boolean busy,again;
    private static SharedPreferences prefs(Context c){return c.getSharedPreferences("omg_message_badge",Context.MODE_PRIVATE);}

    static synchronized void refresh(Context context){
        Context c=context.getApplicationContext();
        final NativeStaffChatApi session;
        try{session=new NativeStaffChatApi(c);}catch(Exception error){clear(c);return;}
        if(busy){again=true;return;}
        busy=true;final long request=revision;
        worker.execute(()->{
            try{
                int count=loader.load(c);
                synchronized(NativeMessageBadge.class){
                    if(session.valid()&&request==revision)save(c,session.scope,count);
                }
            }catch(Exception ignored){/* Preserve the last complete count on network failure. */}
            finally{synchronized(NativeMessageBadge.class){busy=false;if(again){again=false;refresh(c);}}}
        });
    }

    static synchronized void fromWeb(Context c,String token,int count){
        if(token==null||!token.equals(NativeStaffChatApi.prefs(c).getString("token",""))||count<0)return;
        try{NativeStaffChatApi session=new NativeStaffChatApi(c);revision++;save(c,session.scope,count);}catch(Exception ignored){}
    }

    static synchronized void received(Context c,String id){
        if(id==null||id.isEmpty()){refresh(c);return;}
        try{
            NativeStaffChatApi session=new NativeStaffChatApi(c);SharedPreferences p=prefs(c);
            if(!session.scope.equals(p.getString("scope","")))p.edit().clear().commit();
            String key="push_"+NativeStaffChatApi.hash(id);long now=System.currentTimeMillis();
            if(!p.contains(key)){
                SharedPreferences.Editor edit=p.edit();
                for(String old:p.getAll().keySet())if(old.startsWith("push_")&&now-p.getLong(old,0)>86400000L)edit.remove(old);
                edit.putLong(key,now).commit();revision++;
                save(c,session.scope,Math.min(1000000,p.getInt("count",0)+1));
            }
            refresh(c);
        }catch(Exception ignored){clear(c);}
    }

    static synchronized void clear(Context c){
        revision++;prefs(c).edit().clear().apply();publish(c,0);
    }
    private static void save(Context c,String scope,int total){
        int count=Math.max(0,Math.min(1000000,total));
        prefs(c).edit().putString("scope",scope).putInt("count",count).apply();publish(c,count);
    }
    static void publish(Context c,int count){
        NotificationManager manager=c.getSystemService(NotificationManager.class);if(manager==null)return;
        if(count<=0){
            manager.cancel(ID);
            for(StatusBarNotification item:manager.getActiveNotifications())
                if(GROUP.equals(item.getNotification().getGroup()))manager.cancel(item.getTag(),item.getId());
            return;
        }
        NotificationChannel channel=new NotificationChannel(CHANNEL,"미확인 메세지 숫자",NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("메세지 메뉴와 같은 미확인 수를 앱 아이콘에 표시합니다.");
        channel.setShowBadge(true);channel.setSound(null,null);channel.enableVibration(false);manager.createNotificationChannel(channel);
        Intent open=new Intent(c,AttendanceActivity.class).setData(Uri.parse("https://omgworks24.com/messages.html"))
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent content=PendingIntent.getActivity(c,ID,open,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
        Notification notification=new NotificationCompat.Builder(c,CHANNEL)
                .setSmallIcon(R.drawable.ic_oms_notification).setColor(0xff2467bd)
                .setContentTitle("OMS · 미확인 소식 "+count+"개").setContentText("메세지 메뉴에서 확인해주세요.")
                .setNumber(count).setBadgeIconType(NotificationCompat.BADGE_ICON_SMALL)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                // Launchers filter group headers; the count must be a standalone notification.
                .setOnlyAlertOnce(true).setAutoCancel(false).setContentIntent(content).build();
        try{manager.notify(ID,notification);}catch(SecurityException ignored){/* Respect notification permission. */}
    }

    private static int loadCount(Context c)throws Exception{
        return count(new NativeStaffChatApi(c));
    }
    static int count(NativeStaffChatApi api)throws Exception{
        JSONObject messages=api.rpc("list_property_messages",new JSONObject());
        long total=Math.max(0,messages.optInt("unread_count"));
        JSONObject cursor=new JSONObject();int pages=0;
        while(true){
            JSONArray rooms=api.guestRooms(cursor).getJSONArray("rooms");
            for(int i=0;i<rooms.length();i++)total+=Math.max(0,rooms.getJSONObject(i).optInt("unread"));
            if(rooms.length()<50)break;
            if(++pages>=100)throw new IllegalStateException("Incomplete guest unread snapshot");
            JSONObject last=rooms.getJSONObject(rooms.length()-1);
            cursor=new JSONObject().put("before_updated",last.getString("updated_at")).put("before_id",last.getString("id"));
        }
        if(messages.optBoolean("can_manage"))total+=Math.max(0,api.rpc("work_report_inbox",new JSONObject()).optInt("unread_count"));
        if(!api.valid())throw new IllegalStateException("Session changed");
        return (int)Math.min(1000000,total);
    }
}
