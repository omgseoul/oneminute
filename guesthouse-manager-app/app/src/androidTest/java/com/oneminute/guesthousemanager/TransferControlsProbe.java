package com.oneminute.guesthousemanager;
import android.content.Context;
import org.json.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
final class TransferControlsProbe {
 static void verify(Context context)throws Exception{
  NativeStaffChatApi.clearLocal(context);
  CountDownLatch entered=new CountDownLatch(1),release=new CountDownLatch(1),resumed=new CountDownLatch(1),finalSend=new CountDownLatch(1),cancelEntered=new CountDownLatch(1),cancelRelease=new CountDownLatch(1);
  AtomicInteger attempts=new AtomicInteger();AtomicReference<String> client=new AtomicReference<>();
  NativeStaffChatApi api=new NativeStaffChatApi(context){
   JSONObject rpc(String name,JSONObject args)throws Exception{
    if(args.getString("p_peer").equals("cancel")){cancelEntered.countDown();cancelRelease.await(5,TimeUnit.SECONDS);return new JSONObject().put("ok",true);}
    int n=attempts.incrementAndGet();if(n==1){client.set(args.getString("p_client_id"));entered.countDown();release.await(5,TimeUnit.SECONDS);}else{check(client.get().equals(args.getString("p_client_id")),"same client ID on resume");resumed.countDown();}return new JSONObject().put("ok",true);
   }
   JSONObject chat(String action,JSONObject args)throws Exception{check(!args.getString("peer").equals("cancel"),"cancelled upload cannot finalize");finalSend.countDown();return new JSONObject().put("message_id",args.getString("client_id"));}
  };
  File file=new File(context.getCacheDir(),"control-video.mp4");try(FileOutputStream out=new FileOutputStream(file)){out.write(new byte[100]);}
  NativeChatOutbox box=NativeChatOutbox.get(context,api);
  try{
   box.enqueue("pause","video","normal",file,"video/mp4");check(entered.await(5,TimeUnit.SECONDS),"upload entered");String id=client.get();box.pause(id);release.countDown();Thread.sleep(100);check("paused".equals(box.rows("pause").get(0).optString("pending")),"paused remains paused");check(finalSend.getCount()==1,"pause prevents finalization");box.pump();Thread.sleep(80);check(attempts.get()==1,"no automatic resume");
   NativeChatOutbox.clearInstances();box=NativeChatOutbox.get(context,api);check("paused".equals(box.rows("pause").get(0).optString("pending")),"pause survives recreation");box.retry(id);check(resumed.await(5,TimeUnit.SECONDS),"explicit resume");check(finalSend.await(5,TimeUnit.SECONDS),"resumed transfer finalizes");
   File cancel=new File(context.getCacheDir(),"cancel-video.mp4");try(FileOutputStream out=new FileOutputStream(cancel)){out.write(new byte[100]);}box.enqueue("cancel","video","normal",cancel,"video/mp4");check(cancelEntered.await(5,TimeUnit.SECONDS),"cancel upload entered");String cancelId=box.rows("cancel").get(0).optString("client_id");box.cancel(cancelId);check(box.rows("cancel").isEmpty(),"active cancellation hides row");cancelRelease.countDown();for(int i=0;i<100&&cancel.exists();i++)Thread.sleep(10);check(!cancel.exists(),"cancel cleans local file after sender exits");
   okhttp3.Call call=new okhttp3.OkHttpClient().newCall(new okhttp3.Request.Builder().url("https://example.com").build());NativeStaffChatApi.TransferControl control=new NativeStaffChatApi.TransferControl();control.bind(call);control.stop();check(call.isCanceled(),"stop cancels bound HTTP call");
   List<JSONObject> rows=new ArrayList<>();for(int i=0;i<75;i++)rows.add(new JSONObject().put("id",String.valueOf(i)));NativeChatSnapshots.put("account-a","room",rows,new JSONObject().put("display_name","cached"));check(NativeChatSnapshots.get("account-b","room")==null,"cache isolated by account");check(NativeChatSnapshots.get("account-a","room").getJSONArray("messages").length()==50,"recent cache bounded");NativeChatSnapshots.clear();check(NativeChatSnapshots.get("account-a","room")==null,"logout clears cache");
  }finally{release.countDown();cancelRelease.countDown();NativeStaffChatApi.clearLocal(context);file.delete();}
 }
 static void check(boolean yes,String reason){if(!yes)throw new AssertionError(reason);}
}
