package com.oneminute.guesthousemanager;

import android.app.*;
import android.content.*;
import android.os.Bundle;
import android.service.notification.StatusBarNotification;
import java.util.concurrent.*;

/** Exercises real notification counts without a production connection or a real message. */
final class NativeMessageBadgeProbe {
    private static final String TOKEN="12345678-1234-4234-8234-123456789abc";
    private static void check(boolean ok,String message){if(!ok)throw new AssertionError(message);}
    private static Notification summary(Context c){
        for(StatusBarNotification n:c.getSystemService(NotificationManager.class).getActiveNotifications())
            if(n.getId()==NativeMessageBadge.ID)return n.getNotification();
        return null;
    }
    private static void expect(Context c,int count)throws Exception{
        long end=System.currentTimeMillis()+4000;
        while(System.currentTimeMillis()<end){Notification n=summary(c);if(count==0?n==null:n!=null&&n.number==count)return;Thread.sleep(50);}
        throw new AssertionError("Expected notification count "+count);
    }
    private static final class CountApi extends NativeStaffChatApi {
        final boolean owner;
        CountApi(Context c,boolean owner)throws Exception{super(c);this.owner=owner;}
        @Override org.json.JSONObject rpc(String name,org.json.JSONObject args)throws Exception{
            if("list_property_messages".equals(name))return new org.json.JSONObject().put("unread_count",9).put("can_manage",owner);
            if("work_report_inbox".equals(name)){check(owner,"Staff must not request reports");return new org.json.JSONObject().put("unread_count",4);}
            throw new AssertionError("Unexpected RPC");
        }
        @Override org.json.JSONObject guestRooms(org.json.JSONObject cursor)throws Exception{
            org.json.JSONArray rows=new org.json.JSONArray();boolean first=!cursor.has("before_id");
            for(int i=0;i<(first?50:1);i++)rows.put(new org.json.JSONObject().put("id","room-"+i).put("updated_at","2026-10-19T00:00:00Z").put("unread",first?1:3));
            return new org.json.JSONObject().put("rooms",rows);
        }
    }
    static void run(Instrumentation instrumentation){
        Bundle result=new Bundle();Context c=instrumentation.getTargetContext();
        NativeMessageBadge.Loader original=NativeMessageBadge.loader;
        try{
            c.getSharedPreferences("omg_receipts",0).edit().putString("token",TOKEN).putString("expires","2099-01-01T00:00:00Z").commit();
            NativeMessageBadge.clear(c);
            check(NativeMessageBadge.count(new CountApi(c,true))==66,"Messages + paginated guests + owner reports");
            check(NativeMessageBadge.count(new CountApi(c,false))==62,"Staff total excludes owner reports");
            NativeMessageBadge.loader=ctx->{throw new java.io.IOException("synthetic offline");};
            NativeMessageBadge.fromWeb(c,TOKEN,7);expect(c,7);
            Notification n=summary(c);
            check(n.getSmallIcon().getResId()==R.drawable.ic_oms_notification,"OMS status icon");
            check((n.flags&Notification.FLAG_GROUP_SUMMARY)==0,"Badge must not be a launcher-filtered group header");
            check(n.getGroup()==null,"Badge remains independent of alert groups");
            check(c.getSystemService(NotificationManager.class).getNotificationChannel(NativeMessageBadge.CHANNEL).canShowBadge(),"Badge channel enabled");
            NativeLauncherBadgeProbe.verify(instrumentation,c,TOKEN);
            NativeMessageBadge.fromWeb(c,TOKEN,7);expect(c,7);
            NativeMessageBadge.fromWeb(c,"wrong-session",99);expect(c,7);
            NativeMessageBadge.received(c,"same-alert");expect(c,8);
            NativeMessageBadge.received(c,"same-alert");Thread.sleep(150);expect(c,8);
            NativeMessageBadge.fromWeb(c,TOKEN,3);expect(c,3);
            NativeMessageBadge.fromWeb(c,TOKEN,0);expect(c,0);
            Thread.sleep(200);
            CountDownLatch entered=new CountDownLatch(1),release=new CountDownLatch(1);
            NativeMessageBadge.loader=ctx->{entered.countDown();release.await(5,TimeUnit.SECONDS);return 99;};
            NativeMessageBadge.refresh(c);check(entered.await(4,TimeUnit.SECONDS),"Snapshot started");
            NativeMessageBadge.fromWeb(c,TOKEN,2);release.countDown();Thread.sleep(300);expect(c,2);
            c.getSharedPreferences("omg_receipts",0).edit().putString("expires","2000-01-01T00:00:00Z").commit();
            NativeMessageBadge.refresh(c);expect(c,0);
            result.putString("oms_badge","ok");instrumentation.finish(-1,result);
        }catch(Throwable error){error.printStackTrace();result.putString("oms_badge","failed: "+error);instrumentation.finish(0,result);}
        finally{NativeMessageBadge.loader=original;c.getSharedPreferences("omg_receipts",0).edit().clear().commit();NativeMessageBadge.clear(c);}
    }
}
