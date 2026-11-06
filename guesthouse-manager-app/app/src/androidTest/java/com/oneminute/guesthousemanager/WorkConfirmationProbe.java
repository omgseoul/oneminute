package com.oneminute.guesthousemanager;
import android.app.*;
import android.content.*;
import android.os.Bundle;
import android.view.*;
import android.widget.*;
import org.json.JSONObject;
import java.time.Instant;
import java.util.concurrent.atomic.AtomicInteger;
final class WorkConfirmationProbe {
 static void check(boolean value,String why){if(!value)throw new AssertionError(why);}
 static TextView text(View v,String value){return MessagePopupQueueProbe.text(v,value);}
 static int buttons(View v){int n=v instanceof Button?1:0;if(v instanceof ViewGroup)for(int i=0;i<((ViewGroup)v).getChildCount();i++)n+=buttons(((ViewGroup)v).getChildAt(i));return n;}
 static void run(Instrumentation test){Bundle out=new Bundle();WorkConfirmationActivity activity=null;AtomicInteger answers=new AtomicInteger();
  try{
   String id="11111111-1111-4111-8111-111111111111";
   WorkConfirmationActivity.testingApi=answer->{if(answer!=null){check(id.equals(answer),"Only displayed request can be answered");answers.incrementAndGet();return new JSONObject().put("ok",true).put("confirmed",true).put("pending",JSONObject.NULL);}return new JSONObject().put("ok",true).put("server_now",Instant.now().toString()).put("pending",new JSONObject().put("id",id).put("deadline_at",Instant.now().plusSeconds(600).toString()));};
   activity=(WorkConfirmationActivity)test.startActivitySync(new Intent(test.getTargetContext(),WorkConfirmationActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
   WorkConfirmationActivity screen=activity;
   for(int n=0;n<50&&!text(screen.getWindow().getDecorView(),"예, 계속 근무중입니다.").isEnabled();n++){Thread.sleep(100);test.waitForIdleSync();}
   View root=screen.getWindow().getDecorView();check(text(root,"근무 12시간 초과 알림")!=null,"Requested title");check(buttons(root)==1,"Exactly one confirmation button");check(text(root,"예, 계속 근무중입니다.").isEnabled(),"Server challenge enables answer");
   test.runOnMainSync(screen::onBackPressed);check(answers.get()==0&&!screen.isFinishing(),"Back does not continue or dismiss");
   test.runOnMainSync(()->text(root,"예, 계속 근무중입니다.").performClick());
   for(int n=0;n<50&&!screen.isFinishing();n++){Thread.sleep(100);test.waitForIdleSync();}
   check(answers.get()==1&&screen.isFinishing(),"One accepted answer closes popup");
   WorkConfirmationActivity.testingApi=answer->{check(answer==null,"Timeout must not auto-answer");return new JSONObject().put("ok",true).put("pending",JSONObject.NULL);};
   activity=(WorkConfirmationActivity)test.startActivitySync(new Intent(test.getTargetContext(),WorkConfirmationActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
   for(int n=0;n<50&&!activity.isFinishing();n++){Thread.sleep(100);test.waitForIdleSync();}
   check(activity.isFinishing()&&answers.get()==1,"Server expiry closes without confirming");out.putString("oms_work_confirmation","ok");test.finish(-1,out);
  }catch(Throwable e){out.putString("oms_work_confirmation","failed: "+e);test.finish(0,out);}finally{WorkConfirmationActivity.testingApi=null;if(activity!=null){Activity a=activity;test.runOnMainSync(a::finish);}}
 }
}
