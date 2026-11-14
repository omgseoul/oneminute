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

    static synchronized void changed(Context c){revision++;refresh(c);}

    static synchronized void fromWeb(Context c,String token,int count){
        if(token==null||!token.equals(NativeStaffChatApi.prefs(c).getString("token",""))||count<0)return;
        try{NativeStaffChatApi session=new NativeStaffChatApi(c);revision++;save(c,session.scope,count);}catch(Exception ignored){}
    }

    // Persist the same account-specific filters/relative period used by the home menu.
    static synchronized void setQuery(Context c,String token,String json){
        if(token==null||!token.equals(NativeStaffChatApi.prefs(c).getString("token",""))||json==null||json.length()>32768)return;
        try{
            NativeStaffChatApi session=new NativeStaffChatApi(c);JSONObject input=new JSONObject(json);
            JSONObject query=new JSONObject().put("filters",input.getJSONObject("filters")).put("period",input.getJSONObject("period"));
            SharedPreferences p=prefs(c);String value=query.toString();
            if(session.scope.equals(p.getString("query_scope",""))&&value.equals(p.getString("query","")))return;
            p.edit().putString("query_scope",session.scope).putString("query",value).apply();
            changed(c);
        }catch(Exception ignored){}
    }
    static synchronized void received(Context c,String id){
        // A push may be a reminder, a duplicate, or outside the guest filters.
        // Only a complete server snapshot may change the total.
        changed(c);
    }

    static synchronized void clear(Context c){
        revision++;prefs(c).edit().clear().apply();publish(c,0);
    }
    private static boolean isSummary(Notification n){
        String title=String.valueOf(n.extras.getCharSequence(Notification.EXTRA_TITLE));
        String body=String.valueOf(n.extras.getCharSequence(Notification.EXTRA_TEXT));
        return n.extras.getBoolean("oms_unread_summary",false)||title.startsWith("OMS · 미확인 소식")
            ||(("새 메세지 도착".equals(title)||"새 메시지 도착".equals(title))&&(body.startsWith("미확인 메세지 ")||body.startsWith("미확인 메시지 ")));
    }
    private static void save(Context c,String scope,int total){
        int count=Math.max(0,Math.min(1000000,total));
        prefs(c).edit().putString("scope",scope).putInt("count",count).apply();publish(c,count);
    }
    static int currentCount(Context c){return Math.max(1,prefs(c).getInt("count",0));}
    static synchronized void postAlert(Context c,Notification alert){
        NotificationManager manager=c.getSystemService(NotificationManager.class);if(manager==null)return;
        removeLegacy(manager);
        Notification n=Notification.Builder.recoverBuilder(c,alert).setLargeIcon((android.graphics.Bitmap)null).setNumber(Math.max(1,prefs(c).getInt("count",0))).build();
        manager.notify(ID,n);
        refresh(c); // Reconcile even if the first push refresh finished before the alert was posted.
    }
    private static void removeLegacy(NotificationManager manager){
        for(StatusBarNotification item:manager.getActiveNotifications())if(item.getId()!=ID&&
            (GROUP.equals(item.getNotification().getGroup())||item.getNotification().getChannelId().startsWith("property_messages_")))manager.cancel(item.getTag(),item.getId());
    }
    static void publish(Context c,int count){
        NotificationManager manager=c.getSystemService(NotificationManager.class);if(manager==null)return;
        removeLegacy(manager);
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
        android.os.Bundle extras=new android.os.Bundle();extras.putBoolean("oms_unread_summary",true);
        Notification notification=new NotificationCompat.Builder(c,CHANNEL)
                .setSmallIcon(R.drawable.ic_oms_notification).setColor(0xff2467bd)
                .addExtras(extras).setContentTitle("새 메세지 도착").setContentText("미확인 메세지 "+count+"개 · 메세지 메뉴에서 확인해주세요.")
                .setNumber(count).setBadgeIconType(NotificationCompat.BADGE_ICON_SMALL)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                // Launchers filter group headers; the count must be a standalone notification.
                .setOnlyAlertOnce(true).setAutoCancel(false).setContentIntent(content).build();
        try{
            // Some launchers keep the old count on an in-place notification update.
            // Remove that key first when the count changes, or when migrating 0.16.7's
            // group header, so their notification model receives a remove/add pair.
            for(StatusBarNotification item:manager.getActiveNotifications())if(item.getId()==ID){
                Notification previous=item.getNotification();
                if((previous.flags&Notification.FLAG_FOREGROUND_SERVICE)!=0)return;
                // recoverBuilder adopts and mutates this Notification: capture before rebuilding.
                boolean repost=previous.number!=count||(previous.flags&Notification.FLAG_GROUP_SUMMARY)!=0;
                // A receipt refresh often confirms the same count immediately after FCM.
                // Reposting that alert on the silent badge channel can cancel its vibration.
                if(!repost&&previous.getLargeIcon()==null&&previous.getGroup()==null&&!CHANNEL.equals(previous.getChannelId())
                        &&!isSummary(previous))return;
                // Keep the real sender/body and destination; count changes stay quiet.
                if(!isSummary(previous))notification=Notification.Builder.recoverBuilder(c,previous).setLargeIcon((android.graphics.Bitmap)null).setChannelId(CHANNEL)
                    .setGroup(null).setGroupSummary(false).setNumber(count).setOnlyAlertOnce(true)
                    .setFullScreenIntent(null,false).build();
                if(repost)manager.cancel(ID);
            }
            manager.notify(ID,notification);
        }catch(SecurityException ignored){/* Respect notification permission. */}
    }

    private static int loadCount(Context c)throws Exception{
        NativeStaffChatApi api=new NativeStaffChatApi(c);SharedPreferences p=prefs(c);
        JSONObject query=api.scope.equals(p.getString("query_scope",""))?new JSONObject(p.getString("query","{}")):new JSONObject();
        return count(api,query);
    }
    static int count(NativeStaffChatApi api,JSONObject query)throws Exception{
        JSONObject messages=api.rpc("list_property_messages",new JSONObject());
        JSONObject guests=api.rpc("guest_message_summary",new JSONObject().put("p_data",query));
        // messenger_unread excludes guest copies already represented by the guest menu.
        long total=Math.max(0,guests.getLong("messenger_unread"))+Math.max(0,guests.getLong("unread"));
        if(messages.optBoolean("can_manage"))total+=Math.max(0,api.rpc("work_report_inbox",new JSONObject()).getLong("unread_count"));
        if(!api.valid())throw new IllegalStateException("Session changed");
        return (int)Math.min(1000000,total);
    }
}
