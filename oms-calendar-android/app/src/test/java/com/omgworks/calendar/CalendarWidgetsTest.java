package com.omgworks.calendar;

import android.content.Context;
import android.content.Intent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.*;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.Shadows;
import java.time.ZonedDateTime;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28)
public class CalendarWidgetsTest {
    private Context context;
    private final ZonedDateTime now = ZonedDateTime.parse("2026-11-24T16:50:00+09:00[Asia/Seoul]");
    private String id(int n) { return String.format("00000000-0000-4000-8000-%012d", n); }
    @Before public void setup() {
        context = RuntimeEnvironment.getApplication();
        CalendarRefresh.preferences(context).edit().clear().putString("token", "test-session").putString("role", "owner").commit();
        WidgetTasks.epoch(context);
    }
    private JSONObject task(int n, String title, String due, String priority) throws Exception {
        return new JSONObject().put("id", id(n)).put("title", title).put("due_at", due).put("priority", priority);
    }
    private void tasks(JSONObject... rows) {
        JSONArray data = new JSONArray(); for (JSONObject row : rows) data.put(row);
        CalendarRefresh.preferences(context).edit().putString("widget_tasks", data.toString()).commit();
    }
    private RemoteViews remote(boolean tasks, int height) { return CalendarWidgets.buildViews(context, 42, tasks, height, now); }
    private View apply(RemoteViews views) { return views.apply(context, new FrameLayout(context)); }
    private ViewGroup group(View root, int id) { return (ViewGroup) root.findViewById(id); }
    private String text(View root, int id) { return ((TextView) root.findViewById(id)).getText().toString(); }
    private TaskWidgetService.Factory factory() { TaskWidgetService.Factory f=new TaskWidgetService.Factory(context);f.onCreate();return f; }
    private void measure(View root, int width, int height) {
        float d=context.getResources().getDisplayMetrics().density;
        root.measure(View.MeasureSpec.makeMeasureSpec(Math.round(width*d),View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(Math.round(height*d),View.MeasureSpec.EXACTLY));
        root.layout(0,0,root.getMeasuredWidth(),root.getMeasuredHeight());
    }
    @Test public void allRowsAvailableBeyondVisibleHeightAndDuplicateTitlesKept() throws Exception {
        JSONArray rows=new JSONArray();for(int i=1;i<=50;i++)rows.put(task(i,"동일 제목","", "normal"));rows.put(rows.get(0));
        CalendarRefresh.preferences(context).edit().putString("widget_tasks",rows.toString()).commit();
        TaskWidgetService.Factory f=factory();assertEquals(50,f.getCount());assertNotEquals(f.getItemId(0),f.getItemId(1));
        assertEquals("동일 제목",text(apply(f.getViewAt(49)),R.id.widget_task_title));
        View root=apply(remote(true,96));assertTrue(root.findViewById(R.id.widget_task_list) instanceof ListView);
        assertEquals("50",text(root,R.id.widget_count));assertEquals(0,group(root,R.id.widget_entries).getChildCount());
        for(int i=0;i<20;i++)remote(true,180).reapply(context,root);
        assertEquals(0,group(root,R.id.widget_entries).getChildCount());assertEquals(50,factory().getCount());
    }
    @Test public void importantAndUrgentShownIndependentlyOfDates() throws Exception {
        for(String priority:new String[]{"important","urgent","normal"})for(String due:new String[]{"","2026-11-20T00:00:00Z","2026-11-24T23:00:00Z"}){
            View row=apply(CalendarWidgets.taskRow(context,task(1,"업무",due,priority),now,WidgetTasks.epoch(context)));
            assertEquals(priority.equals("normal")?View.GONE:View.VISIBLE,row.findViewById(R.id.widget_priority).getVisibility());
            if(!priority.equals("normal"))assertEquals("★",text(row,R.id.widget_priority));
            assertTrue(row.findViewById(R.id.widget_complete).getContentDescription().toString().contains("완료"));
            measure(row,320,44);float d=context.getResources().getDisplayMetrics().density;
            assertEquals(Math.round(16.5f*d),row.findViewById(R.id.widget_checkbox).getWidth());
            assertTrue(row.findViewById(R.id.widget_complete).getWidth()>=40*d);
        }
    }
    @Test public void overdueThenImportantThenNearestDeadline() throws Exception {
        tasks(task(1,"나중","2026-11-30T14:59:59Z","normal"),task(2,"중요","2026-11-29T14:59:59Z","important"),task(3,"지연","2026-11-22T14:59:59Z","normal"),task(4,"가까움","2026-11-25T14:59:59Z","normal"));
        String[] expected={"지연","중요","가까움","나중"};int i=0;
        for(JSONObject item:CalendarWidgets.sortedTasks(CalendarRefresh.preferences(context),now))assertEquals(expected[i++],item.optString("title"));
    }
    @Test public void completionHidesImmediatelyPersistsAndCallsPrivateApi() throws Exception {
        tasks(task(1,"업무","","normal"));String epoch=WidgetTasks.epoch(context);
        assertTrue(WidgetTasks.enqueue(context,id(1),epoch));assertFalse(WidgetTasks.enqueue(context,id(1),epoch));assertEquals(0,factory().getCount());
        assertTrue(WidgetTasks.pending(CalendarRefresh.preferences(context)).contains(id(1)));
        WidgetTasks.process(context,(name,body)->{assertEquals("calendar_private_items_action",name);assertEquals(id(1),body.getJSONObject("p_item").getString("id"));return new JSONObject().put("ok",true);});
        assertTrue(WidgetTasks.pending(CalendarRefresh.preferences(context)).isEmpty());assertNull(WidgetTasks.find(CalendarRefresh.preferences(context),id(1)));assertEquals(0,factory().getCount());
    }
    @Test public void failureRestoresTaskAndStaffUsesStaffApi() throws Exception {
        CalendarRefresh.preferences(context).edit().putString("role","staff").commit();tasks(task(1,"업무","","normal"));
        WidgetTasks.enqueue(context,id(1),WidgetTasks.epoch(context));
        WidgetTasks.process(context,(name,body)->{assertEquals("complete_mission",name);assertEquals(id(1),body.getString("p_mission_id"));return new JSONObject().put("ok",false);});
        assertEquals(1,factory().getCount());assertTrue(WidgetTasks.pending(CalendarRefresh.preferences(context)).isEmpty());
    }
    @Test public void staleSessionUnknownIdsAndRequiredPhotosCannotComplete() throws Exception {
        tasks(task(1,"사진 필수","","normal").put("photo_required",true));String epoch=WidgetTasks.epoch(context);
        assertFalse(WidgetTasks.enqueue(context,id(1),epoch));assertFalse(WidgetTasks.enqueue(context,id(2),epoch));assertFalse(WidgetTasks.enqueue(context,id(1),"old"));
        CalendarRefresh.clear(context);assertFalse(WidgetTasks.current(context,epoch));assertEquals(0,factory().getCount());
    }
    @Test public void accountSwitchDuringNetworkCannotRemoveNewAccountTask() throws Exception {
        tasks(task(1,"업무","","normal"));WidgetTasks.enqueue(context,id(1),WidgetTasks.epoch(context));
        WidgetTasks.process(context,(name,body)->{CalendarRefresh.preferences(context).edit().putString(WidgetTasks.EPOCH,"new-account").putString("token","different").commit();return new JSONObject().put("ok",true);});
        assertNotNull(WidgetTasks.find(CalendarRefresh.preferences(context),id(1)));
    }
    @Test public void itemClickOpensExactTaskWithoutCalendar() throws Exception {
        tasks(task(1,"업무","","normal"));
        Intent tap=new Intent(context,CalendarWidgets.Tasks.class).setAction(CalendarWidgets.TASK_ACTION).putExtra("task_id",id(1)).putExtra("session_epoch",WidgetTasks.epoch(context)).putExtra("operation","open");
        new CalendarWidgets.Tasks().onReceive(context,tap);Intent activity=Shadows.shadowOf((android.app.Application)context).getNextStartedActivity();
        assertNotNull(activity);assertTrue(activity.getBooleanExtra("tasks",false));assertEquals(id(1),activity.getStringExtra("task_id"));assertTrue(CalendarActivity.taskUrl(activity).contains("task="+id(1)));assertTrue(CalendarActivity.taskUrl(activity).contains("app=todo"));
        assertFalse(CalendarActivity.taskUrl(new Intent().putExtra("task_id","javascript:alert(1)")).contains("task="));
    }
    @Test public void resizingReplacesCalendarAndPreservesSelectedMonth() {
        View root=apply(remote(false,300));
        for(int cycle=0;cycle<8;cycle++)for(int h:new int[]{300,200,120,200,300}){
            remote(false,h).reapply(context,root);assertEquals(h==300?6:h==200?2:0,group(root,R.id.widget_grid).getChildCount());
        }
        CalendarRefresh.preferences(context).edit().putString("widget_month_42","2026-12-01").commit();remote(false,300).reapply(context,root);assertEquals("2026년 12월",text(root,R.id.widget_title));assertEquals("12월 1일 · 일정 없음",text(root,R.id.widget_entry_title));
        CalendarRefresh.preferences(context).edit().remove("token").commit();remote(false,300).reapply(context,root);assertEquals(0,group(root,R.id.widget_grid).getChildCount());assertEquals("앱에서 로그인하면 표시됩니다.",text(root,R.id.widget_entry_title));
    }
    @Test public void monthFillsHeightAndSixWeekMonthFits() {
        for(int height:new int[]{240,300,400}){
            RemoteViews views=CalendarWidgets.buildViews(context,42,false,height,ZonedDateTime.parse("2026-05-10T12:00:00+09:00[Asia/Seoul]"));View root=apply(views);measure(root,320,height);
            assertEquals(root.getHeight()-root.getPaddingBottom(),root.findViewById(R.id.widget_entries).getBottom());
        }
    }
    private void bindPreviewRows(View root){
        TaskWidgetService.Factory f=factory();ListView list=root.findViewById(R.id.widget_task_list);
        list.setAdapter(new BaseAdapter(){public int getCount(){return f.getCount();}public Object getItem(int p){return p;}public long getItemId(int p){return f.getItemId(p);}public View getView(int p,View convert,ViewGroup parent){return f.getViewAt(p).apply(context,parent);}});
    }
    @Test @Config(sdk=35,qualifiers="xhdpi") @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    public void renderActualWidgetPreviews() throws Exception {
        tasks(task(1,"연남동 사업자 확인","2026-11-30T14:59:59Z","important"),task(2,"비자 마무리","","normal"),task(3,"프렌즈아고다 계좌","","normal"),task(4,"Vrbo 계좌등록","","important"),task(5,"연남 사업자 업종 추가","","normal"),task(6,"요금제 홈페이지설정","","normal"),task(7,"스크롤 아래 항목","","normal"));
        java.io.File folder=new java.io.File("build/widget-previews");assertTrue(folder.mkdirs()||folder.isDirectory());
        for(boolean todo:new boolean[]{false,true})for(int width:new int[]{250,320}){
            int height=todo?300:280;View root=apply(remote(todo,height));if(todo)bindPreviewRows(root);measure(root,width,height);
            android.graphics.Bitmap image=android.graphics.Bitmap.createBitmap(root.getWidth(),root.getHeight(),android.graphics.Bitmap.Config.ARGB_8888);root.draw(new android.graphics.Canvas(image));
            try(java.io.FileOutputStream out=new java.io.FileOutputStream(new java.io.File(folder,(todo?"todo-":"calendar-")+width+".png"))){image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,out);}
        }
    }
}
