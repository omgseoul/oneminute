package com.oneminute.guesthousemanager;

import android.app.Activity;
import android.net.Uri;
import android.nfc.NfcAdapter;
import android.webkit.WebView;
import org.json.JSONObject;

/** Foreground, read-only UID capture. The server resolves the branch and records time. */
final class NativeAttendanceNfc {
    private final Activity activity;
    private final WebView web;
    private final NfcAdapter adapter;
    private String requestId;
    private boolean resumed;

    NativeAttendanceNfc(Activity activity, WebView web) {
        this.activity=activity;this.web=web;adapter=NfcAdapter.getDefaultAdapter(activity);
    }
    private boolean trusted() {
        Uri uri=Uri.parse(web.getUrl()==null?"":web.getUrl());
        return "https".equals(uri.getScheme()) && ("omgworks24.com".equals(uri.getHost()) || "www.omgworks24.com".equals(uri.getHost()))
            && (uri.getPort()==-1 || uri.getPort()==443)
            && ("/owner-settings.html".equals(uri.getPath()) || "/app.html".equals(uri.getPath()) || "/report.html".equals(uri.getPath()));
    }
    void start(String id) {
        if (!trusted() || id==null || !id.matches("nfc-[0-9]+-[0-9]+")) return;
        clear();requestId=id;enable();
    }
    void stop(String id) { if(id!=null && id.equals(requestId)) clear(); }
    void resume(){resumed=true;enable();}
    void pause(){resumed=false;disable();}
    void clear(){disable();requestId=null;}
    private void disable(){if(adapter!=null)try{adapter.disableReaderMode(activity);}catch(RuntimeException ignored){}}
    private void enable(){
        if(!resumed || requestId==null)return;
        if(!trusted()){clear();return;}
        final String id=requestId;
        if(adapter==null){complete(id,null,"이 휴대폰은 NFC 태그 읽기를 지원하지 않습니다.");return;}
        if(!adapter.isEnabled()){complete(id,null,"휴대폰 설정에서 NFC를 켠 뒤 다시 시도해주세요.");return;}
        try{
            adapter.enableReaderMode(activity,tag->{
                final String uid=hex(tag.getId());
                activity.runOnUiThread(()->complete(id,uid,uid.isEmpty()?"고유번호가 없는 태그입니다. 다른 태그를 사용해주세요.":null));
            },NfcAdapter.FLAG_READER_NFC_A|NfcAdapter.FLAG_READER_NFC_B|NfcAdapter.FLAG_READER_NFC_F|NfcAdapter.FLAG_READER_NFC_V|NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,null);
        }catch(RuntimeException error){complete(id,null,"NFC를 시작하지 못했습니다. 휴대폰 설정을 확인해주세요.");}
    }
    private void complete(String id,String uid,String error){
        if(!id.equals(requestId)||!trusted()||!resumed)return;
        clear();
        try{JSONObject result=new JSONObject();result.put("request_id",id);if(error!=null)result.put("error",error);else result.put("uid",uid);
            web.evaluateJavascript("window.dispatchEvent(new CustomEvent('omg:nfc-result',{detail:"+result+"}))",null);
        }catch(Exception ignored){}
    }
    static String hex(byte[] bytes){StringBuilder result=new StringBuilder();if(bytes!=null)for(byte value:bytes){result.append("0123456789ABCDEF".charAt((value>>4)&15));result.append("0123456789ABCDEF".charAt(value&15));}return result.toString();}
}
