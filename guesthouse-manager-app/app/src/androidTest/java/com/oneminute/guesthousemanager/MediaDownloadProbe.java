package com.oneminute.guesthousemanager;
import android.content.Context;
import android.util.Base64;
import org.json.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

final class MediaDownloadProbe {
 static void verify(Context context)throws Exception{
  final String id="bbbbaaaa-1234-4234-8234-000000000001",cancelId="bbbbaaaa-1234-4234-8234-000000000002";
  byte[] source=new byte[2*1048576+237];new Random(42).nextBytes(source);
  AtomicInteger calls=new AtomicInteger();CountDownLatch entered=new CountDownLatch(1),release=new CountDownLatch(1);
  NativeStaffChatApi api=new NativeStaffChatApi(context){@Override JSONObject chat(String action,JSONObject data)throws Exception{
   calls.incrementAndGet();JSONObject value=new JSONObject().put("ok",true).put("mime_type","video/mp4").put("byte_length",source.length).put("part_size",1048576);
   if("download_part".equals(action)){if(cancelId.equals(data.getString("message_id"))){entered.countDown();release.await(10,TimeUnit.SECONDS);}int part=data.getInt("part_index"),start=part*1048576;value.put("part_index",part).put("chunk",Base64.encodeToString(Arrays.copyOfRange(source,start,Math.min(start+1048576,source.length)),Base64.NO_WRAP));}return value;
  }};
  File cached=new File(api.cacheDirectory(),id+".media");cached.delete();new File(api.cacheDirectory(),cancelId+".media").delete();
  NativeStaffChatMedia media=new NativeStaffChatMedia(api);List<Long> received=Collections.synchronizedList(new ArrayList<>());CountDownLatch done=new CountDownLatch(1);AtomicReference<String> failure=new AtomicReference<>();
  try{
   media.get("fixture",id,new NativeStaffChatMedia.Result(){public void progress(long n,long total){if(total!=source.length)failure.set("wrong total");received.add(n);}public void done(File f){try{if(!Arrays.equals(source,java.nio.file.Files.readAllBytes(f.toPath())))failure.set("bytes differ");}catch(Exception e){failure.set(e.toString());}done.countDown();}public void failed(String e){failure.set(e);done.countDown();}});
   check(done.await(15,TimeUnit.SECONDS),"download finished");check(failure.get()==null,"download: "+failure.get());check(received.equals(Arrays.asList(0L,1048576L,2097152L,(long)source.length)),"real monotonic byte progress");check(calls.get()==4,"metadata and three bounded parts");
   CountDownLatch hit=new CountDownLatch(1);media.get("fixture",id,new NativeStaffChatMedia.Result(){public void done(File f){hit.countDown();}public void failed(String e){failure.set(e);hit.countDown();}});check(hit.await(5,TimeUnit.SECONDS)&&calls.get()==4,"cached reopen avoids network");
   AtomicBoolean callback=new AtomicBoolean();NativeStaffChatApi.TransferControl stop=media.get("fixture",cancelId,new NativeStaffChatMedia.Result(){public void done(File f){callback.set(true);}public void failed(String e){callback.set(true);}});
   check(entered.await(5,TimeUnit.SECONDS),"cancel entered download");stop.stop();release.countDown();Thread.sleep(150);check(!callback.get(),"cancelled request cannot deliver");check(!new File(api.cacheDirectory(),cancelId+".media").exists(),"partial file not cached");
  }finally{release.countDown();media.close();cached.delete();}
 }
 static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
}
