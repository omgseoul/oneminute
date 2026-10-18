package com.oneminute.guesthousemanager;

import android.content.Context;
import android.graphics.*;
import android.media.ExifInterface;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.os.*;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.effect.Presentation;
import androidx.media3.transformer.*;
import java.io.*;
import java.util.Collections;
import java.util.concurrent.*;

/** Bounds source reads to 100MB and output to 20MB; never uploads an uncompressed oversized video. */
@androidx.annotation.OptIn(markerClass=androidx.media3.common.util.UnstableApi.class)
final class NativeChatUpload {
    interface Callback{void status(String text);void done(File file,String mime);void failed(String message);}
    private final Context context;
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final Handler main=new Handler(Looper.getMainLooper());
    private Transformer transformer;
    private volatile boolean closed;
    private File source,output;
    NativeChatUpload(Context c){context=c.getApplicationContext();}
    void prepare(Uri uri,File directory,Callback cb){
        worker.execute(()->{
            try{
                directory.mkdirs();source=File.createTempFile("source-",".tmp",directory);
                try(InputStream in=context.getContentResolver().openInputStream(uri);OutputStream out=new FileOutputStream(source)){
                    if(in==null)throw new IOException("파일을 열지 못했습니다.");byte[] buffer=new byte[32768];long total=0;int n;
                    while((n=in.read(buffer))!=-1){total+=n;if(closed)throw new IOException("취소되었습니다.");if(total>100L*1024*1024)throw new IOException("원본 파일은 100MB 이하로 선택해주세요.");out.write(buffer,0,n);}
                }
                String mime=context.getContentResolver().getType(uri);
                if(mime!=null&&mime.startsWith("image/")){
                    File image=compressImage(directory);source.delete();source=null;main.post(()->{if(!closed)cb.done(image,"image/jpeg");else image.delete();});
                }else if(mime!=null&&mime.startsWith("video/")){
                    long duration;int width,height;
                    try(MediaMetadataRetriever info=new MediaMetadataRetriever()){
                        info.setDataSource(source.getPath());duration=Long.parseLong(info.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION));
                        width=Integer.parseInt(info.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH));height=Integer.parseInt(info.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT));
                        String rotation=info.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION);if("90".equals(rotation)||"270".equals(rotation)){int t=width;width=height;height=t;}
                    }
                    if(duration<=0||duration>180000)throw new IOException("동영상은 3분 이하로 선택해주세요.");
                    float scale=Math.min(1f,1280f/Math.max(width,height));int targetHeight=Math.max(2,((int)(height*scale)/2)*2);
                    int bitrate=(int)Math.max(150000,Math.min(2500000,(20L*1024*1024*8*.84)/(duration/1000d)-64000));
                    final int h=targetHeight;main.post(()->export(directory,h,bitrate,0,cb));
                }else throw new IOException("사진이나 동영상을 선택해주세요.");
            }catch(Exception e){if(source!=null)source.delete();main.post(()->{if(!closed)cb.failed(e.getMessage()==null?"파일을 준비하지 못했습니다.":e.getMessage());});}
        });
    }
    private File compressImage(File dir)throws Exception{
        BitmapFactory.Options bounds=new BitmapFactory.Options();bounds.inJustDecodeBounds=true;BitmapFactory.decodeFile(source.getPath(),bounds);
        if(bounds.outWidth<=0||bounds.outHeight<=0)throw new IOException("사진을 열지 못했습니다. JPG·PNG 사진으로 다시 선택해주세요.");
        BitmapFactory.Options options=new BitmapFactory.Options();options.inSampleSize=Math.max(1,Math.max(bounds.outWidth,bounds.outHeight)/1920);Bitmap bitmap=BitmapFactory.decodeFile(source.getPath(),options);
        if(bitmap==null)throw new IOException("사진을 읽지 못했습니다.");
        try{
            ExifInterface exif=new ExifInterface(source.getPath());Matrix matrix=new Matrix();int orientation=exif.getAttributeInt(ExifInterface.TAG_ORIENTATION,1);
            switch(orientation){case 2:matrix.setScale(-1,1);break;case 3:matrix.setRotate(180);break;case 4:matrix.setScale(1,-1);break;case 5:matrix.setRotate(90);matrix.postScale(-1,1);break;case 6:matrix.setRotate(90);break;case 7:matrix.setRotate(-90);matrix.postScale(-1,1);break;case 8:matrix.setRotate(-90);break;}
            Bitmap oriented=Bitmap.createBitmap(bitmap,0,0,bitmap.getWidth(),bitmap.getHeight(),matrix,true);if(oriented!=bitmap){bitmap.recycle();bitmap=oriented;}
            float scale=Math.min(1,1920f/Math.max(bitmap.getWidth(),bitmap.getHeight()));if(scale<1){Bitmap resized=Bitmap.createScaledBitmap(bitmap,Math.max(1,Math.round(bitmap.getWidth()*scale)),Math.max(1,Math.round(bitmap.getHeight()*scale)),true);if(resized!=bitmap)bitmap.recycle();bitmap=resized;}
            File file=File.createTempFile("photo-",".jpg",dir);
            for(int quality:new int[]{86,76,66,56,46}){try(FileOutputStream out=new FileOutputStream(file)){bitmap.compress(Bitmap.CompressFormat.JPEG,quality,out);}if(file.length()<=700*1024)break;}
            if(file.length()>1572864){file.delete();throw new IOException("사진을 1.5MB 이하로 압축하지 못했습니다.");}return file;
        }finally{bitmap.recycle();}
    }
    private void export(File directory,int height,int bitrate,int attempt,Callback cb){
        if(closed)return;
        try{
            output=File.createTempFile("video-",".mp4",directory);output.delete();final File target=output;
            EditedMediaItem item=new EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(source))).setEffects(new Effects(Collections.emptyList(),Collections.singletonList(Presentation.createForHeight(height)))).build();
            DefaultEncoderFactory encoder=new DefaultEncoderFactory.Builder(context).setRequestedVideoEncoderSettings(new VideoEncoderSettings.Builder().setBitrate(bitrate).build()).setRequestedAudioEncoderSettings(new AudioEncoderSettings.Builder().setBitrate(64000).build()).build();
            transformer=new Transformer.Builder(context).setVideoMimeType(MimeTypes.VIDEO_H264).setAudioMimeType(MimeTypes.AUDIO_AAC).setEncoderFactory(encoder).addListener(new Transformer.Listener(){
                @Override public void onCompleted(Composition composition,ExportResult result){
                    transformer=null;
                    if(closed){target.delete();return;}
                    if(target.length()>20L*1024*1024&&attempt==0){target.delete();export(directory,Math.min(height,480),Math.max(100000,bitrate/2),1,cb);return;}
                    if(source!=null)source.delete();source=null;
                    if(target.length()==0||target.length()>20L*1024*1024){target.delete();cb.failed("동영상을 20MB 이하로 압축하지 못했습니다. 길이를 줄여 다시 선택해주세요.");return;}
                    cb.done(target,"video/mp4");
                }
                @Override public void onError(Composition c,ExportResult r,ExportException error){transformer=null;target.delete();if(source!=null)source.delete();source=null;if(!closed)cb.failed("이 동영상을 압축하지 못했습니다. 다른 영상으로 다시 시도해주세요.");}
            }).build();
            transformer.start(item,target.getPath());
            main.post(new Runnable(){@Override public void run(){if(closed||transformer==null)return;ProgressHolder p=new ProgressHolder();int state=transformer.getProgress(p);cb.status(state==Transformer.PROGRESS_STATE_AVAILABLE?"동영상 압축 중… "+p.progress+"%":"동영상 압축 중…");main.postDelayed(this,500);}});
        }catch(Exception e){if(output!=null)output.delete();if(source!=null)source.delete();transformer=null;if(!closed)cb.failed("동영상 압축을 시작하지 못했습니다. 다시 선택해주세요.");}
    }
    void close(){closed=true;if(transformer!=null){transformer.cancel();transformer=null;}main.removeCallbacksAndMessages(null);worker.shutdownNow();if(source!=null)source.delete();if(output!=null&&output.length()==0)output.delete();}
}
