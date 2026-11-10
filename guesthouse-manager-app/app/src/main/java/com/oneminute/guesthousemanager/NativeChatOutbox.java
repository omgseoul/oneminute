package com.oneminute.guesthousemanager;

import android.content.Context;
import android.os.*;
import android.util.AtomicFile;
import org.json.*;
import java.io.*;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;

/** Durable per-room lanes. Text remains independent of attachments. Server client_id makes lost replies safe. */
final class NativeChatOutbox {
 private static final Map<String,NativeChatOutbox> instances=new HashMap<>();
 static synchronized NativeChatOutbox get(Context c,NativeStaffChatApi api)throws Exception{
  NativeChatOutbox box=instances.get(api.scope);if(box==null){box=new NativeChatOutbox(c.getApplicationContext(),api);instances.put(api.scope,box);}return box;
 }
 static synchronized void clearInstances(){for(NativeChatOutbox box:instances.values()){synchronized(box){box.closed=true;for(NativeStaffChatApi.TransferControl control:box.transfers.values())control.stop();box.main.removeCallbacksAndMessages(null);box.sender.shutdownNow();}}instances.clear();}
 static void resume(Context c){Context app=c.getApplicationContext();new Thread(()->{try{NativeStaffChatApi api=new NativeStaffChatApi(app);File file=new File(app.getFilesDir(),"staff-chat-drafts/"+api.scope+"/outbox.json");if(file.exists())get(app,api).pump();}catch(Exception ignored){}},"oms-outbox-resume").start();}
 private final NativeStaffChatApi api;private final AtomicFile disk;private final Handler main=new Handler(Looper.getMainLooper());
 private final ExecutorService sender=Executors.newFixedThreadPool(4);private final List<JSONObject> items=new ArrayList<>();
 private final Set<Runnable> listeners=new HashSet<>();private boolean closed;private int sentRevision;private final Set<String> activeLanes=new HashSet<>();private final Map<String,NativeStaffChatApi.TransferControl> transfers=new HashMap<>();
 private NativeChatOutbox(Context c,NativeStaffChatApi api)throws Exception{this.api=api;File dir=new File(c.getFilesDir(),"staff-chat-drafts/"+api.scope);dir.mkdirs();disk=new AtomicFile(new File(dir,"outbox.json"));if(disk.getBaseFile().exists()){JSONArray a=new JSONArray(new String(disk.readFully(),java.nio.charset.StandardCharsets.UTF_8));for(int i=0;i<a.length();i++){JSONObject item=a.getJSONObject(i);if("sending".equals(item.optString("status"))||"saving".equals(item.optString("status")))item.put("status","failed").put("error","전송이 중단되었습니다. 재시도를 눌러주세요.");if("cancelled".equals(item.optString("status"))){deleteFile(item);continue;}items.add(item);}persist();}}
 synchronized int sentRevision(){return sentRevision;}
 synchronized void observe(Runnable r){listeners.add(r);}synchronized void unobserve(Runnable r){listeners.remove(r);}
 private void changed(){List<Runnable> copy;synchronized(this){copy=new ArrayList<>(listeners);}main.post(()->{for(Runnable r:copy)r.run();});}
 private synchronized void persist()throws Exception{if(closed)throw new IOException("Queue closed");FileOutputStream out=null;try{out=disk.startWrite();out.write(new JSONArray(items).toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));disk.finishWrite(out);}catch(Exception e){if(out!=null)disk.failWrite(out);throw e;}}
 synchronized void enqueue(String peer,String body,String priority,File file,String mime)throws Exception{
  JSONObject item=new JSONObject().put("client_id",UUID.randomUUID().toString()).put("peer",peer).put("body",body).put("priority",priority).put("file",file==null?"":file.getCanonicalPath()).put("attachment_type",mime).put("created_at",Instant.now().toString()).put("status","queued");
  items.add(item);try{persist();}catch(Exception e){items.remove(item);throw e;}changed();pump();
 }
 synchronized List<JSONObject> rows(String peer){List<JSONObject> result=new ArrayList<>();for(JSONObject item:items)if(peer.equals(item.optString("peer"))&&!"cancelled".equals(item.optString("status")))try{JSONObject m=item.optJSONObject("message");if(m==null)m=new JSONObject(item.toString()).put("id","local:"+item.getString("client_id")).put("mine",true).put("pending",item.optString("status"));result.add(new JSONObject(m.toString()));}catch(Exception ignored){}return result;}
 synchronized void acknowledge(JSONArray messages){if(messages==null)return;Set<String> ids=new HashSet<>(),clients=new HashSet<>();for(int i=0;i<messages.length();i++){JSONObject m=messages.optJSONObject(i);if(m!=null){ids.add(m.optString("id"));clients.add(m.optString("client_id"));}}List<JSONObject> done=new ArrayList<>();for(JSONObject item:items)if("sent".equals(item.optString("status"))&&(ids.contains(item.optString("message_id"))||clients.contains(item.optString("client_id"))))done.add(item);if(done.isEmpty())return;items.removeAll(done);try{persist();for(JSONObject item:done){String path=item.optString("file");if(!path.isEmpty())new File(path).delete();}}catch(Exception e){items.addAll(done);}}
 private String lane(JSONObject item){return (item.optString("file").isEmpty()?"text:":"media:")+item.optString("peer");}
 synchronized void retry(String id){
  for(JSONObject item:items)if(id.equals(item.optString("client_id"))&&("failed".equals(item.optString("status"))||"paused".equals(item.optString("status")))){
   try{item.put("blocked",false).put("error","").put("status","queued");item.remove("upload_percent");persist();}
   catch(Exception error){try{item.put("status","failed");}catch(JSONException ignored){}}
  }
  changed();pump();
 }
 synchronized void pause(String id){
  for(JSONObject item:items)if(id.equals(item.optString("client_id"))&&Arrays.asList("queued","sending","saving").contains(item.optString("status"))){
   try{item.put("status","paused");persist();NativeStaffChatApi.TransferControl control=transfers.get(id);if(control!=null)control.stop();}catch(Exception ignored){}
  }changed();pump();
 }
 synchronized void cancel(String id){
  for(JSONObject item:new ArrayList<>(items))if(id.equals(item.optString("client_id"))&&!"sent".equals(item.optString("status"))){
   try{item.put("status","cancelled");persist();NativeStaffChatApi.TransferControl control=transfers.get(id);if(control!=null)control.stop();else removeCancelled(item);}catch(Exception ignored){}
  }changed();pump();
 }
 private void deleteFile(JSONObject item){String path=item.optString("file");if(!path.isEmpty())new File(path).delete();}
 private synchronized void removeCancelled(JSONObject item)throws Exception{items.remove(item);try{persist();deleteFile(item);}catch(Exception error){items.add(item);throw error;}}
 synchronized void pump(){
  if(closed||!api.valid())return;boolean updated=false;
  for(JSONObject item:items){
   if(!"queued".equals(item.optString("status")))continue;
   String key=lane(item);boolean media=key.startsWith("media:");int count=0;
   for(String active:activeLanes)if(active.startsWith(media?"media:":"text:"))count++;
   if(activeLanes.contains(key)||count>=2)continue;
   try{item.put("status","sending");persist();}catch(Exception error){try{item.put("status","failed");}catch(JSONException ignored){}continue;}
   updated=true;activeLanes.add(key);NativeStaffChatApi.TransferControl control=new NativeStaffChatApi.TransferControl();transfers.put(item.optString("client_id"),control);sender.execute(()->send(item,key,control));
  }
  if(updated)changed();
 }
 private void send(JSONObject item,String key,NativeStaffChatApi.TransferControl control){
   api.beginTransfer(control);
   final long deadline=System.nanoTime()+TimeUnit.MINUTES.toNanos(3);
   try{
    control.check();JSONObject args=new JSONObject().put("peer",item.getString("peer")).put("body",item.getString("body")).put("priority",item.getString("priority")).put("client_id",item.getString("client_id"));
    String path=item.optString("file"),type=item.optString("attachment_type");if(!path.isEmpty()){
     File file=new File(path);if(!file.exists()||file.length()>(type.startsWith("video/")?20971520:1572864))throw new NativeStaffChatApi.ChatException("첨부 파일을 확인해주세요.",false);
     if(type.startsWith("video/")) {
      int total=(int)((file.length()+1048575)/1048576);byte[] chunk=new byte[1048576];
      try(DataInputStream in=new DataInputStream(new FileInputStream(file))){for(int part=0;part<total;part++){
       control.check();if(closed||System.nanoTime()>deadline)throw new IOException("전송 시간이 초과되었습니다. 재시도를 눌러주세요.");
       int length=(int)Math.min(1048576,file.length()-(long)part*1048576);in.readFully(chunk,0,length);
       api.rpc("staff_chat_upload_chunk",new JSONObject().put("p_client_id",item.getString("client_id")).put("p_peer",item.getString("peer")).put("p_mime_type",type).put("p_part_index",part).put("p_total_parts",total).put("p_chunk",android.util.Base64.encodeToString(chunk,0,length,android.util.Base64.NO_WRAP)));
       synchronized(this){item.put("upload_percent",(part+1)*100/total);persist();}changed();
      }}args.put("uploaded",true);
     }else{byte[] bytes=new byte[(int)file.length()];try(DataInputStream in=new DataInputStream(new FileInputStream(file))){in.readFully(bytes);}args.put("photo","data:"+type+";base64,"+android.util.Base64.encodeToString(bytes,android.util.Base64.NO_WRAP));}
    }
    synchronized(this){control.check();item.put("status","saving");persist();}changed();
    JSONObject result=api.chat("send",args);
    synchronized(this){item.put("message_id",result.getString("message_id")).put("message",result.optJSONObject("message")).put("status","sent").put("attempts",0);persist();sentRevision++;}
   }catch(Exception error){synchronized(this){try{if(!control.stopped){int attempts=item.optInt("attempts")+1;item.put("status","failed").put("error",error.getMessage()).put("blocked",true).put("attempts",attempts);persist();}}catch(Exception ignored){}}}
   finally{api.endTransfer();synchronized(this){transfers.remove(item.optString("client_id"));activeLanes.remove(key);if("cancelled".equals(item.optString("status")))try{removeCancelled(item);}catch(Exception ignored){}}changed();main.post(this::pump);}
 }
}
