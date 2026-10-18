package com.oneminute.guesthousemanager;

import android.app.Dialog;
import android.content.Context;
import android.graphics.Color;
import android.net.Uri;
import android.view.*;
import android.widget.*;
import androidx.core.view.*;
import androidx.media3.common.MediaItem;
import androidx.media3.common.Player;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.ui.PlayerView;
import org.json.JSONObject;
import java.io.File;
import java.util.*;
import static com.oneminute.guesthousemanager.StaffChatUi.*;

@androidx.annotation.OptIn(markerClass=androidx.media3.common.util.UnstableApi.class)
final class NativeStaffMediaViewer {
    interface History {void older(Runnable ready);List<JSONObject> items();boolean complete();}
    private final Context context;
    private final NativeStaffChatMedia media;
    private final String peer;
    private final Dialog dialog;
    private final FrameLayout stage;
    private final LinearLayout thumbs,gallery;
    private final GridView grid;
    private final TextView title,count,older;
    private final HorizontalScrollView strip;
    private final History history;
    private List<JSONObject> items;
    private int index,version;
    private ExoPlayer player;
    private boolean closed,galleryOpen;
    NativeStaffMediaViewer(Context c,NativeStaffChatMedia media,String peer,List<JSONObject> source,String id,History history){
        context=c;this.media=media;this.peer=peer;this.history=history;items=new ArrayList<>(source);
        dialog=new Dialog(c,android.R.style.Theme_Black_NoTitleBar_Fullscreen);LinearLayout root=column(c);root.setBackgroundColor(Color.BLACK);
        ViewCompat.setOnApplyWindowInsetsListener(root,(v,insets)->{androidx.core.graphics.Insets bars=insets.getInsets(WindowInsetsCompat.Type.systemBars()|WindowInsetsCompat.Type.displayCutout());v.setPadding(bars.left,bars.top,bars.right,bars.bottom);return insets;});
        LinearLayout header=row(c);TextView close=button(c,"‹","미디어 닫기");title=text(c,"사진 · 동영상",15,Color.WHITE);TextView album=button(c,"▦","사진·동영상 모아보기");header.addView(close);header.addView(title,weighted());header.addView(album);root.addView(header);
        stage=new FrameLayout(c);root.addView(stage,new LinearLayout.LayoutParams(-1,0,1));
        gallery=column(c);grid=new GridView(c);grid.setNumColumns(3);grid.setHorizontalSpacing(dp(c,4));grid.setVerticalSpacing(dp(c,4));gallery.addView(grid,new LinearLayout.LayoutParams(-1,0,1));older=button(c,"이전 사진·동영상 더 보기","이전 미디어 더 보기");gallery.addView(older);gallery.setVisibility(View.GONE);root.addView(gallery,new LinearLayout.LayoutParams(-1,0,1));
        strip=new HorizontalScrollView(c);strip.setHorizontalScrollBarEnabled(false);thumbs=row(c);strip.addView(thumbs);root.addView(strip,new LinearLayout.LayoutParams(-1,dp(c,66)));
        LinearLayout navigation=row(c);TextView previous=button(c,"‹","이전 사진 또는 동영상"),next=button(c,"›","다음 사진 또는 동영상");count=text(c,"",12,Color.WHITE);count.setGravity(Gravity.CENTER);navigation.addView(previous);navigation.addView(count,weighted());navigation.addView(next);root.addView(navigation);
        previous.setOnClickListener(v->move(-1));next.setOnClickListener(v->move(1));close.setOnClickListener(v->{if(galleryOpen)showGallery(false);else dialog.dismiss();});album.setOnClickListener(v->showGallery(!galleryOpen));
        older.setOnClickListener(v->{older.setEnabled(false);older.setText("불러오는 중…");String current=items.get(index).optString("id");history.older(()->{if(closed)return;items=new ArrayList<>(history.items());index=find(current);refreshGallery();older.setEnabled(true);older.setText("이전 사진·동영상 더 보기");});});
        dialog.setContentView(root);dialog.setOnDismissListener(d->{closed=true;version++;release();media.pin(null);});dialog.setOnKeyListener((d,key,event)->{if(key==android.view.KeyEvent.KEYCODE_BACK&&event.getAction()==android.view.KeyEvent.ACTION_UP&&galleryOpen){showGallery(false);return true;}return false;});
        index=find(id);dialog.show();if(dialog.getWindow()!=null)dialog.getWindow().setLayout(-1,-1);render();
    }
    private int find(String id){for(int i=0;i<items.size();i++)if(id.equals(items.get(i).optString("id")))return i;return 0;}
    private void move(int delta){int next=index+delta;if(next<0||next>=items.size())return;index=next;showGallery(false);render();}
    private void release(){if(player!=null){player.release();player=null;}}
    private void render(){
        if(closed||items.isEmpty())return;release();final int request=++version;stage.removeAllViews();JSONObject item=items.get(index);String id=item.optString("id");boolean video=item.optString("attachment_type").startsWith("video/");
        title.setText(video?"동영상":"사진");count.setText((index+1)+" / "+items.size());TextView loading=text(context,"불러오는 중…",14,Color.WHITE);loading.setGravity(Gravity.CENTER);stage.addView(loading,new FrameLayout.LayoutParams(-1,-1));
        thumbs.removeAllViews();for(int i=Math.max(0,index-10);i<Math.min(items.size(),index+11);i++){final int n=i;JSONObject entry=items.get(i);FrameLayout tile=thumbnail(entry,dp(context,60));LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(dp(context,60),dp(context,60));params.setMargins(dp(context,3),dp(context,3),dp(context,3),dp(context,3));tile.setAlpha(i==index?1:.55f);tile.setOnClickListener(v->{index=n;render();});thumbs.addView(tile,params);if(i==index)tile.post(()->strip.smoothScrollTo(Math.max(0,tile.getLeft()-strip.getWidth()/2),0));}
        media.get(peer,id,new NativeStaffChatMedia.Result(){public void done(File file){
            if(closed||request!=version)return;media.pin(file);stage.removeAllViews();
            if(video){
                PlayerView view=new PlayerView(context);stage.addView(view,new FrameLayout.LayoutParams(-1,-1));player=new ExoPlayer.Builder(context).build();view.setPlayer(player);view.setKeepScreenOn(true);
                player.addListener(new Player.Listener(){@Override public void onPlayerError(androidx.media3.common.PlaybackException error){if(request==version){loading.setText("재생하지 못했습니다. 눌러서 다시 시도해주세요.");loading.setOnClickListener(v->render());if(loading.getParent()==null)stage.addView(loading,new FrameLayout.LayoutParams(-1,-1));}}});
                player.setMediaItem(MediaItem.fromUri(Uri.fromFile(file)));player.prepare();player.play();
            }else{
                StaffChatZoomImage image=new StaffChatZoomImage(context,NativeStaffMediaViewer.this::move);image.setContentDescription("대화 첨부 사진");stage.addView(image,new FrameLayout.LayoutParams(-1,-1));
                media.worker.execute(()->{android.graphics.Bitmap bitmap=NativeStaffChatMedia.fullImage(file);image.post(()->{if(!closed&&request==version)image.setImageBitmap(bitmap);});});
            }
        }public void failed(String message){if(!closed&&request==version){loading.setText(message);loading.setOnClickListener(v->render());}}});
    }
    private FrameLayout thumbnail(JSONObject item,int size){FrameLayout tile=new FrameLayout(context);ImageView image=new ImageView(context);image.setScaleType(ImageView.ScaleType.CENTER_CROP);tile.addView(image,new FrameLayout.LayoutParams(-1,-1));boolean video=item.optString("attachment_type").startsWith("video/");media.bind(image,peer,item.optString("id"),video);if(video){TextView play=text(context,"▶",18,Color.WHITE);play.setShadowLayer(3,0,1,Color.BLACK);play.setGravity(Gravity.CENTER);tile.addView(play,new FrameLayout.LayoutParams(-1,-1));}tile.setContentDescription(video?"동영상 열기":"사진 열기");return tile;}
    private void showGallery(boolean show){galleryOpen=show;if(player!=null)player.pause();stage.setVisibility(show?View.GONE:View.VISIBLE);strip.setVisibility(show?View.GONE:View.VISIBLE);gallery.setVisibility(show?View.VISIBLE:View.GONE);if(show)refreshGallery();}
    private void refreshGallery(){older.setVisibility(history.complete()?View.GONE:View.VISIBLE);grid.setAdapter(new BaseAdapter(){public int getCount(){return items.size();}public Object getItem(int p){return items.get(p);}public long getItemId(int p){return p;}public View getView(int p,View recycled,ViewGroup parent){int size=Math.max(dp(context,80),(context.getResources().getDisplayMetrics().widthPixels-dp(context,8))/3);FrameLayout tile=thumbnail(items.get(p),size);tile.setLayoutParams(new android.widget.AbsListView.LayoutParams(-1,size));tile.setOnClickListener(v->{index=p;showGallery(false);render();});return tile;}});}
    void pause(){if(player!=null)player.pause();}
    void dismiss(){dialog.dismiss();}
    boolean showing(){return dialog.isShowing();}
}
