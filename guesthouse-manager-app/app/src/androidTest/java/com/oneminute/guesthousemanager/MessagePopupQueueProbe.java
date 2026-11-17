package com.oneminute.guesthousemanager;
import android.app.*;
import android.content.*;
import android.os.Bundle;
import android.view.*;
import android.widget.*;
final class MessagePopupQueueProbe {
 static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
 static TextView text(View v,String value){if(v instanceof TextView&&value.contentEquals(((TextView)v).getText()))return(TextView)v;if(v instanceof ViewGroup)for(int i=0;i<((ViewGroup)v).getChildCount();i++){TextView found=text(((ViewGroup)v).getChildAt(i),value);if(found!=null)return found;}return null;}
 static Intent item(Context c,int n){return new Intent(c,MessageAlertActivity.class).putExtra("alertId","synthetic-queue-"+n).putExtra("senderLabel","To do 알림").putExtra("message","순서 검사 "+n).putExtra("messageType","general");}
 static void run(Instrumentation test){Bundle out=new Bundle();Context c=test.getTargetContext();MessageAlertActivity activity=null;
  try{
   c.getSharedPreferences("omg_push",0).edit().putString("role","staff").putString("member_id","queue-test").commit();NativeMessagePopupQueue.clear(c);
   // Simulate Android collapsing four fullscreen launches to just one.
   for(int n=1;n<=4;n++)NativeMessagePopupQueue.offer(c,item(c,n));
   activity=(MessageAlertActivity)test.startActivitySync(item(c,4).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
   final MessageAlertActivity screen=activity;test.waitForIdleSync();
   check(text(screen.getWindow().getDecorView(),"순서 검사 1")!=null,"First alert is not overwritten by last launch");
   test.runOnMainSync(()->screen.onNewIntent(item(c,3)));test.waitForIdleSync();check(NativeMessagePopupQueue.size(c)==4,"Repeated launch deduplicated");
   for(int n=1;n<=4;n++){
    final int index=n;test.runOnMainSync(()->{check(text(screen.getWindow().getDecorView(),"순서 검사 "+index)!=null,"FIFO display "+index);if(index<4)check(text(screen.getWindow().getDecorView(),(5-index)+"건 대기")!=null,"Count matches queue");else check(text(screen.getWindow().getDecorView(),"1건 대기")==null,"Single pending count is omitted");text(screen.getWindow().getDecorView(),"확인").performClick();});test.waitForIdleSync();Thread.sleep(250);
   }
   check(NativeMessagePopupQueue.size(c)==0,"All four consumed");check(!NativeMessagePopupQueue.offer(c,item(c,1)),"Delayed retry cannot reopen confirmed alert");
   // Advance the timeout clock without waiting five minutes on the emulator.
   activity=(MessageAlertActivity)test.startActivitySync(item(c,6).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
   final MessageAlertActivity timed=activity;final Bundle saved=new Bundle();
   test.runOnMainSync(()->{
    timed.popupTimeout.save(saved);long deadline=saved.getLong("oms_popup_deadline");
    check(deadline-android.os.SystemClock.elapsedRealtime()<=300000L,"Five minute budget");
    timed.onNewIntent(item(c,7));final Bundle after=new Bundle();timed.popupTimeout.save(after);
    check(after.getLong("oms_popup_deadline")==deadline,"New arrival does not extend timer");
    timed.popupTimeout.check(deadline-1);check(!timed.isFinishing(),"Visible before deadline");
    timed.popupTimeout.check(deadline);check(timed.isFinishing(),"Closes at five minutes");
    check((timed.getWindow().getAttributes().flags&WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)==0,"Screen hold released");
   });test.waitForIdleSync();check(NativeMessagePopupQueue.size(c)==0,"Timeout dismisses whole batch");check(!NativeMessagePopupQueue.offer(c,item(c,6)),"Timed out alert cannot reopen");check(!NativeMessagePopupQueue.offer(c,item(c,7)),"Queued timeout cannot reopen");
   test.runOnMainSync(()->{
    final int[] expired={0};PopupScreenTimeout restored=new PopupScreenTimeout(()->expired[0]++);restored.start(saved);
    long deadline=saved.getLong("oms_popup_deadline");restored.check(deadline-1);check(expired[0]==0,"Recreation preserves remaining budget");restored.check(deadline);restored.check(deadline+1);check(expired[0]==1,"Expires exactly once");
    PopupScreenTimeout stopped=new PopupScreenTimeout(()->expired[0]++);stopped.start(null);stopped.stop();stopped.check(Long.MAX_VALUE);check(expired[0]==1,"Destroyed timer cannot expire later");
   });
   NativeMessagePopupQueue.offer(c,item(c,5));c.getSharedPreferences("omg_push",0).edit().putString("member_id","other-user").commit();check(NativeMessagePopupQueue.peek(c)==null,"Account switch clears previous user's queue");
   out.putString("oms_popup_queue","ok");test.finish(-1,out);
  }catch(Throwable e){out.putString("oms_popup_queue","failed: "+e);test.finish(0,out);}finally{NativeMessagePopupQueue.clear(c);c.getSharedPreferences("omg_push",0).edit().clear().commit();if(activity!=null){final Activity a=activity;test.runOnMainSync(a::finish);}}
 }
}
