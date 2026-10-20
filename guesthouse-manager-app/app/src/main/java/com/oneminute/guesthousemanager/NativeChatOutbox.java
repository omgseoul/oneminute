package com.oneminute.guesthousemanager;

import android.content.Context;
import android.os.*;
import android.util.AtomicFile;
import org.json.*;
import java.io.*;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;

/** Durable FIFO, independent of an Activity. Server client_id makes lost replies safe. */
final class NativeChatOutbox {
 private static final Map<String,NativeChatOutbox> instances=new HashMap<>();
 static synchronized NativeChatOutbox get(Context c,NativeStaffChatApi api)throws Exception{
  NativeChatOutbox box=instances.get(api.scope);if(box==null){box=new NativeChatOutbox(c.getApplicationContext(),api);instances.put(api.scope,box);}return box;
 }
 static synchronized void clearInstances(){for(NativeChatOutbox box:instances.values()){box.main.removeCallbacksAndMessages(null);box.sender.shutdownNow();}instances.clear();}
 private final NativeStaffChatApi api;private final AtomicFile disk;private final Handler main=new Handler(Looper.getMainLooper());
 private final ExecutorService sender=Executors.newSingleThreadExecutor();private final List<JSONObject> items=new ArrayList<>();
 private final Set<Runnable> listeners=new HashSet<>();private boolean running;private final Runnable retry=this::pump;
 private NativeChatOutbox(Context c,NativeStaffChatApi api)throws Exception{this.api=api;File dir=new File(c.getFilesDir(),"staff-chat-drafts/"+api.scope);dir.mkdirs();disk=new AtomicFile(new File(dir,"outbox.json"));if(disk.getBaseFile().exists()){JSONArray a=new JSONArray(new String(disk.readFully(),java.nio.charset.StandardCharsets.UTF_8));for(int i=0;i<a.length();i++)items.add(a.getJSONObject(i));}}
 synchronized void observe(Runnable r){listeners.add(r);}synchronized void unobserve(Runnable r){listeners.remove(r);}
 private void changed(){List<Runnable> copy;synchronized(this){copy=new ArrayList<>(listeners);}main.post(()->{for(Runnable r:copy)r.run();});}
 private synchronized void persist()throws Exception{FileOutputStream out=null;try{out=disk.startWrite();out.write(new JSONArray(items).toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));disk.finishWrite(out);}catch(Exception e){if(out!=null)disk.failWrite(out);throw e;}}
 synchronized void enqueue(String peer,String body,String priority,File file,String mime)throws Exception{
  JSONObject item=new JSONObject().put("client_id",UUID.randomUUID().toString()).put("peer",peer).put("body",body).put("priority",priority).put("file",file==null?"":file.getCanonicalPath()).put("attachment_type",mime).put("created_at",Instant.now().toString()).put("status","queued");
  items.add(item);try{persist();}catch(Exception e){items.remove(item);throw e;}changed();pump();
 }
 synchronized List<JSONObject> rows(String peer){List<JSONObject> result=new ArrayList<>();for(JSONObject item:items)if(peer.equals(item.optString("peer")))try{JSONObject m=item.optJSONObject("message");if(m==null)m=new JSONObject(item.toString()).put("id","local:"+item.getString("client_id")).put("mine",true).put("pending",item.optString("status"));result.add(new JSONObject(m.toString()));}catch(Exception ignored){}return result;}
 synchronized void acknowledge(JSONArray messages){if(messages==null)return;Set<String> ids=new HashSet<>(),clients=new HashSet<>();for(int i=0;i<messages.length();i++){JSONObject m=messages.optJSONObject(i);if(m!=null){ids.add(m.optString("id"));clients.add(m.optString("client_id"));}}List<JSONObject> done=new ArrayList<>();for(JSONObject item:items)if("sent".equals(item.optString("status"))&&(ids.contains(item.optString("message_id"))||clients.contains(item.optString("client_id"))))done.add(item);if(done.isEmpty())return;items.removeAll(done);try{persist();for(JSONObject item:done){String path=item.optString("file");if(!path.isEmpty())new File(path).delete();}}catch(Exception e){items.addAll(done);}}
 synchronized void retry(String id){for(JSONObject item:items)if(id.equals(item.optString("client_id")))try{item.put("blocked",false).put("status","queued");persist();}catch(Exception ignored){}pump();}
 synchronized void pump(){
  if(running||!api.valid())return;JSONObject next=null;for(JSONObject item:items)if(!"sent".equals(item.optString("status"))){next=item;break;}if(next==null||next.optBoolean("blocked"))return;
  main.removeCallbacks(retry);final JSONObject item=next;running=true;
  sender.execute(()->{
   boolean failed=false;
   try{
    synchronized(this){item.put("status","sending");persist();}changed();
    JSONObject args=new JSONObject().put("peer",item.getString("peer")).put("body",item.getString("body")).put("priority",item.getString("priority")).put("client_id",item.getString("client_id"));
    String path=item.optString("file"),type=item.optString("attachment_type");if(!path.isEmpty()){
     File file=new File(path);if(!file.exists()||file.length()>(type.startsWith("video/")?20971520:1572864))throw new NativeStaffChatApi.ChatException("첨부 파일을 확인해주세요.",false);
     byte[] bytes=new byte[(int)file.length()];try(DataInputStream in=new DataInputStream(new FileInputStream(file))){in.readFully(bytes);}args.put("photo","data:"+type+";base64,"+android.util.Base64.encodeToString(bytes,android.util.Base64.NO_WRAP));
    }
    JSONObject result=api.chat("send",args);
    synchronized(this){item.put("message_id",result.getString("message_id")).put("message",result.optJSONObject("message")).put("status","sent").put("attempts",0);persist();}
   }catch(Exception error){failed=true;synchronized(this){try{item.put("status","failed").put("blocked",error instanceof NativeStaffChatApi.ChatException&&!((NativeStaffChatApi.ChatException)error).retryable).put("attempts",item.optInt("attempts")+1);persist();}catch(Exception ignored){}}}
   finally{synchronized(this){running=false;}changed();final boolean delayed=failed;main.post(()->{main.removeCallbacks(retry);main.postDelayed(retry,delayed?Math.min(30000,1000L<<Math.min(item.optInt("attempts"),5)):0);});}
  });
 }
}
