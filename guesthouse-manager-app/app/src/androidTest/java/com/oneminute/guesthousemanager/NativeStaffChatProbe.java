package com.oneminute.guesthousemanager;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.os.Bundle;
import android.util.Base64;
import android.view.*;
import android.widget.*;
import androidx.media3.common.Player;
import androidx.media3.exoplayer.ExoPlayer;
import org.json.*;
import java.io.*;
import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.Callable;
import java.util.concurrent.atomic.AtomicReference;

/** Synthetic account and local fixtures only: never connects to the production backend. */
public final class NativeStaffChatProbe {
    private static final String TOKEN="12345678-1234-4234-8234-123456789abc",PEER="employee:12345678-1234-4234-8234-123456789def";
    private static final String VIDEO="12345678-1234-4234-8234-000000000049";
    private static final String CLIP="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";
    private final Instrumentation instrumentation;
    private NativeStaffChatActivity activity;
    private FakeApi fake;
    NativeStaffChatProbe(Instrumentation i){instrumentation=i;}
    static void run(Instrumentation i){Bundle result=new Bundle();try{new NativeStaffChatProbe(i).verify();result.putString("oms_chat","ok");i.finish(-1,result);}catch(Throwable error){error.printStackTrace();result.putString("oms_chat","failed: "+error);i.finish(0,result);}}
    private <T>T ui(Callable<T> action)throws Exception{AtomicReference<T> value=new AtomicReference<>();AtomicReference<Exception> error=new AtomicReference<>();instrumentation.runOnMainSync(()->{try{value.set(action.call());}catch(Exception e){error.set(e);}});if(error.get()!=null)throw error.get();return value.get();}
    private static Object field(Object object,String name)throws Exception{Field field=object.getClass().getDeclaredField(name);field.setAccessible(true);return field.get(object);}
    private void waitFor(Callable<Boolean> condition)throws Exception{long until=System.currentTimeMillis()+25000;while(System.currentTimeMillis()<until){if(ui(condition))return;Thread.sleep(100);}throw new AssertionError("Native UI condition timed out");}
    private static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
    private void verify()throws Exception{
        Context c=instrumentation.getTargetContext();c.getSharedPreferences("omg_receipts",0).edit().putString("token",TOKEN).putString("expires","2099-01-01T00:00:00Z").commit();
        NativeStaffChatActivity.apiFactory=context->{fake=new FakeApi(context);return fake;};
        try{
            Intent launch=new Intent(c,NativeStaffChatActivity.class).putExtra("peer",PEER).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);activity=(NativeStaffChatActivity)instrumentation.startActivitySync(launch);
            waitFor(()->((TextView)field(activity,"send")).isEnabled());
            ui(()->{EditText input=(EditText)field(activity,"input");input.setText("확인 ");input.setSelection(input.length());((ImageButton)field(activity,"emoji")).performClick();GridView grid=(GridView)field(activity,"emojis");grid.performItemClick(grid.getChildAt(0),0,0);check(input.getText().toString().equals("확인 😀"),"emoji cursor insertion");((TextView)field(activity,"send")).performClick();return null;});
            waitFor(()->((TextView)field(activity,"status")).getText().toString().contains("재시도"));
            ui(()->{((TextView)field(activity,"send")).performClick();return null;});waitFor(()->((EditText)field(activity,"input")).length()==0&&!((Boolean)field(activity,"sending")));
            check(fake.sendCalls==2&&fake.saved.size()==1,"ambiguous send retry must use one client id");
            check(!fake.readIds.contains("12345678-1234-4234-8234-000000000000"),"unseen older messages must remain unread");
            ui(()->{Method open=activity.getClass().getDeclaredMethod("openMedia",String.class);open.setAccessible(true);open.invoke(activity,VIDEO);return null;});
            waitFor(()->{Object viewer=field(activity,"viewer");ExoPlayer player=(ExoPlayer)field(viewer,"player");return player!=null&&player.getPlaybackState()==Player.STATE_READY&&player.getVideoSize().width>0&&player.getCurrentPosition()>100;});
            ui(()->{Object viewer=field(activity,"viewer");((NativeStaffMediaViewer)viewer).pause();ExoPlayer player=(ExoPlayer)field(viewer,"player");check(!player.getPlayWhenReady(),"background pause");Method move=viewer.getClass().getDeclaredMethod("move",int.class);move.setAccessible(true);move.invoke(viewer,-1);check(field(viewer,"player")==null,"switching to a photo releases the video player");return null;});
            waitFor(()->{FrameLayout stage=(FrameLayout)field(field(activity,"viewer"),"stage");return stage.getChildAt(0) instanceof StaffChatZoomImage&&((ImageView)stage.getChildAt(0)).getDrawable()!=null;});
            ui(()->{((NativeStaffMediaViewer)field(activity,"viewer")).dismiss();((EditText)field(activity,"input")).setText("이모지를 선택해보세요");((ImageButton)field(activity,"emoji")).performClick();return null;});
            Thread.sleep(400);Bitmap screenshot=instrumentation.getUiAutomation().takeScreenshot();try(FileOutputStream out=new FileOutputStream(new File(c.getFilesDir(),"native-chat-probe.png"))){screenshot.compress(Bitmap.CompressFormat.PNG,100,out);}screenshot.recycle();
            ui(()->{activity.finish();return null;});
        }finally{NativeStaffChatActivity.apiFactory=NativeStaffChatApi::new;c.getSharedPreferences("omg_receipts",0).edit().clear().commit();NativeStaffChatApi.clearLocal(c);}
    }
    private static final class FakeApi extends NativeStaffChatApi {
        int sendCalls;
        final Set<String> saved=new HashSet<>(),readIds=new HashSet<>();
        final String jpeg;
        FakeApi(Context c)throws Exception{super(c);Bitmap b=Bitmap.createBitmap(32,32,Bitmap.Config.RGB_565);b.eraseColor(0xff95c6ff);ByteArrayOutputStream out=new ByteArrayOutputStream();b.compress(Bitmap.CompressFormat.JPEG,90,out);b.recycle();jpeg=Base64.encodeToString(out.toByteArray(),Base64.NO_WRAP);}
        @Override JSONObject chat(String action,JSONObject data)throws Exception{
            if("send".equals(action)){sendCalls++;String id=data.getString("client_id");boolean duplicate=!saved.add(id);if(sendCalls==1)throw new IOException("전송 결과를 확인하지 못했습니다.");return new JSONObject().put("ok",true).put("message_id",id).put("duplicate",duplicate);}
            if("read".equals(action)){JSONArray ids=data.getJSONArray("ids");for(int i=0;i<ids.length();i++)readIds.add(ids.getString(i));return new JSONObject().put("ok",true);}
            if("attachment".equals(action)){boolean video=VIDEO.equals(data.optString("message_id"));return new JSONObject().put("ok",true).put("attachment",video?"data:video/mp4;base64,"+CLIP:"data:image/jpeg;base64,"+jpeg);}
            if("rooms".equals(action))return new JSONObject().put("ok",true).put("rooms",new JSONArray());
            JSONArray messages=new JSONArray();if(!data.has("before_time"))for(int i=0;i<50;i++){
                JSONObject m=new JSONObject().put("id",String.format(Locale.ROOT,"12345678-1234-4234-8234-%012d",i)).put("created_at",String.format(Locale.ROOT,"2026-10-18T01:%02d:00Z",i)).put("body",i==49?"동영상":i==48?"객실 사진":"확인했습니다 "+i).put("mine",i%2==0).put("read_at",JSONObject.NULL);
                if(i>=48)m.put("attachment_type",i==49?"video/mp4":"image/jpeg");messages.put(m);
            }
            return new JSONObject().put("ok",true).put("can_send",true).put("peer",new JSONObject().put("display_name","근무자 채팅")).put("messages",messages);
        }
        @Override JSONObject rpc(String name,JSONObject args)throws Exception{return new JSONObject().put("ok",true).put("recipients",new JSONArray()).put("profile",new JSONObject().put("display_name","근무자"));}
        @Override void notifyMessage(String id){}
    }
}
