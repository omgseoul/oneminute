package com.oneminute.guesthousemanager;

import android.app.*;
import android.content.*;
import android.net.Uri;
import android.service.notification.StatusBarNotification;
import androidx.core.app.NotificationCompat;
import org.json.*;
import java.util.concurrent.*;

/** Two standalone notifications match the guest/staff home counters. Launchers sum their numbers.
 * Alert channels still preserve the configured sound, vibration and popup strength. */
final class NativeMessageBadge {
    static final String GROUP="oms_unread_messages";
    static final String CHANNEL="oms_unread_count_v1";
    static final int ID=0x4f4d5301;
    static final int GUEST_ID=0x4f4d5302;
    static final class Counts {
        final int guest,staff;
        Counts(long guest,long staff){this.guest=clamp(guest);this.staff=clamp(staff);}
        int total(){return guest+staff;}
    }
    private static int clamp(long value){return (int)Math.max(0,Math.min(1000000,value));}
    interface Loader { Counts load(Context context) throws Exception; }
    static Loader loader=NativeMessageBadge::loadCounts;
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
                Counts count=loader.load(c);
                synchronized(NativeMessageBadge.class){
                    if(session.valid()&&request==revision)save(c,session.scope,count);
                }
            }catch(Exception ignored){/* Preserve the last complete count on network failure. */}
            finally{synchronized(NativeMessageBadge.class){busy=false;if(again){again=false;refresh(c);}}}
        });
    }

    static synchronized void changed(Context c){revision++;refresh(c);}

    static void fromWeb(Context c,String token,int staff){fromWeb(c,token,0,staff);}
    static synchronized void fromWeb(Context c,String token,int guest,int staff){
        if(token==null||!token.equals(NativeStaffChatApi.prefs(c).getString("token",""))||guest<0||staff<0)return;
        try{NativeStaffChatApi session=new NativeStaffChatApi(c);revision++;save(c,session.scope,new Counts(guest,staff));}catch(Exception ignored){}
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
        revision++;prefs(c).edit().clear().apply();publish(c,new Counts(0,0));
    }
    private static boolean isSummary(Notification n){
        String title=String.valueOf(n.extras.getCharSequence(Notification.EXTRA_TITLE));
        String body=String.valueOf(n.extras.getCharSequence(Notification.EXTRA_TEXT));
        return n.extras.getBoolean("oms_unread_summary",false)||title.startsWith("OMS · 미확인 소식")
            ||(("새 메세지 도착".equals(title)||"새 메시지 도착".equals(title))&&(body.startsWith("미확인 메세지 ")||body.startsWith("미확인 메시지 ")));
    }
    private static void save(Context c,String scope,Counts counts){
        prefs(c).edit().putString("scope",scope).putInt("guest_count",counts.guest).putInt("staff_count",counts.staff)
            .remove("count").apply();publish(c,counts);
    }
    static int id(boolean guest){return guest?GUEST_ID:ID;}
    static int currentCount(Context c,boolean guest){return Math.max(1,prefs(c).getInt(guest?"guest_count":"staff_count",0));}
    static boolean guest(String type,String context,String route){
        if("guest_chat".equals(type))return true;
        if(route!=null&&(route.startsWith("guest-messages.html")||route.startsWith("online.html#thread/")))return true;
        try{String kind=new JSONObject(context).optString("kind");return "online".equals(kind)||"onsite".equals(kind);}catch(Exception ignored){return false;}
    }
    static boolean guest(java.util.Map<String,String> data){return guest(data.get("messageType"),data.get("guestContext"),data.get("route"));}
    static boolean bot(String route){return "messages.html#bot".equals(route)||"messages.html?tab=alerts".equals(route);}
    static String url(boolean guest,boolean bot){return "https://omgworks24.com/"+(guest?"guest-messages.html#inbox":bot?"messages.html#bot":"messages.html?tab=staff");}
    // Popup deep links are restricted to the known app destinations, never arbitrary FCM URLs.
    static String messageUrl(String type,String context,String route,String alertId){
        if(bot(route))return url(false,true);
        if(guest(type,context,route)){
            if(route!=null&&route.matches("(?:guest-messages|online)\\.html#thread/[0-9]+(?:\\?property=[0-9a-fA-F-]{36})?"))
                return "https://omgworks24.com/"+route.replaceFirst("^online\\.html","guest-messages.html");
            return url(true,false);
        }
        return "https://omgworks24.com/messages.html"+(alertId==null||alertId.isEmpty()?"":"?message_id="+Uri.encode(alertId));
    }
    private static String title(boolean guest,int count){return (guest?"게스트 메시지 ":"직원 메시지 ")+count+"건 알림";}
    private static PendingIntent content(Context c,boolean guest,boolean bot){
        Intent open=new Intent(c,AttendanceActivity.class).setData(Uri.parse(url(guest,bot)))
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return PendingIntent.getActivity(c,id(guest),open,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
    }
    static Notification decorate(Context c,Notification alert,boolean guest,boolean bot){
        android.os.Bundle extras=new android.os.Bundle(alert.extras);
        extras.putBoolean("oms_unread_summary",false);extras.putString("oms_message_bucket",guest?"guest":"staff");extras.putBoolean("oms_bot_notice",bot);
        return Notification.Builder.recoverBuilder(c,alert).setExtras(extras).setLargeIcon((android.graphics.Bitmap)null)
            .setGroup(null).setGroupSummary(false).setNumber(currentCount(c,guest)).setContentTitle(title(guest,currentCount(c,guest)))
            .setContentIntent(content(c,guest,bot)).build();
    }
    static Notification postAlert(Context c,Notification alert){return postAlert(c,alert,false,false);}
    static synchronized Notification postAlert(Context c,Notification alert,boolean guest,boolean bot){
        Notification n=decorate(c,alert,guest,bot);
        NotificationManager manager=c.getSystemService(NotificationManager.class);
        if(manager!=null){removeLegacy(manager);manager.notify(id(guest),n);}
        refresh(c); // Reconcile even if the receipt refresh finished before the alert was posted.
        return n;
    }
    private static void removeLegacy(NotificationManager manager){
        for(StatusBarNotification item:manager.getActiveNotifications())if(item.getId()!=ID&&item.getId()!=GUEST_ID&&
            (GROUP.equals(item.getNotification().getGroup())||String.valueOf(item.getNotification().getChannelId()).startsWith("property_messages_")))manager.cancel(item.getTag(),item.getId());
    }
    static void publish(Context c,Counts counts){
        NotificationManager manager=c.getSystemService(NotificationManager.class);if(manager==null)return;
        removeLegacy(manager);
        NotificationChannel channel=new NotificationChannel(CHANNEL,"미확인 메세지 숫자",NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("게스트·직원 메시지 수를 각각 표시하고 앱 아이콘에는 합계를 표시합니다.");
        channel.setShowBadge(true);channel.setSound(null,null);channel.enableVibration(false);manager.createNotificationChannel(channel);
        publish(c,manager,true,counts.guest);publish(c,manager,false,counts.staff);
    }
    private static void publish(Context c,NotificationManager manager,boolean guest,int count){
        int id=id(guest);
        if(count<=0){manager.cancel(id);return;}
        android.os.Bundle extras=new android.os.Bundle();extras.putBoolean("oms_unread_summary",true);extras.putString("oms_message_bucket",guest?"guest":"staff");
        Notification notification=new NotificationCompat.Builder(c,CHANNEL)
            .setSmallIcon(R.drawable.ic_oms_notification).setColor(0xff2467bd).addExtras(extras)
            .setContentTitle(title(guest,count)).setContentText((guest?"게스트":"직원")+" 메시지 메뉴에서 확인해주세요.")
            .setNumber(count).setBadgeIconType(NotificationCompat.BADGE_ICON_SMALL).setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setOnlyAlertOnce(true).setAutoCancel(false).setContentIntent(content(c,guest,false)).build();
        try{
            for(StatusBarNotification item:manager.getActiveNotifications())if(item.getId()==id){
                Notification previous=item.getNotification();
                boolean categorized=(guest?"guest":"staff").equals(previous.extras.getString("oms_message_bucket"));
                boolean repost=previous.number!=count||(previous.flags&Notification.FLAG_GROUP_SUMMARY)!=0||!categorized;
                // Leave foreground alarm ownership with its service; refresh again when it stops.
                if((previous.flags&Notification.FLAG_FOREGROUND_SERVICE)!=0)return;
                // An unchanged bucket is not a new event: never repost it or move it above a real arrival.
                if(!repost&&previous.getLargeIcon()==null&&previous.getGroup()==null)return;
                if(categorized&&!isSummary(previous))notification=Notification.Builder.recoverBuilder(c,previous)
                    .setLargeIcon((android.graphics.Bitmap)null).setChannelId(CHANNEL).setGroup(null).setGroupSummary(false)
                    .setNumber(count).setContentTitle(title(guest,count)).setWhen(previous.when).setOnlyAlertOnce(true).setFullScreenIntent(null,false).build();
                // Updating a count is silent and keeps its original arrival timestamp.
                notification=Notification.Builder.recoverBuilder(c,notification).setWhen(previous.when).setOnlyAlertOnce(true).build();
            }
            manager.notify(id,notification);
        }catch(SecurityException ignored){/* Respect notification permission. */}
    }

    private static Counts loadCounts(Context c)throws Exception{
        NativeStaffChatApi api=new NativeStaffChatApi(c);SharedPreferences p=prefs(c);
        JSONObject query=api.scope.equals(p.getString("query_scope",""))?new JSONObject(p.getString("query","{}")):new JSONObject();
        return counts(api,query);
    }
    static Counts counts(NativeStaffChatApi api,JSONObject query)throws Exception{
        JSONObject summary=api.rpc("home_message_summary",new JSONObject().put("p_data",query));
        if(!api.valid())throw new IllegalStateException("Session changed");
        return new Counts(summary.getLong("guest_unread"),summary.getLong("staff_unread"));
    }
}
