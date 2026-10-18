package com.oneminute.guesthousemanager;

import android.content.Context;
import android.graphics.*;
import android.media.MediaMetadataRetriever;
import android.os.*;
import android.util.Base64;
import android.util.LruCache;
import android.widget.ImageView;
import org.json.JSONObject;
import java.io.*;
import java.util.concurrent.*;

/** Private per-session cache. Large attachments are fetched only when a recycled row is visible. */
final class NativeStaffChatMedia {
    interface Result {void done(File file);void failed(String message);}
    final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final NativeStaffChatApi api;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final LruCache<String,Bitmap> thumbs=new LruCache<String,Bitmap>(8*1024*1024){@Override protected int sizeOf(String k,Bitmap b){return b.getAllocationByteCount();}};
    private volatile boolean closed;
    private volatile File pinned;
    NativeStaffChatMedia(NativeStaffChatApi api){this.api=api;}
    void pin(File file){pinned=file;}
    File file(String peer,String id)throws Exception {
        if(!api.valid())throw new IOException("로그인이 만료되었습니다.");
        if(!id.matches("[0-9a-fA-F-]{36}"))throw new IOException("첨부 파일을 확인해주세요.");
        File file=new File(api.cacheDirectory(),id+".media");
        if(file.exists()&&file.length()>0){file.setLastModified(System.currentTimeMillis());return file;}
        JSONObject result=api.chat("attachment",new JSONObject().put("peer",peer).put("message_id",id));
        String data=result.getString("attachment");int comma=data.indexOf(',');
        if(comma<0||!data.substring(0,comma).matches("data:(image/jpeg|video/webm|video/mp4);base64"))throw new IOException("지원하지 않는 첨부 파일입니다.");
        byte[] bytes=Base64.decode(data.substring(comma+1),Base64.DEFAULT);
        if(bytes.length>20*1024*1024||bytes.length<3)throw new IOException("첨부 파일 크기를 확인해주세요.");
        File temp=File.createTempFile("attachment-",".tmp",api.cacheDirectory());
        try{
            try(FileOutputStream out=new FileOutputStream(temp)){out.write(bytes);}
            if(!api.valid()||closed)throw new IOException("채팅을 다시 열어주세요.");
            if(!temp.renameTo(file))throw new IOException("첨부 파일을 저장하지 못했습니다.");
        }finally{temp.delete();}
        prune();return file;
    }
    void get(String peer,String id,Result result){worker.execute(()->{try{File file=file(peer,id);main.post(()->{if(!closed&&api.valid())result.done(file);});}catch(Exception e){main.post(()->{if(!closed)result.failed("첨부 파일을 불러오지 못했습니다. 다시 눌러주세요.");});}});}
    void bind(ImageView image,String peer,String id,boolean video){
        String key=id+(video?":video":":image");image.setTag(key);image.setImageDrawable(null);image.setBackgroundColor(0xffdce8f7);
        Bitmap hit=thumbs.get(key);if(hit!=null){image.setImageBitmap(hit);return;}
        image.post(()->{if(closed)return;worker.execute(()->{
            if(closed||!image.isAttachedToWindow()||!key.equals(image.getTag()))return;
            try{Bitmap bitmap=thumbnail(file(peer,id),video);if(bitmap==null)return;thumbs.put(key,bitmap);main.post(()->{if(!closed&&api.valid()&&key.equals(image.getTag()))image.setImageBitmap(bitmap);});}catch(Exception ignored){/* The row remains a tappable retry placeholder. */}
        });});
    }
    static Bitmap thumbnail(File file,boolean video)throws Exception {
        if(!video){BitmapFactory.Options bounds=new BitmapFactory.Options();bounds.inJustDecodeBounds=true;BitmapFactory.decodeFile(file.getPath(),bounds);BitmapFactory.Options options=new BitmapFactory.Options();options.inSampleSize=Math.max(1,Math.max(bounds.outWidth,bounds.outHeight)/480);return BitmapFactory.decodeFile(file.getPath(),options);}
        MediaMetadataRetriever reader=new MediaMetadataRetriever();try{
            reader.setDataSource(file.getPath());Bitmap frame=null;
            for(long time:new long[]{500000,1500000,0}){
                frame=Build.VERSION.SDK_INT>=27?reader.getScaledFrameAtTime(time,MediaMetadataRetriever.OPTION_CLOSEST_SYNC,480,480):reader.getFrameAtTime(time,MediaMetadataRetriever.OPTION_CLOSEST_SYNC);
                if(frame!=null)break;
            }
            if(frame!=null&&Math.max(frame.getWidth(),frame.getHeight())>480){float scale=480f/Math.max(frame.getWidth(),frame.getHeight());Bitmap resized=Bitmap.createScaledBitmap(frame,Math.max(1,Math.round(frame.getWidth()*scale)),Math.max(1,Math.round(frame.getHeight()*scale)),true);if(resized!=frame)frame.recycle();return resized;}
            return frame;
        }finally{reader.release();}
    }
    static Bitmap fullImage(File file){BitmapFactory.Options bounds=new BitmapFactory.Options();bounds.inJustDecodeBounds=true;BitmapFactory.decodeFile(file.getPath(),bounds);BitmapFactory.Options o=new BitmapFactory.Options();o.inSampleSize=Math.max(1,Math.max(bounds.outWidth,bounds.outHeight)/2048);return BitmapFactory.decodeFile(file.getPath(),o);}
    private void prune(){File[] list=api.cacheDirectory().listFiles();if(list==null)return;java.util.Arrays.sort(list,(a,b)->Long.compare(a.lastModified(),b.lastModified()));long bytes=0;for(File f:list)bytes+=f.length();for(File f:list){if(bytes<=128L*1024*1024)break;if(!f.equals(pinned)){long length=f.length();if(f.delete())bytes-=length;}}}
    void close(){closed=true;worker.shutdownNow();thumbs.evictAll();}
}
