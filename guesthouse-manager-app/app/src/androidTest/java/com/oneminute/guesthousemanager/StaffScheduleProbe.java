package com.oneminute.guesthousemanager;
import android.app.*;import android.content.*;import android.os.*;import android.view.*;import android.widget.*;import org.json.*;import java.lang.reflect.*;import java.util.concurrent.*;import java.util.concurrent.atomic.*;
/** Local fake API only. Exercises the real composer and scheduling sheet. */
final class StaffScheduleProbe {
 static final String TOKEN="12345678-1234-4234-8234-123456789abc",ID="12345678-1234-4234-8234-123456789def",PEER="employee:"+ID;
 final Instrumentation test;NativeStaffChatActivity activity;Fake api;
 StaffScheduleProbe(Instrumentation test){this.test=test;}
 static void run(Instrumentation i){Bundle b=new Bundle();try{new StaffScheduleProbe(i).verify();b.putString("oms_schedule","ok");i.finish(-1,b);}catch(Throwable e){e.printStackTrace();b.putString("oms_schedule","failed: "+e);i.finish(0,b);}}
 <T>T ui(Callable<T> call)throws Exception{AtomicReference<T> value=new AtomicReference<>();AtomicReference<Throwable> error=new AtomicReference<>();test.runOnMainSync(()->{try{value.set(call.call());}catch(Throwable e){error.set(e);}});if(error.get()!=null)throw new Exception(error.get());return value.get();}
 Object field(Object o,String name)throws Exception{Field f=o.getClass().getDeclaredField(name);f.setAccessible(true);return f.get(o);}
 void waitFor(Callable<Boolean> call)throws Exception{long deadline=System.currentTimeMillis()+12000;while(System.currentTimeMillis()<deadline){if(ui(call))return;Thread.sleep(80);}throw new AssertionError("schedule UI timeout");}
 View find(View v,String text){if(v instanceof TextView&&text.contentEquals(((TextView)v).getText()))return v;if(v instanceof ViewGroup)for(int n=0;n<((ViewGroup)v).getChildCount();n++){View match=find(((ViewGroup)v).getChildAt(n),text);if(match!=null)return match;}return null;}
 View root()throws Exception{Object controller=field(activity,"schedules");PopupWindow popup=(PopupWindow)field(controller,"popup");if(popup!=null&&popup.isShowing())return popup.getContentView();Dialog dialog=(Dialog)field(controller,"dialog");return dialog!=null?dialog.getWindow().getDecorView():activity.getWindow().getDecorView();}
 void capture(String name)throws Exception{test.waitForIdleSync();Thread.sleep(150);android.graphics.Bitmap bmp=test.getUiAutomation().takeScreenshot();if(bmp!=null){try(java.io.FileOutputStream out=new java.io.FileOutputStream(new java.io.File(test.getTargetContext().getExternalFilesDir(null),name+".png"))){bmp.compress(android.graphics.Bitmap.CompressFormat.PNG,100,out);}bmp.recycle();}}
 void verify()throws Exception{
  Context c=test.getTargetContext();c.getSharedPreferences("omg_receipts",0).edit().putString("token",TOKEN).putString("expires","2099-01-01T00:00:00Z").commit();NativeMessageBadge.loader=x->new NativeMessageBadge.Counts(0,0);NativeStaffChatActivity.apiFactory=x->{api=new Fake(x);return api;};
  try{activity=(NativeStaffChatActivity)test.startActivitySync(new Intent(c,NativeStaffChatActivity.class).putExtra("peer",PEER).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));waitFor(()->((EditText)field(activity,"input")).isEnabled());
   ui(()->{if(((View)field(activity,"scheduled")).getVisibility()!=View.GONE)throw new AssertionError("calendar must be hidden when no reservations");if(find(activity.getWindow().getDecorView(),"◷ 예약 메시지")!=null)throw new AssertionError("no second composer row");((EditText)field(activity,"input")).setText("출근 때 확인해주세요");((TextView)field(activity,"send")).performLongClick();return null;});waitFor(()->find(root(),"근무자 출근 시")!=null);
   if(api.immediate!=0)throw new AssertionError("long press must not send immediately");
   capture("staff-schedule-menu");
   ui(()->{PopupWindow popup=(PopupWindow)field(field(activity,"schedules"),"popup");if(popup.getHeight()>StaffChatUi.dp(c,150))throw new AssertionError("menu must be compact");find(root(),"근무자 출근 시").performClick();return null;});waitFor(()->find(root(),"예약하기")!=null);
   ui(()->{find(root(),"예약하기").performClick();return null;});waitFor(()->api.saved!=null&&((EditText)field(activity,"input")).length()==0&&((View)field(activity,"scheduled")).getVisibility()==View.VISIBLE);
   if(!"checkin".equals(api.saved.getString("mode"))||!ID.equals(api.saved.getString("trigger_employee_id")))throw new AssertionError("wrong check-in recipient");
   ui(()->{View calendar=(View)field(activity,"scheduled"),emoji=(View)field(activity,"emoji");int[] a=new int[2],b=new int[2];calendar.getLocationOnScreen(a);emoji.getLocationOnScreen(b);if(a[0]+calendar.getWidth()>b[0]+1)throw new AssertionError("calendar must be immediately left of emoji");EditText input=(EditText)field(activity,"input");if(input.getPaddingRight()<StaffChatUi.dp(c,66))throw new AssertionError("text must not overlap calendar");calendar.performClick();return null;});waitFor(()->root().findViewWithTag("scheduled-item-"+ID)!=null);capture("staff-schedule-list");
   ui(()->{root().findViewWithTag("scheduled-item-"+ID).performClick();return null;});waitFor(()->find(root(),"예약 변경")!=null);ui(()->{find(root(),"날짜·시간").performClick();find(root(),"예약 변경").performClick();return null;});waitFor(()->api.updated);if(!"time".equals(api.saved.getString("mode")))throw new AssertionError("time reschedule missing");
   ui(()->{api.saved=null;((NativeStaffSchedule)field(activity,"schedules")).refresh(true);return null;});waitFor(()->((View)field(activity,"scheduled")).getVisibility()==View.GONE);
   ui(()->{((EditText)field(activity,"input")).setText("일반 보내기 유지");((TextView)field(activity,"send")).performClick();return null;});waitFor(()->api.immediate==1);
  }finally{if(activity!=null)ui(()->{activity.finish();return null;});NativeStaffChatActivity.apiFactory=NativeStaffChatApi::new;}
 }
 static final class Fake extends NativeStaffChatApi {
  volatile JSONObject saved;volatile boolean updated;volatile int immediate;
  Fake(Context c)throws Exception{super(c);}
  @Override JSONObject chat(String action,JSONObject data)throws Exception{
   JSONObject r=new JSONObject().put("ok",true);
   if("schedule_list".equals(action))return r.put("items",saved==null?new JSONArray():new JSONArray().put(new JSONObject(saved.toString()).put("id",ID).put("revision",1).put("trigger_name","테스트 직원"))).put("recipients",new JSONArray().put(new JSONObject().put("id",ID).put("name","테스트 직원")));
   if("schedule_create".equals(action)||"schedule_update".equals(action)){saved=new JSONObject(data.toString());updated="schedule_update".equals(action);return r;}
   if("send".equals(action)){immediate++;return r.put("message_id",ID).put("message",new JSONObject().put("id",ID).put("body",data.getString("body")).put("mine",true).put("created_at",java.time.Instant.now().toString()));}
   return r.put("messages",new JSONArray()).put("can_send",true).put("peer",new JSONObject().put("display_name","테스트 직원"));
  }
  @Override JSONObject rpc(String name,JSONObject args)throws Exception{if("chat_live_ticket".equals(name))throw new java.io.IOException("local fixture");return new JSONObject().put("ok",true).put("profile",new JSONObject().put("display_name","테스트 직원"));}
  @Override void notifyMessage(String id){}
 }
}
