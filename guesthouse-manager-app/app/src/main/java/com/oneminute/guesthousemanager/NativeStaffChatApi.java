package com.oneminute.guesthousemanager;

import android.content.Context;
import android.content.SharedPreferences;
import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;

/** Uses the same server-validated work session and permission-checked RPCs as the web client. */
class NativeStaffChatApi {
    private static final String BASE="https://rfcozgyvupvachhhblzn.supabase.co/";
    private static final String KEY="sb_publishable_Gy0_TtIcJ6xKDEiGWEnXAg_f4_eyXPI";
    static final String REALTIME="wss://rfcozgyvupvachhhblzn.supabase.co/realtime/v1/websocket?apikey="+KEY+"&vsn=1.0.0";
    static class ChatException extends IOException {final boolean retryable;ChatException(String message,boolean retryable){super(message);this.retryable=retryable;}}
    private static final okhttp3.OkHttpClient HTTP=new okhttp3.OkHttpClient.Builder()
        .connectTimeout(15,java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(45,java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(20,java.util.concurrent.TimeUnit.SECONDS)
        .callTimeout(55,java.util.concurrent.TimeUnit.SECONDS)
        .retryOnConnectionFailure(false).followRedirects(false).build();
    static final class TransferControl {
        volatile boolean stopped;private okhttp3.Call call;
        synchronized void bind(okhttp3.Call next)throws IOException{if(stopped){next.cancel();throw new IOException("전송 중지");}call=next;}
        synchronized void stop(){stopped=true;if(call!=null)call.cancel();}
        void check()throws IOException{if(stopped)throw new IOException("전송 중지");}
    }
    private final ThreadLocal<TransferControl> transfer=new ThreadLocal<>();
    void beginTransfer(TransferControl control){transfer.set(control);}
    void endTransfer(){transfer.remove();}
    private final java.util.Set<okhttp3.Call> reads=java.util.Collections.synchronizedSet(new java.util.HashSet<>());
    void cancelReads(){synchronized(reads){for(okhttp3.Call call:reads)call.cancel();}}
    private final Context context;
    private final String token;
    final String scope;
    private final boolean workConfirmationOnly;
    NativeStaffChatApi(Context context) throws Exception {this(context,false);}
    NativeStaffChatApi(Context context,boolean workConfirmationOnly) throws Exception {
        this.workConfirmationOnly=workConfirmationOnly;
        this.context=context.getApplicationContext();
        token=prefs(context).getString("token","");
        if(!valid())throw new IOException("로그인이 만료되었습니다. OMS에서 다시 로그인해주세요.");
        scope=hash(token);
    }
    static SharedPreferences prefs(Context c){return c.getSharedPreferences("omg_receipts",Context.MODE_PRIVATE);}
    boolean valid(){
        try{return token!=null&&token.matches("[0-9a-fA-F-]{36}")&&token.equals(prefs(context).getString("token",""))&&(workConfirmationOnly||Instant.parse(prefs(context).getString("expires","")).toEpochMilli()>System.currentTimeMillis());}
        catch(Exception e){return false;}
    }
    static boolean validPeer(String peer){return peer!=null&&peer.matches("(?i)(owner|employee|group):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}");}
    JSONObject chat(String action,JSONObject data)throws Exception {
        if("messages".equals(action))return rpc("staff_chat_native_messages",new JSONObject().put("p_data",data));
        return rpc("staff_chat_rpc",new JSONObject().put("p_action",action).put("p_data",data));
    }
    JSONObject rpc(String name,JSONObject args)throws Exception {
        if(!name.matches("chat_live_ticket|staff_chat_upload_chunk|staff_chat_rpc|staff_chat_native_messages|staff_chat_peer_profile|list_property_messages|work_report_inbox|work_shift_confirmation"))throw new IOException("잘못된 요청입니다.");
        if(workConfirmationOnly&&!"work_shift_confirmation".equals(name))throw new IOException("잘못된 요청입니다.");
        args.put("p_access_token",token);
        JSONObject result=request(BASE+"rest/v1/rpc/"+name,args,true);
        if(workConfirmationOnly&&result.optJSONObject("session")!=null&&valid())SupabaseMessageReceipt.bind(context,token,result.getJSONObject("session").optString("expires_at"));
        return result;
    }
    JSONObject guestRooms(JSONObject cursor)throws Exception {
        return request(BASE+"functions/v1/guest-support",new JSONObject().put("action","rooms").put("data",cursor).put("access_token",token),true);
    }
    void notifyMessage(String id)throws Exception {
        request(BASE+"functions/v1/dispatch-notification",new JSONObject().put("access_token",token).put("message_id",id),false);
    }
    private JSONObject request(String url,JSONObject args,boolean apiKey)throws Exception {
        if(!valid())throw new IOException("로그인이 만료되었습니다. OMS에서 다시 로그인해주세요.");
        okhttp3.Request.Builder request=new okhttp3.Request.Builder().url(url).post(
            okhttp3.RequestBody.create(okhttp3.MediaType.parse("application/json; charset=utf-8"),args.toString()));
        if(apiKey)request.header("apikey",KEY);
        okhttp3.Call call=HTTP.newCall(request.build());TransferControl control=transfer.get();if(control!=null)control.bind(call);else reads.add(call);
        try(okhttp3.Response response=call.execute()){
            int code=response.code();okhttp3.ResponseBody responseBody=response.body();
            if(responseBody==null)throw new IOException("서버에 연결하지 못했습니다. 다시 시도해주세요.");
            StringBuilder text=new StringBuilder();try(Reader reader=responseBody.charStream()){
                char[] buffer=new char[8192];int n;while((n=reader.read(buffer))!=-1){if(text.length()+n>32*1024*1024)throw new IOException("첨부 파일이 너무 큽니다.");text.append(buffer,0,n);}
            }
            if(!valid())throw new IOException("로그인이 변경되었습니다. 채팅을 다시 열어주세요.");
            JSONObject result=new JSONObject(text.toString());
            if(code<200||code>=300||!result.optBoolean("ok"))throw new ChatException("57014".equals(result.optString("code"))?"서버 처리 시간이 초과되었습니다. 다시 시도해주세요.":result.optString("message","연결을 확인하고 다시 시도해주세요."),code>=500||code==429);
            return result;
        }catch(Exception error){
            if(error instanceof ChatException)throw error;String message=error.getMessage();if(message!=null&&message.matches("(?s).*[가-힣].*"))throw error;
            throw new IOException("연결을 확인하고 다시 시도해주세요.");
        }finally{reads.remove(call);}
    }
    File cacheDirectory(){File dir=new File(context.getCacheDir(),"staff-chat/"+scope);dir.mkdirs();return dir;}
    static String hash(String value){
        try{byte[] bytes=MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));StringBuilder out=new StringBuilder();for(byte b:bytes)out.append(String.format("%02x",b&255));return out.toString();}
        catch(Exception e){throw new IllegalStateException(e);}
    }
    static void clearLocal(Context c){NativeChatSnapshots.clear();NativeChatOutbox.clearInstances();delete(new File(c.getCacheDir(),"staff-chat"));delete(new File(c.getFilesDir(),"staff-chat-drafts"));c.getSharedPreferences("omg_chat_drafts",Context.MODE_PRIVATE).edit().clear().apply();}
    private static void delete(File f){File[] children=f.listFiles();if(children!=null)for(File child:children)delete(child);f.delete();}
}
