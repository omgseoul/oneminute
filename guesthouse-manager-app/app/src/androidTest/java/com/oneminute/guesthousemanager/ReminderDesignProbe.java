package com.oneminute.guesthousemanager;
import android.app.*;
import android.content.*;
import android.os.*;
import android.graphics.Bitmap;
import java.io.FileOutputStream;
final class ReminderDesignProbe {
 static void run(Instrumentation test){Bundle out=new Bundle();Context c=test.getTargetContext();Activity activity=null;
  try{
   c.getSharedPreferences("omg_push",0).edit().putString("role","staff").putString("member_id","reminder-design-test").commit();NativeMessagePopupQueue.clear(c);
   String[] bodies={"To do 알림\n2일 지연: 냉장고 정리","To do 알림\n오늘: 객실 비품 채우기","일정 알림\n3일 후: 소방 안전 점검"};String[] headings={"지연된 업무","To do 알림","일정 알림"};String[] timings={"(2일 지연)","(오늘)","(3일 후)"};Intent first=null;
   for(int i=0;i<3;i++){Intent intent=new Intent(c,MessageAlertActivity.class).putExtra("alertId","synthetic-design-"+i).putExtra("senderLabel","OMS 도우미").putExtra("message",bodies[i]).putExtra("messageType","general");NativeMessagePopupQueue.offer(c,intent);if(i==0)first=intent;}
   activity=test.startActivitySync(first.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));final Activity a=activity;
   for(int i=0;i<3;i++){test.waitForIdleSync();Thread.sleep(350);MessagePopupQueueProbe.check(MessagePopupQueueProbe.text(a.getWindow().getDecorView(),headings[i])!=null,"header "+i);MessagePopupQueueProbe.check(MessagePopupQueueProbe.text(a.getWindow().getDecorView(),timings[i])!=null,"timing "+i);Bitmap screenshot=test.getUiAutomation().takeScreenshot();try(FileOutputStream f=c.openFileOutput("native-reminder-"+i+".png",0)){screenshot.compress(Bitmap.CompressFormat.PNG,100,f);}test.runOnMainSync(()->MessagePopupQueueProbe.text(a.getWindow().getDecorView(),"확인").performClick());}
   out.putString("oms_reminder_design","ok");test.finish(-1,out);
  }catch(Throwable e){out.putString("oms_reminder_design","failed: "+e);test.finish(0,out);}finally{NativeMessagePopupQueue.clear(c);c.getSharedPreferences("omg_push",0).edit().clear().commit();if(activity!=null){final Activity a=activity;test.runOnMainSync(a::finish);}}
 }
}
