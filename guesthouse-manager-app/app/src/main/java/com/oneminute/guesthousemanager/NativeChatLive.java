package com.oneminute.guesthousemanager;
import android.os.*;
import org.json.*;
import okhttp3.*;
import java.time.Instant;
import java.util.concurrent.*;

/** Receive-only Supabase protocol v1; fresh private ticket on each reconnect. */
final class NativeChatLive {
 private static final OkHttpClient HTTP=new OkHttpClient.Builder().build();
 private final NativeStaffChatApi api;private final Runnable changed;private final WebSocket.Factory sockets;private final Handler main=new Handler(Looper.getMainLooper());
 private final ExecutorService auth=Executors.newSingleThreadExecutor();private WebSocket socket;
 private boolean stopped=true,connected;private int generation,attempt,ref;private final Runnable reconnect=this::connect;
 NativeChatLive(NativeStaffChatApi api,Runnable changed){this(api,changed,HTTP);}
 NativeChatLive(NativeStaffChatApi api,Runnable changed,WebSocket.Factory sockets){this.api=api;this.changed=changed;this.sockets=sockets;}
 boolean connected(){return connected;}
 void start(){if(!stopped)return;stopped=false;connect();}
 void stop(){stopped=true;generation++;clear();}
 private void clear(){connected=false;main.removeCallbacksAndMessages(null);if(socket!=null){socket.cancel();socket=null;}}
 private void fail(int version){if(stopped||version!=generation)return;generation++;clear();main.postDelayed(reconnect,Math.min(30000,1000L<<Math.min(attempt++,5)));}
 private void connect(){
  if(stopped||!api.valid())return;clear();final int version=++generation;
  auth.execute(()->{try{JSONObject ticket=api.rpc("chat_live_ticket",new JSONObject());main.post(()->{if(stopped||version!=generation)return;open(ticket,version);});}catch(Exception e){main.post(()->fail(version));}});
 }
 private void open(JSONObject ticket,int version){
  if(!ticket.optString("topic").startsWith("oms-live:")){fail(version);return;}String topic="realtime:"+ticket.optString("topic");ref=1;
  main.postDelayed(()->{if(!connected)fail(version);},12000);
  socket=sockets.newWebSocket(new Request.Builder().url(NativeStaffChatApi.REALTIME).build(),new WebSocketListener(){
   @Override public void onOpen(WebSocket ws,Response response){try{ws.send(new JSONObject().put("topic",topic).put("event","phx_join").put("ref","1").put("join_ref","1").put("payload",new JSONObject().put("config",new JSONObject().put("private",true).put("broadcast",new JSONObject().put("ack",false).put("self",false)).put("presence",new JSONObject().put("enabled",false)))).toString());}catch(Exception e){ws.cancel();}}
   @Override public void onMessage(WebSocket ws,String text){main.post(()->{if(stopped||version!=generation)return;try{JSONObject m=new JSONObject(text);String event=m.optString("event");
    if("phx_reply".equals(event)){if(!"ok".equals(m.optJSONObject("payload").optString("status"))){fail(version);return;}if(topic.equals(m.optString("topic"))&&!connected){connected=true;attempt=0;changed.run();beat(ws,version);long ttl=Instant.parse(ticket.getString("expires_at")).toEpochMilli()-System.currentTimeMillis()-30000;main.postDelayed(reconnect,Math.max(1000,ttl));}else if("phoenix".equals(m.optString("topic")))lastAck=System.currentTimeMillis();}
    else if("broadcast".equals(event)&&"changed".equals(m.optJSONObject("payload").optString("event")))changed.run();
    else if("phx_error".equals(event)||"phx_close".equals(event))fail(version);
   }catch(Exception e){fail(version);}});}
   @Override public void onFailure(WebSocket ws,Throwable e,Response response){main.post(()->fail(version));}
   @Override public void onClosed(WebSocket ws,int code,String reason){main.post(()->fail(version));}
  });
 }
 private long lastAck;
 private void beat(WebSocket ws,int version){lastAck=System.currentTimeMillis();main.postDelayed(new Runnable(){public void run(){if(stopped||version!=generation)return;if(System.currentTimeMillis()-lastAck>45000){fail(version);return;}try{ws.send(new JSONObject().put("topic","phoenix").put("event","heartbeat").put("payload",new JSONObject()).put("ref",String.valueOf(++ref)).toString());}catch(Exception e){fail(version);return;}main.postDelayed(this,20000);}},20000);}
 void destroy(){stop();auth.shutdown();}
}
