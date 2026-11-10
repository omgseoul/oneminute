package com.oneminute.guesthousemanager;

import android.app.Instrumentation;
import android.content.Context;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.os.Bundle;
import android.util.Base64;
import org.json.JSONObject;
import java.io.*;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Real 55–65MB video through the shipped Media3 compressor and durable outbox. */
public final class LargeVideoProbe {
 public static void run(Instrumentation instrument){
  Bundle report=new Bundle();Context c=instrument.getTargetContext();
  try{
   File dir=new File(c.getFilesDir(),"large-video-probe");dir.mkdirs();
   File source=new File(dir,"source.mp4");
   try(InputStream in=instrument.getContext().getAssets().open("large-video.mp4");OutputStream out=new FileOutputStream(source)){
    byte[] b=new byte[65536];int n;while((n=in.read(b))!=-1)out.write(b,0,n);
   }
   check(source.length()>=55000000&&source.length()<=65000000,"real source size");report.putLong("source_bytes",source.length());
   AtomicReference<File> prepared=new AtomicReference<>();AtomicReference<String> failure=new AtomicReference<>();CountDownLatch ready=new CountDownLatch(1);
   NativeChatUpload upload=new NativeChatUpload(c);long start=System.currentTimeMillis();
   instrument.runOnMainSync(()->upload.prepare(Uri.fromFile(source),dir,new NativeChatUpload.Callback(){
    public void status(String text){}public void done(File f,String mime){prepared.set(f);ready.countDown();}public void failed(String message){failure.set(message);ready.countDown();}
   }));
   check(ready.await(240,TimeUnit.SECONDS),"compression timeout");check(failure.get()==null,"compression: "+failure.get());
   File compressed=prepared.get();check(compressed!=null&&compressed.length()>0&&compressed.length()<=20971520,"compressed size");
   report.putLong("compressed_bytes",compressed.length());report.putLong("compression_ms",System.currentTimeMillis()-start);
   MediaMetadataRetriever metadata=new MediaMetadataRetriever();try{metadata.setDataSource(compressed.getPath());check(Long.parseLong(metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION))>=19000,"duration preserved");check(metadata.getFrameAtTime(1000000)!=null,"compressed video decodes");}finally{metadata.release();}
   byte[] expected=hash(compressed);
   for(String role:new String[]{"employee","administrator"}){
    NativeStaffChatApi.clearLocal(c);
    NativeStaffChatApi.prefs(c).edit().putString("token",UUID.randomUUID().toString()).putString("expires",Instant.now().plusSeconds(600).toString()).commit();
    File received=new File(dir,role+"-received.mp4");CountDownLatch sent=new CountDownLatch(1);
    Set<Integer> parts=new HashSet<>();AtomicBoolean lost=new AtomicBoolean();AtomicReference<Throwable> error=new AtomicReference<>();
    NativeStaffChatApi api=new NativeStaffChatApi(c){
     @Override JSONObject rpc(String name,JSONObject args)throws Exception{
      try{check(name.equals("staff_chat_upload_chunk"),"chunk RPC");byte[] b=Base64.decode(args.getString("p_chunk"),Base64.DEFAULT);int part=args.getInt("p_part_index");check(b.length<=1048576,"bounded chunk");
       if(parts.add(part))try(RandomAccessFile out=new RandomAccessFile(received,"rw")){out.seek((long)part*1048576);out.write(b);}
       if(part==1&&!lost.getAndSet(true))throw new IOException("lost response");
       return new JSONObject().put("ok",true);
      }catch(AssertionError e){error.set(e);throw new IOException(e);}
     }
     @Override JSONObject chat(String action,JSONObject args)throws Exception{
      try{check(args.optBoolean("uploaded")&&!args.has("photo"),"small final request");check(Arrays.equals(expected,LargeVideoProbe.hash(received)),"received bytes match");sent.countDown();return new JSONObject().put("ok",true).put("message_id",UUID.randomUUID().toString());}
      catch(AssertionError e){error.set(e);sent.countDown();throw new IOException(e);}
     }
    };
    NativeChatOutbox box=NativeChatOutbox.get(c,api);box.enqueue(role.equals("employee")?"owner:00000000-0000-4000-8000-000000000001":"employee:00000000-0000-4000-8000-000000000002","video","normal",compressed,"video/mp4");
    check(sent.await(60,TimeUnit.SECONDS),role+" outbox timeout");check(error.get()==null,role+" "+error.get());check(lost.get(),"retry exercised");report.putString(role,"compressed, chunked, retried, received byte-identical");
    NativeChatOutbox.clearInstances();received.delete();
   }
   instrument.runOnMainSync(upload::close);source.delete();compressed.delete();NativeStaffChatApi.clearLocal(c);report.putString("oms_large_video","ok");instrument.finish(-1,report);
  }catch(Throwable e){report.putString("oms_large_video","failed");report.putString("error",e.toString());instrument.finish(0,report);}
 }
 private static byte[] hash(File file)throws Exception{MessageDigest digest=MessageDigest.getInstance("SHA-256");try(InputStream in=new FileInputStream(file)){byte[] b=new byte[65536];int n;while((n=in.read(b))!=-1)digest.update(b,0,n);}return digest.digest();}
 private static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
}
