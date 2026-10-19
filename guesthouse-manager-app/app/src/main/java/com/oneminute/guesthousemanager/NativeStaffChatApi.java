package com.oneminute.guesthousemanager;

import android.content.Context;
import android.content.SharedPreferences;
import org.json.JSONObject;
import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;

/** Uses the same short-lived work session and permission-checked RPCs as the web client. */
class NativeStaffChatApi {
    private static final String BASE="https://rfcozgyvupvachhhblzn.supabase.co/";
    private static final String KEY="sb_publishable_Gy0_TtIcJ6xKDEiGWEnXAg_f4_eyXPI";
    private final Context context;
    private final String token;
    final String scope;
    NativeStaffChatApi(Context context) throws Exception {
        this.context=context.getApplicationContext();
        token=prefs(context).getString("token","");
        if(!valid())throw new IOException("로그인이 만료되었습니다. OMS에서 다시 로그인해주세요.");
        scope=hash(token);
    }
    static SharedPreferences prefs(Context c){return c.getSharedPreferences("omg_receipts",Context.MODE_PRIVATE);}
    boolean valid(){
        try{return token!=null&&token.matches("[0-9a-fA-F-]{36}")&&token.equals(prefs(context).getString("token",""))&&Instant.parse(prefs(context).getString("expires","")).toEpochMilli()>System.currentTimeMillis();}
        catch(Exception e){return false;}
    }
    static boolean validPeer(String peer){return peer!=null&&peer.matches("(?i)(owner|employee):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}");}
    JSONObject chat(String action,JSONObject data)throws Exception {
        if("messages".equals(action))return rpc("staff_chat_native_messages",new JSONObject().put("p_data",data));
        return rpc("staff_chat_rpc",new JSONObject().put("p_action",action).put("p_data",data));
    }
    JSONObject rpc(String name,JSONObject args)throws Exception {
        if(!name.matches("staff_chat_rpc|staff_chat_native_messages|staff_chat_peer_profile|list_property_messages|work_report_inbox"))throw new IOException("잘못된 요청입니다.");
        args.put("p_access_token",token);
        return request(BASE+"rest/v1/rpc/"+name,args,true);
    }
    JSONObject guestRooms(JSONObject cursor)throws Exception {
        return request(BASE+"functions/v1/guest-support",new JSONObject().put("action","rooms").put("data",cursor).put("access_token",token),true);
    }
    void notifyMessage(String id)throws Exception {
        request(BASE+"functions/v1/dispatch-notification",new JSONObject().put("access_token",token).put("message_id",id),false);
    }
    private JSONObject request(String url,JSONObject args,boolean apiKey)throws Exception {
        if(!valid())throw new IOException("로그인이 만료되었습니다. OMS에서 다시 로그인해주세요.");
        HttpURLConnection connection=(HttpURLConnection)new URL(url).openConnection();
        try{
            connection.setInstanceFollowRedirects(false);connection.setRequestMethod("POST");connection.setDoOutput(true);
            connection.setConnectTimeout(15000);connection.setReadTimeout(45000);connection.setRequestProperty("Content-Type","application/json");
            if(apiKey)connection.setRequestProperty("apikey",KEY);
            byte[] body=args.toString().getBytes(StandardCharsets.UTF_8);connection.setFixedLengthStreamingMode(body.length);
            try(OutputStream out=connection.getOutputStream()){out.write(body);}
            int code=connection.getResponseCode();InputStream stream=code>=200&&code<300?connection.getInputStream():connection.getErrorStream();
            if(stream==null)throw new IOException("서버에 연결하지 못했습니다. 다시 시도해주세요.");
            StringBuilder text=new StringBuilder();try(Reader reader=new InputStreamReader(stream,StandardCharsets.UTF_8)){
                char[] buffer=new char[8192];int n;while((n=reader.read(buffer))!=-1){if(text.length()+n>32*1024*1024)throw new IOException("첨부 파일이 너무 큽니다.");text.append(buffer,0,n);}
            }
            if(!valid())throw new IOException("로그인이 변경되었습니다. 채팅을 다시 열어주세요.");
            JSONObject result=new JSONObject(text.toString());
            if(code<200||code>=300||!result.optBoolean("ok"))throw new IOException(result.optString("message","연결을 확인하고 다시 시도해주세요."));
            return result;
        }catch(Exception error){
            String message=error.getMessage();if(message!=null&&message.matches("(?s).*[가-힣].*"))throw error;
            throw new IOException("연결을 확인하고 다시 시도해주세요.");
        }finally{connection.disconnect();}
    }
    File cacheDirectory(){File dir=new File(context.getCacheDir(),"staff-chat/"+scope);dir.mkdirs();return dir;}
    static String hash(String value){
        try{byte[] bytes=MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));StringBuilder out=new StringBuilder();for(byte b:bytes)out.append(String.format("%02x",b&255));return out.toString();}
        catch(Exception e){throw new IllegalStateException(e);}
    }
    static void clearLocal(Context c){delete(new File(c.getCacheDir(),"staff-chat"));delete(new File(c.getFilesDir(),"staff-chat-drafts"));c.getSharedPreferences("omg_chat_drafts",Context.MODE_PRIVATE).edit().clear().apply();}
    private static void delete(File f){File[] children=f.listFiles();if(children!=null)for(File child:children)delete(child);f.delete();}
}
