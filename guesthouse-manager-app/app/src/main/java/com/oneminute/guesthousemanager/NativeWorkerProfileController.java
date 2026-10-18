package com.oneminute.guesthousemanager;

import android.app.Activity;
import android.os.Handler;
import android.os.Looper;
import org.json.JSONObject;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Opens the exact chat profile dialog above the existing WebView approval layer. */
final class NativeWorkerProfileController {
    interface ApiFactory {NativeStaffChatApi create(Activity activity)throws Exception;}
    static ApiFactory apiFactory=NativeStaffChatApi::new;
    private final Activity activity;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private NativeStaffChatApi api;
    private NativeStaffChatMedia media;
    private NativeStaffProfileDialog dialog;
    private String peer="";
    private int generation;
    private boolean destroyed;

    NativeWorkerProfileController(Activity activity){this.activity=activity;}
    boolean open(String requestedPeer){
        if(destroyed||activity.isFinishing()||!NativeStaffChatApi.validPeer(requestedPeer))return false;
        if(dialog!=null&&dialog.isShowing()&&requestedPeer.equals(peer)&&api!=null&&api.valid())return true;
        clear();
        try{api=apiFactory.create(activity);}catch(Exception error){return false;}
        peer=requestedPeer;media=new NativeStaffChatMedia(api);dialog=new NativeStaffProfileDialog(activity,new JSONObject(),media);
        final NativeStaffProfileDialog opened=dialog;
        dialog.setOnDismissListener(ignored->{if(dialog==opened)generation++;});dialog.loading();dialog.show();load();return true;
    }
    private void load(){
        if(dialog==null||!dialog.isShowing()||api==null)return;
        final int request=++generation;final NativeStaffProfileDialog target=dialog;final NativeStaffChatApi lookup=api;final String person=peer;
        target.loading();
        worker.execute(()->{
            try{
                JSONObject profile=lookup.rpc("staff_chat_peer_profile",new JSONObject().put("p_peer",person)).getJSONObject("profile");
                main.post(()->{if(current(request,target,lookup))target.bind(profile);});
            }catch(Exception error){main.post(()->{if(current(request,target,lookup))target.failed(error.getMessage()==null?"근무자 정보를 불러오지 못했습니다.":error.getMessage(),this::load);});}
        });
    }
    private boolean current(int request,NativeStaffProfileDialog target,NativeStaffChatApi lookup){
        if(destroyed||request!=generation||dialog!=target||!target.isShowing())return false;
        if(!lookup.valid()){clear();return false;}return true;
    }
    void clear(){generation++;if(dialog!=null)dialog.dismiss();dialog=null;if(media!=null)media.close();media=null;api=null;peer="";}
    void resume(){if(api!=null&&!api.valid())clear();}
    void close(){destroyed=true;clear();main.removeCallbacksAndMessages(null);worker.shutdownNow();}
}
