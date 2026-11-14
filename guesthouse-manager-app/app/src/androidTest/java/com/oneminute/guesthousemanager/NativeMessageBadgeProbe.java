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
        final boolean owner;org.json.JSONObject receivedQuery;
        CountApi(Context c,boolean owner)throws Exception{super(c);this.owner=owner;}
        @Override org.json.JSONObject rpc(String name,org.json.JSONObject args)throws Exception{
            if("list_property_messages".equals(name))return new org.json.JSONObject().put("unread_count",846).put("can_manage",owner);
            if("guest_message_summary".equals(name)){receivedQuery=args.getJSONObject("p_data");return new org.json.JSONObject().put("unread",31).put("messenger_unread",12).put("total_unread",830);}
            if("work_report_inbox".equals(name)){check(owner,"Staff must not request reports");return new org.json.JSONObject().put("unread_count",4);}
            throw new AssertionError("Unexpected RPC");
        }
        @Override org.json.JSONObject guestRooms(org.json.JSONObject cursor)throws Exception{
            throw new AssertionError("Unfiltered guest rooms must not be counted");
        }
    }
    private static void verifyLogo(Context c, Notification notification) {
        check(notification.getLargeIcon()==null,"No duplicate logo on right of notification");
        android.graphics.drawable.Drawable icon=c.getDrawable(R.drawable.ic_oms_notification);
        android.graphics.Bitmap small=android.graphics.Bitmap.createBitmap(240,240,android.graphics.Bitmap.Config.ARGB_8888);
        icon.setBounds(0,0,240,240);icon.draw(new android.graphics.Canvas(small));
        check(android.graphics.Color.alpha(small.getPixel(120,14))>240,"Status ring reaches expanded outer edge");
        check(android.graphics.Color.alpha(small.getPixel(120,65))>240,"Status ring has thicker stroke");
        check(android.graphics.Color.alpha(small.getPixel(120,120))==0,"Status ring hole remains clear");
    }
    static void run(Instrumentation instrumentation){
        Bundle result=new Bundle();Context c=instrumentation.getTargetContext();
        NativeMessageBadge.Loader original=NativeMessageBadge.loader;
        try{
            c.getSharedPreferences("omg_receipts",0).edit().putString("token",TOKEN).putString("expires","2099-01-01T00:00:00Z").commit();
            NativeMessageBadge.clear(c);
            org.json.JSONObject query=new org.json.JSONObject("{\"filters\":{\"version\":1,\"qrVersion\":1,\"statuses\":[\"qr\"],\"properties\":[\"home\"]},\"period\":{\"days\":3}}");
            CountApi owner=new CountApi(c,true);
            check(NativeMessageBadge.count(owner,query)==47,"31 guests + (12 staff + 4 reports), not 846 historical items");
            check(owner.receivedQuery.toString().equals(query.toString()),"Home filters and rolling period reach summary RPC unchanged");
            check(NativeMessageBadge.count(new CountApi(c,false),new org.json.JSONObject())==43,"Staff menu sum excludes owner-only reports");
            NativeMessageBadge.loader=ctx->{throw new java.io.IOException("synthetic offline");};
            NativeMessageBadge.setQuery(c,TOKEN,query.toString());
            check(c.getSharedPreferences("omg_message_badge",0).getString("query","").equals(query.toString()),"Background query persisted");
            NativeMessageBadge.setQuery(c,"wrong-session","{\"filters\":{},\"period\":{}}");
            check(c.getSharedPreferences("omg_message_badge",0).getString("query","").equals(query.toString()),"Other sessions cannot replace filters");
            Thread.sleep(200);
            NativeMessageBadge.fromWeb(c,TOKEN,846);expect(c,846);
            NativeMessageBadge.fromWeb(c,TOKEN,47);expect(c,47);
            check(summary(c).extras.getCharSequence(Notification.EXTRA_TEXT).toString().contains("47개"),"Summary text replaces stale 846 when count falls");
            Notification legacy=new Notification.Builder(c,NativeMessageBadge.CHANNEL).setSmallIcon(R.drawable.ic_oms_notification).setContentTitle("새 메세지 도착").setContentText("미확인 메세지 846개 · 메세지 메뉴에서 확인해주세요.").setNumber(846).build();
            c.getSystemService(NotificationManager.class).notify(NativeMessageBadge.ID,legacy);expect(c,846);
            NativeMessageBadge.fromWeb(c,TOKEN,7);expect(c,7);
            check(summary(c).extras.getCharSequence(Notification.EXTRA_TEXT).toString().contains("7개"),"Legacy summary text is migrated");
            Notification n=summary(c);
            verifyLogo(c,n);
            check(n.getSmallIcon().getResId()==R.drawable.ic_oms_notification,"OMS status icon");
            check((n.flags&Notification.FLAG_GROUP_SUMMARY)==0,"Badge must not be a launcher-filtered group header");
            check(n.getGroup()==null,"Badge remains independent of alert groups");
            check(c.getSystemService(NotificationManager.class).getNotificationChannel(NativeMessageBadge.CHANNEL).canShowBadge(),"Badge channel enabled");
            NativeNotificationModesProbe.verify(c,TOKEN);
            Notification actual=new Notification.Builder(c,NativeMessageBadge.CHANNEL).setLargeIcon(android.graphics.Bitmap.createBitmap(24,24,android.graphics.Bitmap.Config.ARGB_8888)).setSmallIcon(R.drawable.ic_oms_notification).setContentTitle("새 메세지 도착").setContentText("보낸 사람 · 안녕하세요").build();
            NativeMessageBadge.postAlert(c,actual);NativeMessageBadge.postAlert(c,actual);
            check(c.getSystemService(NotificationManager.class).getActiveNotifications().length==1,"One real message notification, no extra unread bulletin");
            NativeMessageBadge.fromWeb(c,TOKEN,2);expect(c,2);
            verifyLogo(c,summary(c));
            check("보낸 사람 · 안녕하세요".contentEquals(summary(c).extras.getCharSequence(Notification.EXTRA_TEXT)),"Count updates preserve actual message content");
            NativeLauncherBadgeProbe.verify(instrumentation,c,TOKEN);
            NativeMessageBadge.fromWeb(c,TOKEN,7);expect(c,7);
            NativeMessageBadge.fromWeb(c,"wrong-session",99);expect(c,7);
            NativeMessageBadge.received(c,"same-alert");expect(c,7);
            NativeMessageBadge.received(c,"same-alert");Thread.sleep(150);expect(c,7);
            NativeMessageBadge.fromWeb(c,TOKEN,3);expect(c,3);
            NativeMessageBadge.fromWeb(c,TOKEN,0);expect(c,0);
            Thread.sleep(200);
            CountDownLatch entered=new CountDownLatch(1),release=new CountDownLatch(1);
            NativeMessageBadge.loader=ctx->{entered.countDown();release.await(5,TimeUnit.SECONDS);return 99;};
            NativeMessageBadge.refresh(c);check(entered.await(4,TimeUnit.SECONDS),"Snapshot started");
            NativeMessageBadge.fromWeb(c,TOKEN,2);release.countDown();Thread.sleep(300);expect(c,2);
            Thread.sleep(200);CountDownLatch staleEntered=new CountDownLatch(1),staleRelease=new CountDownLatch(1);java.util.concurrent.atomic.AtomicInteger loads=new java.util.concurrent.atomic.AtomicInteger();
            NativeMessageBadge.loader=ctx->{if(loads.incrementAndGet()==1){staleEntered.countDown();staleRelease.await(5,TimeUnit.SECONDS);return 99;}return 0;};
            NativeMessageBadge.refresh(c);check(staleEntered.await(4,TimeUnit.SECONDS),"Pre-read snapshot started");
            NativeMessageBadge.changed(c);staleRelease.countDown();expect(c,0);
            check(loads.get()>=2,"Reading invalidates stale snapshot and reloads count");
            c.getSharedPreferences("omg_receipts",0).edit().putString("expires","2000-01-01T00:00:00Z").commit();
            NativeMessageBadge.refresh(c);expect(c,0);
            result.putString("oms_badge","ok");instrumentation.finish(-1,result);
        }catch(Throwable error){error.printStackTrace();result.putString("oms_badge","failed: "+error);instrumentation.finish(0,result);}
        finally{NativeMessageBadge.loader=original;c.getSharedPreferences("omg_receipts",0).edit().clear().commit();NativeMessageBadge.clear(c);}
    }
}
