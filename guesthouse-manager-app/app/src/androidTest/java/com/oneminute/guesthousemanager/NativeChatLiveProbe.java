package com.oneminute.guesthousemanager;
import android.app.Instrumentation;
import android.os.*;
import org.json.*;
import okhttp3.*;
import okio.ByteString;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.atomic.*;

final class NativeChatLiveProbe {
 static void run(Instrumentation instrumentation)throws Exception{
  AtomicInteger tickets=new AtomicInteger(),changes=new AtomicInteger();AtomicReference<Wire> latest=new AtomicReference<>();List<String> topics=new ArrayList<>();
  NativeStaffChatApi api=new NativeStaffChatApi(instrumentation.getTargetContext()){
   @Override JSONObject rpc(String name,JSONObject args)throws Exception{if(!"chat_live_ticket".equals(name))throw new AssertionError("unexpected RPC");tickets.incrementAndGet();return new JSONObject().put("ok",true).put("topic","oms-live:"+UUID.randomUUID()).put("expires_at",Instant.now().plusSeconds(600).toString());}
  };
  NativeChatLive live=new NativeChatLive(api,changes::incrementAndGet,(request,listener)->{Wire wire=new Wire(request,listener,topics);latest.set(wire);new Handler(Looper.getMainLooper()).post(()->listener.onOpen(wire,null));return wire;});
  try{
   instrumentation.runOnMainSync(live::start);await(()->changes.get()==1);
   if(!latest.get().privateJoin)throw new AssertionError("native channel must be private");
   latest.get().listener.onMessage(latest.get(),"{\"event\":\"broadcast\",\"payload\":{\"event\":\"changed\",\"payload\":{}}}");await(()->changes.get()==2);
   latest.get().listener.onFailure(latest.get(),new java.io.IOException("fixture disconnect"),null);await(()->tickets.get()>=2&&changes.get()>=3);
   if(topics.size()<2||topics.get(0).equals(topics.get(1)))throw new AssertionError("fresh reconnect ticket required");
   instrumentation.runOnMainSync(live::stop);int before=tickets.get();Thread.sleep(1300);if(tickets.get()!=before)throw new AssertionError("stopped activity reconnects");
  }finally{instrumentation.runOnMainSync(live::destroy);}
 }
 interface Condition{boolean get();}
 static void await(Condition condition)throws Exception{long until=SystemClock.uptimeMillis()+6000;while(SystemClock.uptimeMillis()<until){if(condition.get())return;Thread.sleep(20);}throw new AssertionError("native realtime condition timed out");}
 static class Wire implements WebSocket{
  final Request request;final WebSocketListener listener;final List<String> topics;boolean privateJoin;
  Wire(Request request,WebSocketListener listener,List<String> topics){this.request=request;this.listener=listener;this.topics=topics;}
  public Request request(){return request;}public long queueSize(){return 0;}public boolean send(ByteString b){return false;}public boolean close(int code,String reason){return true;}public void cancel(){}
  public boolean send(String text){try{JSONObject m=new JSONObject(text);if("phx_join".equals(m.optString("event"))){privateJoin=m.getJSONObject("payload").getJSONObject("config").getBoolean("private");topics.add(m.getString("topic"));listener.onMessage(this,new JSONObject().put("event","phx_reply").put("topic",m.getString("topic")).put("payload",new JSONObject().put("status","ok")).toString());}else if("heartbeat".equals(m.optString("event")))listener.onMessage(this,"{\"event\":\"phx_reply\",\"topic\":\"phoenix\",\"payload\":{\"status\":\"ok\"}}");return true;}catch(Exception e){throw new AssertionError(e);}}
 }
}
