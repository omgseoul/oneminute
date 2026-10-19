package com.oneminute.guesthousemanager;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Base64;
import android.view.*;
import android.widget.*;
import android.webkit.WebView;
import android.view.inputmethod.InputMethodManager;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;
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
    private String roomProfileMetrics;
    static void runHandoff(Instrumentation i){Bundle result=new Bundle();try{new NativeStaffChatProbe(i).verifyHandoff();result.putString("oms_handoff","ok");i.finish(-1,result);}catch(Throwable error){error.printStackTrace();result.putString("oms_handoff","failed: "+error);i.finish(0,result);}}
    private String stage="start",layout="";
    NativeStaffChatProbe(Instrumentation i){instrumentation=i;NativeMessageBadge.loader=context->0;}
    static void run(Instrumentation i){NativeStaffChatProbe probe=new NativeStaffChatProbe(i);Bundle result=new Bundle();try{probe.verify();result.putString("oms_chat","ok");i.finish(-1,result);}catch(Throwable error){probe.capture("native-chat-probe.png");error.printStackTrace();result.putString("oms_chat","failed: "+error);i.finish(0,result);}}
    static void runLayout(Instrumentation i){NativeStaffChatProbe probe=new NativeStaffChatProbe(i);Bundle result=new Bundle();try{probe.verifyLayoutOnly();result.putString("oms_layout","ok");i.finish(-1,result);}catch(Throwable error){probe.capture("native-chat-layout.png");error.printStackTrace();result.putString("oms_layout","failed: "+error);i.finish(0,result);}}
    private <T>T ui(Callable<T> action)throws Exception{AtomicReference<T> value=new AtomicReference<>();AtomicReference<Throwable> error=new AtomicReference<>();instrumentation.runOnMainSync(()->{try{value.set(action.call());}catch(Throwable e){error.set(e);}});if(error.get() instanceof Error)throw (Error)error.get();if(error.get()!=null)throw (Exception)error.get();return value.get();}
    private static Object field(Object object,String name)throws Exception{Field field=object.getClass().getDeclaredField(name);field.setAccessible(true);return field.get(object);}
    private void waitFor(Callable<Boolean> condition)throws Exception{long until=System.currentTimeMillis()+25000;while(System.currentTimeMillis()<until){if(ui(condition))return;Thread.sleep(100);}throw new AssertionError("Native UI condition timed out: "+stage+" "+layout);}
    private static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
    private void verify()throws Exception{
        Context c=instrumentation.getTargetContext();c.getSharedPreferences("omg_receipts",0).edit().putString("token",TOKEN).putString("expires","2099-01-01T00:00:00Z").commit();
        verifyUploads(c);
        NativeStaffChatActivity.apiFactory=context->{fake=new FakeApi(context);return fake;};
        try{
            Intent launch=new Intent(c,NativeStaffChatActivity.class).putExtra("peer",PEER).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);activity=(NativeStaffChatActivity)instrumentation.startActivitySync(launch);
            waitFor(()->((EditText)field(activity,"input")).isEnabled());
            stage="visible incoming receipt reaches server";waitFor(()->fake.readIds.contains(VIDEO));
            verifySendStates();verifySafeLayout();verifyProfile();verifyApprovalProfile();verifyConversationRows();verifyStickerPicker();
            ui(()->{EditText input=(EditText)field(activity,"input");input.setText("확인 ");input.setSelection(input.length());((ImageButton)field(activity,"emoji")).performClick();GridView grid=(GridView)field(activity,"emojis");grid.performItemClick(grid.getChildAt(0),0,0);check(input.getText().toString().equals("확인 [시바:환영해요]"),"sticker cursor insertion");check(input.getText().getSpans(0,input.length(),android.text.style.ImageSpan.class).length==1,"selected sticker draws in input");grid.performItemClick(null,28,28);check(input.getText().toString().endsWith("😀"),"original Unicode emojis follow four Shiba rows");((TextView)field(activity,"send")).performClick();return null;});
            waitFor(()->((TextView)field(activity,"status")).getText().toString().contains("재시도"));
            ui(()->{((TextView)field(activity,"send")).performClick();return null;});waitFor(()->((EditText)field(activity,"input")).length()==0&&!((Boolean)field(activity,"sending")));
            check(fake.sendCalls==2&&fake.saved.size()==1,"ambiguous send retry must use one client id");
            check(!fake.readIds.contains("12345678-1234-4234-8234-000000000000"),"unseen older messages must remain unread");
            ui(()->{Method open=activity.getClass().getDeclaredMethod("openMedia",String.class);open.setAccessible(true);open.invoke(activity,VIDEO);return null;});
            waitFor(()->{Object viewer=field(activity,"viewer");ExoPlayer player=(ExoPlayer)field(viewer,"player");return player!=null&&player.getPlaybackState()==Player.STATE_READY&&player.getVideoSize().width>0&&player.getCurrentPosition()>100;});
            ui(()->{Object viewer=field(activity,"viewer");((NativeStaffMediaViewer)viewer).pause();ExoPlayer player=(ExoPlayer)field(viewer,"player");check(!player.getPlayWhenReady(),"background pause");Method move=viewer.getClass().getDeclaredMethod("move",int.class);move.setAccessible(true);move.invoke(viewer,-1);check(field(viewer,"player")==null,"switching to a photo releases the video player");return null;});
            waitFor(()->{FrameLayout stage=(FrameLayout)field(field(activity,"viewer"),"stage");return stage.getChildAt(0) instanceof StaffChatZoomImage&&((ImageView)stage.getChildAt(0)).getDrawable()!=null;});
            ui(()->{((NativeStaffMediaViewer)field(activity,"viewer")).dismiss();((EditText)field(activity,"input")).setText("이모지를 선택해보세요");if(((GridView)field(activity,"emojis")).getVisibility()!=View.VISIBLE)((ImageButton)field(activity,"emoji")).performClick();return null;});
            Thread.sleep(400);Bitmap screenshot=instrumentation.getUiAutomation().takeScreenshot();try(FileOutputStream out=new FileOutputStream(new File(c.getFilesDir(),"native-chat-probe.png"))){screenshot.compress(Bitmap.CompressFormat.PNG,100,out);}screenshot.recycle();
            instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK);waitFor(()->((GridView)field(activity,"emojis")).getVisibility()==View.GONE);
            check(!activity.isFinishing(),"first back closes the emoji picker");
            stage="back to hub";instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK);waitFor(()->activity.isFinishing());
        }finally{NativeStaffChatActivity.apiFactory=NativeStaffChatApi::new;c.getSharedPreferences("omg_receipts",0).edit().clear().commit();NativeStaffChatApi.clearLocal(c);}
    }
    private void verifyLayoutOnly()throws Exception{
        Context c=instrumentation.getTargetContext();c.getSharedPreferences("omg_receipts",0).edit().putString("token",TOKEN).putString("expires","2099-01-01T00:00:00Z").commit();
        NativeStaffChatActivity.apiFactory=context->{fake=new FakeApi(context);return fake;};
        try{
            activity=(NativeStaffChatActivity)instrumentation.startActivitySync(new Intent(c,NativeStaffChatActivity.class).putExtra("peer",PEER).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            waitFor(()->((EditText)field(activity,"input")).isEnabled());stage="visible incoming receipt reaches server";waitFor(()->fake.readIds.contains(VIDEO));
            verifySendStates();verifySafeLayout();verifyProfile();verifyApprovalProfile();verifyConversationRows();verifyStickerPicker();
            Bitmap screenshot=instrumentation.getUiAutomation().takeScreenshot();try(FileOutputStream out=new FileOutputStream(new File(c.getFilesDir(),"native-chat-layout.png"))){screenshot.compress(Bitmap.CompressFormat.PNG,100,out);}screenshot.recycle();
            stage="back to hub";instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK);waitFor(()->activity.isFinishing());
        }finally{NativeStaffChatActivity.apiFactory=NativeStaffChatApi::new;c.getSharedPreferences("omg_receipts",0).edit().clear().commit();NativeStaffChatApi.clearLocal(c);}
    }
    private boolean safeLayout(boolean keyboard)throws Exception{
        View root=(View)field(activity,"root"),input=(View)field(activity,"input"),send=(View)field(activity,"send"),title=(View)field(activity,"title");
        WindowInsetsCompat insets=ViewCompat.getRootWindowInsets(root);if(insets==null||root.getHeight()==0)return false;
        layout="ime="+insets.isVisible(WindowInsetsCompat.Type.ime())+" destroyed="+activity.isDestroyed()+" rows="+((ListView)field(activity,"list")).getCount()+" padding="+root.getPaddingTop()+","+root.getPaddingBottom();
        if(keyboard!=insets.isVisible(WindowInsetsCompat.Type.ime()))return false;
        androidx.core.graphics.Insets safe=insets.getInsets(WindowInsetsCompat.Type.systemBars()|WindowInsetsCompat.Type.displayCutout()|WindowInsetsCompat.Type.ime());
        View decor=activity.getWindow().getDecorView();int[] d=new int[2],t=new int[2],s=new int[2];decor.getLocationOnScreen(d);title.getLocationOnScreen(t);send.getLocationOnScreen(s);
        layout+=" safe="+safe+" titleY="+t[1]+" sendBottom="+(s[1]+send.getHeight())+" windowBottom="+(d[1]+decor.getHeight());
        return safe.top>0&&safe.bottom>0&&t[1]>=d[1]+safe.top&&s[1]+send.getHeight()<=d[1]+decor.getHeight()-safe.bottom+1&&input.getHeight()>0&&input.getGlobalVisibleRect(new Rect())&&(!keyboard||((ListView)field(activity,"list")).getHeight()>=Math.round(40*activity.getResources().getDisplayMetrics().density));
    }
    private void verifyConversationRows()throws Exception{
        String outgoing="12345678-1234-4234-8234-000000000048";
        stage="incoming identity and unread outgoing";waitFor(()->{
            View root=(View)field(activity,"root");View avatar=root.findViewWithTag("message-avatar-"+VIDEO);return avatar!=null&&root.findViewWithTag("message-name-"+VIDEO)!=null&&root.findViewWithTag("message-unread-"+outgoing)!=null;
        });
        ui(()->{View root=(View)field(activity,"root");verifySideMeta(root,outgoing,true);verifySideMeta(root,VIDEO,false);return null;});
        ui(()->{View root=(View)field(activity,"root");check(root.findViewWithTag("message-avatar-"+outgoing)==null&&root.findViewWithTag("message-name-"+outgoing)==null,"own messages omit identity");root.findViewWithTag("message-avatar-"+VIDEO).performClick();return null;});
        stage="message avatar opens shared profile";waitFor(()->{Dialog dialog=(Dialog)field(activity,"peerProfileDialog");return dialog!=null&&dialog.isShowing()&&dialog.getWindow().getDecorView().hasWindowFocus();});instrumentation.waitForIdleSync();
        instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK);stage="message profile closes";waitFor(()->!((Dialog)field(activity,"peerProfileDialog")).isShowing());
        capture("native-chat-messages.png");
        ui(()->{fake.sentRead=true;Method load=activity.getClass().getDeclaredMethod("load",boolean.class,Runnable.class);load.setAccessible(true);load.invoke(activity,false,null);return null;});
        stage="real receipt removes outgoing 1";waitFor(()->((View)field(activity,"root")).findViewWithTag("message-unread-"+outgoing)==null);
        ui(()->{NativeStaffChatState state=(NativeStaffChatState)field(activity,"state");check(!state.messages.get(46).isNull("read_at"),"receipt-only projection updates earlier sticker");return null;});
    }
    private void verifySideMeta(View root,String id,boolean mine){
        View bubble=root.findViewWithTag("message-bubble-"+id),meta=root.findViewWithTag("message-meta-"+id),time=root.findViewWithTag("message-time-"+id);
        check(bubble!=null&&meta!=null&&time!=null,"Bubble and side metadata exist");
        int[] b=new int[2],m=new int[2],t=new int[2];bubble.getLocationOnScreen(b);meta.getLocationOnScreen(m);time.getLocationOnScreen(t);
        check(mine?m[0]+meta.getWidth()<=b[0]:m[0]>=b[0]+bubble.getWidth(),"Metadata stays beside the bubble");
        check(Math.abs(m[1]+meta.getHeight()-b[1]-bubble.getHeight())<=2,"Metadata aligns to bubble bottom");
        check(t[1]+time.getHeight()<=b[1]+bubble.getHeight()+2,"Time does not add a row below the bubble");
    }
    private void verifyStickerPicker()throws Exception{
        ui(()->{((ImageButton)field(activity,"emoji")).performClick();return null;});
        stage="four Shiba rows at picker top";waitFor(()->{GridView grid=(GridView)field(activity,"emojis");return grid.getVisibility()==View.VISIBLE&&grid.getNumColumns()==7&&grid.getLastVisiblePosition()>=27;});
        ui(()->{GridView grid=(GridView)field(activity,"emojis");check(grid.getAdapter().getCount()==28+54,"28 Shiba stickers plus unchanged original emojis");for(int i=0;i<28;i++){View cell=grid.getAdapter().getView(i,null,grid);check(cell instanceof ImageView&&((ImageView)cell).getDrawable()!=null,"bundled transparent Shiba atlas "+i);}return null;});
        capture("native-chat-stickers.png");instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK);stage="picker closes without leaving room";waitFor(()->((GridView)field(activity,"emojis")).getVisibility()==View.GONE);check(!activity.isFinishing(),"picker back keeps room");
    }
    private boolean latestMessageVisible()throws Exception{
        ListView list=(ListView)field(activity,"list");View composer=(View)field(activity,"composer");
        View last=list.getChildCount()>0?list.getChildAt(list.getChildCount()-1):null;
        if(last==null)return false;
        int[] row=new int[2],bar=new int[2];last.getLocationOnScreen(row);composer.getLocationOnScreen(bar);
        layout+=" last="+list.getLastVisiblePosition()+"/"+(list.getCount()-1)+" rowBottom="+(row[1]+last.getHeight())+" composerTop="+bar[1];
        return list.getLastVisiblePosition()==list.getCount()-1&&last.getBottom()<=list.getHeight()-list.getPaddingBottom()+1&&row[1]+last.getHeight()<=bar[1];
    }
    private void verifySafeLayout()throws Exception{
        stage="initial system bars";waitFor(()->safeLayout(false));
        // Rebuild after the first window dispatch: this reproduced the room opened
        // from the old native list, where all system-bar padding was lost.
        ui(()->{Method open=activity.getClass().getDeclaredMethod("openRoom",String.class);open.setAccessible(true);open.invoke(activity,PEER);return null;});
        stage="reopened room and rows";waitFor(()->safeLayout(false)&&((EditText)field(activity,"input")).isEnabled()&&((ListView)field(activity,"list")).getCount()>1&&latestMessageVisible());
        instrumentation.waitForIdleSync();Thread.sleep(150);instrumentation.waitForIdleSync();
        // Begin in older history, so a composer focus must deliberately reveal the
        // newest message instead of merely preserving the pre-keyboard offset.
        scrollOlderHistory();
        stage="older history before typing";waitFor(()->((ListView)field(activity,"list")).getLastVisiblePosition()<((ListView)field(activity,"list")).getCount()-1);
        int[] center=ui(()->{View input=(View)field(activity,"input");int[] p=new int[2];input.getLocationOnScreen(p);return new int[]{p[0]+input.getWidth()/3,p[1]+input.getHeight()/2};});
        long now=SystemClock.uptimeMillis();MotionEvent down=MotionEvent.obtain(now,now,MotionEvent.ACTION_DOWN,center[0],center[1],0),up=MotionEvent.obtain(now,now+80,MotionEvent.ACTION_UP,center[0],center[1],0);instrumentation.sendPointerSync(down);instrumentation.sendPointerSync(up);down.recycle();up.recycle();
        ui(()->{EditText input=(EditText)field(activity,"input");input.requestFocus();((InputMethodManager)activity.getSystemService(Context.INPUT_METHOD_SERVICE)).showSoftInput(input,InputMethodManager.SHOW_IMPLICIT);return null;});
        View sameInput=(View)field(activity,"input");
        stage="keyboard and latest message shown";waitFor(()->safeLayout(true)&&latestMessageVisible());instrumentation.sendStringSync("visible input");
        check(ui(()->field(activity,"input")==sameInput&&!activity.isDestroyed()),"keyboard opening preserves the input view and activity");
        ui(()->{((EditText)field(activity,"input")).setText("one\ntwo\nthree\nfour");return null;});
        stage="multiline composer keeps latest message visible";waitFor(()->safeLayout(true)&&latestMessageVisible());
        // Once typing has started, scrolling back through history must still work.
        scrollOlderHistory();
        stage="history while keyboard open";waitFor(()->((ListView)field(activity,"list")).getLastVisiblePosition()<((ListView)field(activity,"list")).getCount()-1);
        int[] historyAnchor=ui(()->{ListView list=(ListView)field(activity,"list");return new int[]{list.getFirstVisiblePosition(),list.getChildAt(0).getTop()};});
        ui(()->{((EditText)field(activity,"input")).setText("visible input");return null;});
        instrumentation.waitForIdleSync();
        check(ui(()->((ListView)field(activity,"list")).getLastVisiblePosition()<((ListView)field(activity,"list")).getCount()-1),"composer resize preserves intentional history scrolling");
        stage="history anchor preserved after composer resize";waitFor(()->{ListView list=(ListView)field(activity,"list");return list.getFirstVisiblePosition()==historyAnchor[0]&&Math.abs(list.getChildAt(0).getTop()-historyAnchor[1])<=1;});
        ui(()->{Method latest=activity.getClass().getDeclaredMethod("scrollToLatest",ListView.class);latest.setAccessible(true);latest.invoke(activity,(ListView)field(activity,"list"));return null;});
        stage="latest message before capture";waitFor(()->safeLayout(true)&&latestMessageVisible());
        Bitmap keyboard=instrumentation.getUiAutomation().takeScreenshot();try(FileOutputStream out=new FileOutputStream(new File(instrumentation.getTargetContext().getFilesDir(),"native-chat-keyboard.png"))){keyboard.compress(Bitmap.CompressFormat.PNG,100,out);}keyboard.recycle();
        ui(()->{EditText input=(EditText)field(activity,"input");check(input.getText().toString().contains("visible input"),"visible composer accepts actual keyboard input");input.setText("");((InputMethodManager)activity.getSystemService(Context.INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(input.getWindowToken(),0);input.clearFocus();return null;});
        stage="keyboard hidden keeps latest message visible";waitFor(()->safeLayout(false)&&latestMessageVisible());
    }
    private void scrollOlderHistory()throws Exception{
        for(int attempt=0;attempt<10;attempt++){
            if(ui(()->{ListView list=(ListView)field(activity,"list");return list.getLastVisiblePosition()<list.getCount()-1;})){
                // Frame well before the last rows: a taller viewport can naturally
                // expose the end without scrolling if the fixture is too close to it.
                ui(()->{ListView list=(ListView)field(activity,"list");list.smoothScrollBy(0,0);list.setSelection(5);return null;});
                waitFor(()->{ListView list=(ListView)field(activity,"list");return list.getLastVisiblePosition()<list.getCount()-8;});return;
            }
            int[] gesture=ui(()->{View list=(View)field(activity,"list");int[] point=new int[2];list.getLocationOnScreen(point);return new int[]{point[0]+list.getWidth()/2,point[1]+list.getHeight()/5,point[1]+list.getHeight()*4/5};});
            long start=SystemClock.uptimeMillis();
            for(int step=0;step<=8;step++){int action=step==0?MotionEvent.ACTION_DOWN:step==8?MotionEvent.ACTION_UP:MotionEvent.ACTION_MOVE;MotionEvent event=MotionEvent.obtain(start,start+step*35,action,gesture[0],gesture[1]+(gesture[2]-gesture[1])*step/8f,0);instrumentation.sendPointerSync(event);event.recycle();Thread.sleep(35);}
            instrumentation.waitForIdleSync();Thread.sleep(150);
        }
        throw new AssertionError("An actual downward history swipe did not reveal older messages: "+stage);
    }
    private void capture(String name){try{Bitmap screenshot=instrumentation.getUiAutomation().takeScreenshot();try(FileOutputStream out=new FileOutputStream(new File(instrumentation.getTargetContext().getFilesDir(),name))){screenshot.compress(Bitmap.CompressFormat.PNG,100,out);}screenshot.recycle();}catch(Exception ignored){}}
    private void verifyProfile()throws Exception{
        stage="worker profile loaded";waitFor(()->field(activity,"profile")!=null);
        View sameInput=(View)field(activity,"input");
        ui(()->{((EditText)sameInput).setText("프로필을 닫아도 유지할 초안");((TextView)field(activity,"title")).performClick();return null;});
        stage="shared worker profile card";waitFor(()->{
            Dialog dialog=(Dialog)field(activity,"peerProfileDialog");if(dialog==null||!dialog.isShowing())return false;
            View decor=dialog.getWindow().getDecorView();FrameLayout avatar=decor.findViewWithTag("staff-profile-avatar");
            return avatar!=null&&((ImageView)avatar.getChildAt(1)).getDrawable()!=null;
        });
        ui(()->{
            Dialog dialog=(Dialog)field(activity,"peerProfileDialog");View decor=dialog.getWindow().getDecorView();
            check(((TextView)decor.findViewWithTag("staff-profile-name")).getText().toString().equals("김한울"),"profile hero displays worker name");
            for(String[] expected:new String[][]{{"display_name","김한울"},{"job_title","평일 오전"},{"property_name","One Minute"},{"contact_phone","-"}})check(((TextView)decor.findViewWithTag("staff-profile-"+expected[0])).getText().toString().equals(expected[1]),"profile field "+expected[0]);
            View close=decor.findViewWithTag("staff-profile-close");Rect visible=new Rect();check(close.getGlobalVisibleRect(visible)&&visible.height()==close.getHeight(),"top-right close is fully visible");
            return null;
        });
        instrumentation.waitForIdleSync();Thread.sleep(350);roomProfileMetrics=ui(()->profileMetrics((Dialog)field(activity,"peerProfileDialog")));capture("native-chat-profile.png");
        ui(()->{Dialog dialog=(Dialog)field(activity,"peerProfileDialog");dialog.getWindow().getDecorView().findViewWithTag("staff-profile-close").performClick();return null;});
        stage="profile close returns to room";waitFor(()->!((Dialog)field(activity,"peerProfileDialog")).isShowing());
        ui(()->{
            JSONObject profile=(JSONObject)field(activity,"profile");profile.put("job_title",JSONObject.NULL).put("contact_phone","  ").put("property_name","One Minute 서울역점 긴 지점 이름도 줄바꿈하여 전체 내용이 보여야 합니다");
            ((View)((ImageView)field(activity,"headerAvatar")).getParent()).performClick();return null;
        });
        stage="avatar opens same profile with long and empty fields";waitFor(()->{
            Dialog dialog=(Dialog)field(activity,"peerProfileDialog");if(!dialog.isShowing())return false;
            TextView property=dialog.getWindow().getDecorView().findViewWithTag("staff-profile-property_name");
            return property.getLayout()!=null&&property.getLineCount()>1;
        });
        ui(()->{
            Dialog dialog=(Dialog)field(activity,"peerProfileDialog");View decor=dialog.getWindow().getDecorView();
            check(((TextView)decor.findViewWithTag("staff-profile-job_title")).getText().toString().equals("-"),"missing job uses shared placeholder");
            check(((TextView)decor.findViewWithTag("staff-profile-contact_phone")).getText().toString().equals("-"),"blank contact uses shared placeholder");
            ((ScrollView)decor.findViewWithTag("staff-profile-scroll")).fullScroll(View.FOCUS_DOWN);return null;
        });
        instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK);
        stage="profile back preserves room and draft";waitFor(()->!((Dialog)field(activity,"peerProfileDialog")).isShowing());
        ui(()->{check(field(activity,"input")==sameInput&&((EditText)sameInput).getText().toString().equals("프로필을 닫아도 유지할 초안"),"profile close/back preserve input and unsent draft");((EditText)sameInput).setText("");return null;});
    }
    private String profileMetrics(Dialog dialog){
        View decor=dialog.getWindow().getDecorView();StringBuilder result=new StringBuilder();
        for(String tag:new String[]{"card","title","avatar","name","fields","close","display_name","job_title","property_name","contact_phone"}){
            View view=decor.findViewWithTag("staff-profile-"+tag);int[] point=new int[2];view.getLocationOnScreen(point);
            result.append(tag).append(':').append(point[0]).append(',').append(point[1]).append(',').append(view.getWidth()).append(',').append(view.getHeight());
            if(view instanceof TextView){TextView text=(TextView)view;result.append(',').append(text.getTextSize()).append(',').append(text.getLineHeight());}
            result.append(';');
        }
        return result.toString();
    }
    private Dialog approvalProfile(AttendanceActivity host)throws Exception{
        Field owner=AttendanceActivity.class.getDeclaredField("workerProfiles");owner.setAccessible(true);Object controller=owner.get(host);return controller==null?null:(Dialog)field(controller,"dialog");
    }
    private void awaitProfileDrawn(Dialog dialog)throws Exception{
        long until=SystemClock.uptimeMillis()+6000;
        while(SystemClock.uptimeMillis()<until){
            Rect heading=ui(()->{Rect bounds=new Rect();dialog.getWindow().getDecorView().findViewWithTag("staff-profile-title").getGlobalVisibleRect(bounds);return bounds;});
            Bitmap frame=instrumentation.getUiAutomation().takeScreenshot();int ink=0;
            if(frame!=null){for(int y=Math.max(0,heading.top);y<Math.min(frame.getHeight(),heading.bottom);y+=2)for(int x=Math.max(0,heading.left);x<Math.min(frame.getWidth(),heading.right);x+=2){int c=frame.getPixel(x,y);if(Color.red(c)<100&&Color.green(c)<130&&Color.blue(c)>Color.green(c)+10)ink++;}frame.recycle();}
            if(ink>12)return;Thread.sleep(100);
        }
        throw new AssertionError("Native worker profile title was measured but not drawn on screen");
    }
    private void verifyApprovalProfile()throws Exception{
        Context context=instrumentation.getTargetContext();AttendanceActivity host=null;
        NativeWorkerProfileController.apiFactory=FakeApi::new;
        try{
            host=(AttendanceActivity)instrumentation.startActivitySync(new Intent().setClassName(context,"com.oneminute.guesthousemanager.ChatHandoffProbeActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            final AttendanceActivity parent=host;Field webField=AttendanceActivity.class.getDeclaredField("webView");webField.setAccessible(true);WebView web=(WebView)webField.get(host);
            awaitJs(web,"window.fixtureReady===true && !!document.querySelector('.mp-identity')");
            String before=js(web,"JSON.stringify({nonce:fixtureNonce,href:location.href,state:history.state,length:history.length})");
            check("false".equals(js(web,"OMGNative.openWorkerProfile('employee:invalid')")),"malformed worker ID is rejected by native host");
            js(web,"document.querySelector('.mp-identity').click();true");
            stage="approval opens identical native profile";waitFor(()->{
                Dialog dialog=approvalProfile(parent);if(dialog==null||!dialog.isShowing())return false;
                View status=dialog.getWindow().getDecorView().findViewWithTag("staff-profile-status");
                layout="expected="+roomProfileMetrics+" actual="+profileMetrics(dialog);
                return status.getVisibility()==View.GONE&&roomProfileMetrics.equals(profileMetrics(dialog));
            });
            check("true".equals(js(web,"!document.getElementById('messageProfile')?.open")),"native profile does not create a second web modal");
            check(before.equals(js(web,"JSON.stringify({nonce:fixtureNonce,href:location.href,state:history.state,length:history.length})")),"opening native profile preserves approval document and history");
            instrumentation.waitForIdleSync();awaitProfileDrawn(ui(()->approvalProfile(parent)));capture("native-worker-profile-host.png");
            ui(()->{approvalProfile(parent).getWindow().getDecorView().findViewWithTag("staff-profile-close").performClick();return null;});
            stage="approval profile closes without dismissing approval";waitFor(()->!approvalProfile(parent).isShowing());
            check(before.equals(js(web,"JSON.stringify({nonce:fixtureNonce,href:location.href,state:history.state,length:history.length})")),"closing profile keeps approval layer and scroll document");
            NativeWorkerProfileController.apiFactory=a->{FakeApi api=new FakeApi(a);api.profileFailures=1;return api;};
            js(web,"document.querySelector('.mp-identity').click();true");
            stage="native profile error stays in shared card";waitFor(()->{
                Dialog dialog=approvalProfile(parent);return dialog!=null&&dialog.isShowing()&&dialog.getWindow().getDecorView().findViewWithTag("staff-profile-retry").getVisibility()==View.VISIBLE;
            });
            ui(()->{Dialog dialog=approvalProfile(parent);View decor=dialog.getWindow().getDecorView();check(((TextView)decor.findViewWithTag("staff-profile-display_name")).getText().toString().equals("-"),"failed lookup cannot show previous person's data");decor.findViewWithTag("staff-profile-retry").performClick();return null;});
            stage="native profile retry reuses card";waitFor(()->approvalProfile(parent).getWindow().getDecorView().findViewWithTag("staff-profile-status").getVisibility()==View.GONE);
            instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK);stage="native profile back preserves approval";waitFor(()->!approvalProfile(parent).isShowing());
            check(before.equals(js(web,"JSON.stringify({nonce:fixtureNonce,href:location.href,state:history.state,length:history.length})")),"native profile back does not pop approval history");
            ui(()->{String url="https://example.invalid/messages.html";web.loadDataWithBaseURL(url,"<html><body>untrusted fixture</body></html>","text/html","UTF-8",url);return null;});
            awaitJs(web,"location.host==='example.invalid'");
            check("false".equals(js(web,"OMGNative.openWorkerProfile('"+PEER+"')")),"native worker profile rejects an untrusted page");
        }finally{NativeWorkerProfileController.apiFactory=NativeStaffChatApi::new;if(host!=null){final AttendanceActivity parent=host;if(ui(()->approvalProfile(parent)!=null&&approvalProfile(parent).isShowing()))capture("native-worker-profile-host.png");ui(()->{parent.finish();return null;});}}
        stage="return from approval fixture";waitFor(()->activity.hasWindowFocus());
    }
    private void verifySendStates()throws Exception{
        File file=new File(instrumentation.getTargetContext().getCacheDir(),"composer-state.jpg");try(FileOutputStream out=new FileOutputStream(file)){out.write(1);}
        ui(()->{EditText input=(EditText)field(activity,"input");TextView send=(TextView)field(activity,"send");input.setText("");check(!send.isEnabled()&&send.getAlpha()<.5f,"empty send is dimmed and disabled");input.setText(" \n ");check(!send.isEnabled(),"whitespace is not sendable");input.setText("확인");check(send.isEnabled()&&send.getAlpha()==1f,"typing enables and brightens send immediately");input.setText("");Field pending=activity.getClass().getDeclaredField("pendingFile");pending.setAccessible(true);pending.set(activity,file);Method show=activity.getClass().getDeclaredMethod("showAttachment");show.setAccessible(true);show.invoke(activity);check(send.isEnabled(),"attachment-only message is sendable");pending.set(activity,null);show.invoke(activity);check(!send.isEnabled(),"removing the last attachment dims send");return null;});file.delete();
    }
    private String js(WebView view,String code)throws Exception{
        java.util.concurrent.CountDownLatch done=new java.util.concurrent.CountDownLatch(1);AtomicReference<String> result=new AtomicReference<>();
        instrumentation.runOnMainSync(()->view.evaluateJavascript(code,value->{result.set(value);done.countDown();}));
        if(!done.await(5,java.util.concurrent.TimeUnit.SECONDS))throw new AssertionError("WebView script timed out");return result.get();
    }
    private void awaitJs(WebView view,String code)throws Exception{long until=SystemClock.uptimeMillis()+20000;while(SystemClock.uptimeMillis()<until){if("true".equals(js(view,code)))return;Thread.sleep(100);}throw new AssertionError("WebView condition timed out: "+code);}
    private void verifyHandoff()throws Exception{
        Context c=instrumentation.getTargetContext();c.getSharedPreferences("omg_receipts",0).edit().putString("token",TOKEN).putString("expires","2099-01-01T00:00:00Z").commit();
        NativeStaffChatActivity.apiFactory=context->{fake=new FakeApi(context);return fake;};
        Instrumentation.ActivityMonitor monitor=new Instrumentation.ActivityMonitor(NativeStaffChatActivity.class.getName(),null,false);instrumentation.addMonitor(monitor);
        AttendanceActivity host=null;
        try{
            host=(AttendanceActivity)instrumentation.startActivitySync(new Intent().setClassName(c,"com.oneminute.guesthousemanager.ChatHandoffProbeActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            Field webField=AttendanceActivity.class.getDeclaredField("webView");webField.setAccessible(true);WebView web=(WebView)webField.get(host);
            awaitJs(web,"window.fixtureReady===true && !!document.querySelector('.staff-room')");String nonce=js(web,"window.fixtureNonce");
            String before=ui(()->web.getUrl())+" "+js(web,"JSON.stringify({href:location.href,origin:location.origin,bridge:typeof window.OMGNative?.openStaffChat})");
            js(web,"window.fixtureLinkCancelled=null;document.querySelector('.staff-room').addEventListener('click',event=>setTimeout(()=>window.fixtureLinkCancelled=event.defaultPrevented,0),{once:true});document.querySelector('.staff-room').click();true");activity=(NativeStaffChatActivity)monitor.waitForActivityWithTimeout(10000);check(activity!=null,"real WebView link opens one native conversation: "+before+" after="+ui(()->web.getUrl())+" cancelled="+js(web,"window.fixtureLinkCancelled"));
            waitFor(()->((EditText)field(activity,"input")).isEnabled());verifySendStates();
            final AttendanceActivity parent=host;
            ui(()->{Method open=AttendanceActivity.class.getDeclaredMethod("openNativeStaffChat",String.class,String.class);open.setAccessible(true);check((Boolean)open.invoke(parent,PEER,"[]"),"repeated host callback is consumed");return null;});
            View sameInput=(View)field(activity,"input");ui(()->{EditText input=(EditText)field(activity,"input");input.requestFocus();((InputMethodManager)activity.getSystemService(Context.INPUT_METHOD_SERVICE)).showSoftInput(input,InputMethodManager.SHOW_IMPLICIT);input.setText("입력 중 유지");return null;});
            stage="handoff keyboard";waitFor(()->safeLayout(true));Thread.sleep(7200);
            check(monitor.getHits()==1,"watchdog must not relaunch the native room after 1.5/6.5 seconds");
            ui(()->{check(!activity.isDestroyed()&&field(activity,"input")==sameInput,"typing must not recreate the activity or composer");EditText input=(EditText)field(activity,"input");check(input.getText().toString().equals("입력 중 유지"),"typing draft stays intact");((InputMethodManager)activity.getSystemService(Context.INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(input.getWindowToken(),0);input.clearFocus();return null;});
            stage="handoff keyboard hidden";waitFor(()->safeLayout(false));Thread.sleep(400);ui(()->{activity.getOnBackPressedDispatcher().onBackPressed();return null;});waitFor(()->activity.isFinishing());
            awaitJs(web,"!document.hidden");check(nonce.equals(js(web,"window.fixtureNonce")),"return preserves the original hub document");check("true".equals(js(web,"!document.getElementById('navigationFailure')")),"no false N5 dialog after returning to hub");
        }finally{if(host!=null){final AttendanceActivity parent=host;ui(()->{parent.finish();return null;});}instrumentation.removeMonitor(monitor);NativeStaffChatActivity.apiFactory=NativeStaffChatApi::new;c.getSharedPreferences("omg_receipts",0).edit().clear().commit();NativeStaffChatApi.clearLocal(c);}
    }
    private void verifyUploads(Context c)throws Exception{
        File dir=new File(c.getFilesDir(),"native-chat-upload-probe");dir.mkdirs();
        File image=new File(dir,"source.png");Bitmap png=Bitmap.createBitmap(48,32,Bitmap.Config.ARGB_8888);try(FileOutputStream out=new FileOutputStream(image)){png.compress(Bitmap.CompressFormat.PNG,100,out);}png.recycle();
        File video=new File(dir,"source.mp4");try(FileOutputStream out=new FileOutputStream(video)){out.write(Base64.decode(CLIP,Base64.DEFAULT));}
        for(File source:new File[]{image,video}){
            AtomicReference<File> prepared=new AtomicReference<>();AtomicReference<String> error=new AtomicReference<>(),mime=new AtomicReference<>();NativeChatUpload uploader=new NativeChatUpload(c);
            ui(()->{uploader.prepare(android.net.Uri.fromFile(source),dir,new NativeChatUpload.Callback(){public void status(String text){}public void done(File file,String type){prepared.set(file);mime.set(type);}public void failed(String message){error.set(message);}});return null;});
            waitFor(()->prepared.get()!=null||error.get()!=null);check(error.get()==null,"native upload: "+error.get());File result=prepared.get();check(result.length()>0&&result.length()<=20L*1024*1024,"upload output limit");
            if(source==image){check("image/jpeg".equals(mime.get()),"JPEG output");Bitmap decoded=BitmapFactory.decodeFile(result.getPath());check(decoded!=null&&Color.red(decoded.getPixel(0,0))>230,"transparent PNG becomes a white JPEG");decoded.recycle();}
            else{check("video/mp4".equals(mime.get()),"MP4 output");android.media.MediaMetadataRetriever reader=new android.media.MediaMetadataRetriever();try{reader.setDataSource(result.getPath());check(Integer.parseInt(reader.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT))<=1280,"video resized by real transformer");}finally{reader.release();}}
            ui(()->{uploader.close();return null;});result.delete();
        }
        image.delete();video.delete();dir.delete();
    }
    private static final class FakeApi extends NativeStaffChatApi {
        int sendCalls;
        int profileFailures;
        boolean sentRead;
        final Set<String> saved=new HashSet<>(),readIds=new HashSet<>();
        final String jpeg;
        FakeApi(Context c)throws Exception{super(c);Bitmap b=Bitmap.createBitmap(32,32,Bitmap.Config.RGB_565);b.eraseColor(0xff95c6ff);ByteArrayOutputStream out=new ByteArrayOutputStream();b.compress(Bitmap.CompressFormat.JPEG,90,out);b.recycle();jpeg=Base64.encodeToString(out.toByteArray(),Base64.NO_WRAP);}
        @Override JSONObject chat(String action,JSONObject data)throws Exception{
            if("send".equals(action)){sendCalls++;String id=data.getString("client_id");boolean duplicate=!saved.add(id);if(sendCalls==1)throw new IOException("전송 결과를 확인하지 못했습니다.");return new JSONObject().put("ok",true).put("message_id",id).put("duplicate",duplicate);}
            if("read".equals(action)){JSONArray ids=data.getJSONArray("ids");for(int i=0;i<ids.length();i++)readIds.add(ids.getString(i));return new JSONObject().put("ok",true);}
            if("attachment".equals(action)){boolean video=VIDEO.equals(data.optString("message_id"));return new JSONObject().put("ok",true).put("attachment",video?"data:video/mp4;base64,"+CLIP:"data:image/jpeg;base64,"+jpeg);}
            if("rooms".equals(action))return new JSONObject().put("ok",true).put("rooms",new JSONArray());
            JSONArray messages=new JSONArray();if(!data.has("before_time"))for(int i=0;i<50;i++){
                JSONObject m=new JSONObject().put("id",String.format(Locale.ROOT,"12345678-1234-4234-8234-%012d",i)).put("created_at",String.format(Locale.ROOT,"2026-10-18T01:%02d:00Z",i)).put("body",i==49?"동영상":i==48?"객실 사진":i==47?"[시바:ㅋㅋㅋ]":i==46?"[시바:청소 완료]":"확인했습니다 "+i).put("mine",i%2==0).put("read_at",sentRead&&i==48?"2026-10-19T00:00:00Z":JSONObject.NULL);
                if(i>=48)m.put("attachment_type",i==49?"video/mp4":"image/jpeg");messages.put(m);
            }
            JSONArray receipts=new JSONArray();if(sentRead)receipts.put(new JSONObject().put("id","12345678-1234-4234-8234-000000000046").put("read_at","2026-10-19T00:00:00Z"));
            return new JSONObject().put("ok",true).put("can_send",true).put("peer",new JSONObject().put("display_name","근무자 채팅")).put("messages",messages).put("receipts",receipts);
        }
        @Override JSONObject rpc(String name,JSONObject args)throws Exception{if("staff_chat_peer_profile".equals(name)&&profileFailures-->0)throw new IOException("연결을 확인하고 다시 시도해주세요.");return new JSONObject().put("ok",true).put("recipients",new JSONArray()).put("profile",new JSONObject().put("display_name","김한울").put("profile_image","data:image/jpeg;base64,"+jpeg).put("job_title","평일 오전").put("property_name","One Minute").put("contact_phone",""));}
        @Override void notifyMessage(String id){}
    }
}
