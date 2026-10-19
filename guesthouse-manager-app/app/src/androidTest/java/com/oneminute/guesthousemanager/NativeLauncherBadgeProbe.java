package com.oneminute.guesthousemanager;

import android.app.*;
import android.content.*;
import android.graphics.Bitmap;
import android.os.ParcelFileDescriptor;
import android.view.accessibility.AccessibilityNodeInfo;
import java.io.*;
import java.util.*;

/** Verify the actual launcher icon, not just NotificationManager's stored number. */
final class NativeLauncherBadgeProbe {
    private static Instrumentation instrumentation;
    private static Context context;
    private static String launcher;
    static void verify(Instrumentation i,Context c,String token)throws Exception{
        instrumentation=i;context=c;
        launcher=c.getPackageManager().resolveActivity(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME),0).activityInfo.packageName;
        NativeMessageBadge.fromWeb(c,token,2);
        NotificationManager manager=c.getSystemService(NotificationManager.class);
        Notification current=null;
        for(android.service.notification.StatusBarNotification item:manager.getActiveNotifications())
            if(item.getId()==NativeMessageBadge.ID)current=item.getNotification();
        if(current==null)throw new AssertionError("Missing badge fixture");
        // Reproduce 0.16.7: group headers store a number but Launcher3 filters them out.
        manager.notify(NativeMessageBadge.ID,Notification.Builder.recoverBuilder(c,current)
                .setGroup(NativeMessageBadge.GROUP).setGroupSummary(true).build());
        shell("input keyevent KEYCODE_HOME");Thread.sleep(800);
        android.util.DisplayMetrics metrics=c.getResources().getDisplayMetrics();
        int x=metrics.widthPixels/2,h=metrics.heightPixels;
        shell("input swipe "+x+" "+(h*85/100)+" "+x+" "+(h*20/100)+" 450");
        awaitCount(0);capture("launcher-badge-before.png");
        NativeMessageBadge.fromWeb(c,token,2);awaitCount(2);capture("launcher-badge-after.png");
        NativeMessageBadge.fromWeb(c,token,1);awaitCount(1);
        NativeMessageBadge.fromWeb(c,token,0);awaitCount(0);capture("launcher-badge-cleared.png");
        System.out.println("PASS: launcher excludes old group header, exposes exact counts 2 -> 1 -> 0 for standalone badge");
    }
    private static void shell(String command)throws Exception{
        ParcelFileDescriptor fd=instrumentation.getUiAutomation().executeShellCommand(command);
        try(InputStream in=new ParcelFileDescriptor.AutoCloseInputStream(fd)){
            byte[] bytes=new byte[4096];while(in.read(bytes)!=-1){}
        }
    }
    private static List<String> labels(){
        List<String> result=new ArrayList<>();collect(instrumentation.getUiAutomation().getRootInActiveWindow(),result);return result;
    }
    private static void collect(AccessibilityNodeInfo node,List<String> result){
        if(node==null)return;
        String description=String.valueOf(node.getContentDescription());
        if(node.isVisibleToUser()&&launcher.equals(String.valueOf(node.getPackageName()))&&description.startsWith("OMS"))result.add(description);
        for(int i=0;i<node.getChildCount();i++)collect(node.getChild(i),result);
    }
    private static void awaitCount(int count)throws Exception{
        long end=System.currentTimeMillis()+15000;List<String> last=Collections.emptyList();
        while(System.currentTimeMillis()<end){
            last=labels();boolean matches=!last.isEmpty()&&(count==0
                    ?last.stream().noneMatch(s->s.matches(".*\\b[1-9][0-9]*\\b.*"))
                    :last.stream().anyMatch(s->s.matches(".*\\b"+count+"\\b.*")));
            if(matches){System.out.println("LAUNCHER_BADGE count="+count+" labels="+last);return;}
            Thread.sleep(200);
        }
        capture("launcher-badge-failed.png");throw new AssertionError("Launcher count "+count+" not visible; labels="+last+", launcher="+launcher);
    }
    private static void capture(String name)throws Exception{
        Thread.sleep(250);Bitmap bitmap=instrumentation.getUiAutomation().takeScreenshot();
        try(FileOutputStream output=new FileOutputStream(new File(context.getFilesDir(),name))){bitmap.compress(Bitmap.CompressFormat.PNG,100,output);}
        bitmap.recycle();
    }
}
