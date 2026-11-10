package com.oneminute.guesthousemanager;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import org.json.JSONObject;
import java.io.File;
import java.io.RandomAccessFile;
import java.io.IOException;
import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

/** A stalled video must not prevent text or another room from sending. */
final class ChatQueueProbe {
 static void run(Instrumentation instrument){
  Bundle result=new Bundle();Context context=instrument.getTargetContext();
  CountDownLatch release=new CountDownLatch(1),releaseText=new CountDownLatch(1),textEntered=new CountDownLatch(1),otherTextSent=new CountDownLatch(1);
  try{
   NativeStaffChatApi.clearLocal(context);
   NativeStaffChatApi.prefs(context).edit().putString("token",UUID.randomUUID().toString()).putString("expires",Instant.now().plusSeconds(600).toString()).commit();
   CountDownLatch entered=new CountDownLatch(1),textSent=new CountDownLatch(1),otherSent=new CountDownLatch(1);
   AtomicInteger attempts=new AtomicInteger();
   NativeStaffChatApi api=new NativeStaffChatApi(context){
    @Override JSONObject rpc(String name,JSONObject args)throws Exception{
     if("room-a".equals(args.getString("p_peer"))){attempts.incrementAndGet();entered.countDown();release.await(20,TimeUnit.SECONDS);throw new IOException("Simulated failure");}
     return new JSONObject().put("ok",true);
    }
    @Override JSONObject chat(String action,JSONObject args)throws Exception{
     if("stalled text".equals(args.getString("body"))){textEntered.countDown();releaseText.await(20,TimeUnit.SECONDS);}
     if("other text".equals(args.getString("body")))otherTextSent.countDown();
     if("text".equals(args.getString("body")))textSent.countDown();else otherSent.countDown();
     return new JSONObject().put("ok",true).put("message_id",args.getString("client_id"));
    }
   };
   File video=new File(context.getCacheDir(),"queue-video.mp4");try(RandomAccessFile f=new RandomAccessFile(video,"rw")){f.setLength(100);f.seek(4);f.writeBytes("ftyp");}
   NativeChatOutbox box=NativeChatOutbox.get(context,api);
   box.enqueue("room-a","video","normal",video,"video/mp4");
   check(entered.await(5,TimeUnit.SECONDS),"video starts");
   box.enqueue("room-a","text","normal",null,"");
   box.enqueue("room-b","video","normal",video,"video/mp4");
   check(textSent.await(5,TimeUnit.SECONDS),"text bypasses stalled video in same room");
   check(otherSent.await(5,TimeUnit.SECONDS),"other room bypasses stalled video");
   release.countDown();String id=waitFailed(box);
   for(int n=0;n<5;n++){box.pump();Thread.sleep(40);}
   check(attempts.get()==1,"failed video never retries automatically");
   box.retry(id);check(id.equals(waitFailed(box)),"retry preserves client ID");
   check(attempts.get()==2,"only explicit retry sends again");
   box.cancel(id);check(box.rows("room-a").stream().noneMatch(row->id.equals(row.optString("client_id"))),"cancel removes failed row");
   box.enqueue("room-a","stalled text","normal",null,"");check(textEntered.await(5,TimeUnit.SECONDS),"text starts");
   box.enqueue("room-b","other text","normal",null,"");check(otherTextSent.await(5,TimeUnit.SECONDS),"other room text bypasses stalled text");releaseText.countDown();
   NativeStaffChatApi.clearLocal(context);TransferControlsProbe.verify(context);result.putString("oms_chat_queue","ok");instrument.finish(-1,result);
  }catch(Throwable error){result.putString("oms_chat_queue","failed: "+error);instrument.finish(0,result);}
  finally{release.countDown();releaseText.countDown();NativeChatOutbox.clearInstances();}
 }
 private static String waitFailed(NativeChatOutbox box)throws Exception{
  long deadline=System.currentTimeMillis()+5000;
  while(System.currentTimeMillis()<deadline){for(JSONObject row:box.rows("room-a"))if("failed".equals(row.optString("pending")))return row.getString("client_id");Thread.sleep(20);}
  throw new AssertionError("failure state not persisted");
 }
 private static void check(boolean valid,String message){if(!valid)throw new AssertionError(message);}
}
