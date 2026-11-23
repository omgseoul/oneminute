package com.omgworks.calendar;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.TextView;
import android.widget.RemoteViews;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import java.time.ZonedDateTime;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28)
public class CalendarWidgetsTest {
    private Context context;
    private final ZonedDateTime now = ZonedDateTime.parse("2026-11-23T16:50:00+09:00[Asia/Seoul]");

    @Before public void setup() {
        context = RuntimeEnvironment.getApplication();
        CalendarRefresh.preferences(context).edit().clear().putString("token", "test-session").commit();
    }

    private JSONObject task(String id, String title, String due, String priority) throws Exception {
        return new JSONObject().put("id", id).put("title", title).put("due_at", due).put("priority", priority);
    }

    private void tasks(JSONObject... rows) {
        JSONArray data = new JSONArray();
        for (JSONObject row : rows) data.put(row);
        CalendarRefresh.preferences(context).edit().putString("widget_tasks", data.toString()).commit();
    }

    private RemoteViews remote(boolean tasks, int height) {
        return CalendarWidgets.buildViews(context, 42, tasks, height, now);
    }

    private View apply(RemoteViews views) { return views.apply(context, new FrameLayout(context)); }
    private ViewGroup group(View root, int id) { return (ViewGroup) root.findViewById(id); }
    private String text(View root, int id) { return ((TextView) root.findViewById(id)).getText().toString(); }

    @Test public void repeatedRefreshReplacesTasksInsteadOfAppending() throws Exception {
        tasks(task("1", "연남동 사업자 확인", "2026-11-30T14:59:59Z", "normal"));
        View root = apply(remote(true, 200));
        for (int i = 0; i < 30; i++) {
            remote(true, 200).reapply(context, root);
            assertEquals(1, group(root, R.id.widget_entries).getChildCount());
            assertEquals(0, group(root, R.id.widget_grid).getChildCount());
        }
    }

    @Test public void resizingRepeatedlyLeavesExactlyOneCalendar() {
        View root = apply(remote(false, 200));
        for (int cycle = 0; cycle < 10; cycle++) {
            for (int height : new int[]{300, 200, 120, 200, 300}) {
                remote(false, height).reapply(context, root);
                ViewGroup grid = group(root, R.id.widget_grid);
                assertEquals(height == 300 ? 6 : height == 200 ? 2 : 0, grid.getChildCount());
                for (int row = 0; row < grid.getChildCount(); row++)
                    assertEquals(7, ((ViewGroup) grid.getChildAt(row)).getChildCount());
                assertEquals(1, group(root, R.id.widget_entries).getChildCount());
            }
        }
    }

    @Test public void emptyAndLoggedOutStatesRemovePreviousContents() throws Exception {
        tasks(task("1", "완료 전 업무", "2026-11-30T14:59:59Z", "normal"));
        View root = apply(remote(true, 200));
        tasks();
        remote(true, 200).reapply(context, root);
        assertEquals(1, group(root, R.id.widget_entries).getChildCount());
        assertEquals("미완료 할 일이 없습니다.", text(root, R.id.widget_entry_title));
        remote(false, 300).reapply(context, root);
        CalendarRefresh.preferences(context).edit().remove("token").commit();
        remote(false, 300).reapply(context, root);
        assertEquals(0, group(root, R.id.widget_grid).getChildCount());
        assertEquals(1, group(root, R.id.widget_entries).getChildCount());
        assertEquals("앱에서 로그인하면 표시됩니다.", text(root, R.id.widget_entry_title));
        assertEquals(View.GONE, root.findViewById(R.id.widget_action).getVisibility());
    }

    @Test public void deduplicationUsesIdsAndPreservesSeparateTasksWithSameTitle() throws Exception {
        JSONObject first = task("1", "동일 제목", "2026-11-30T14:59:59Z", "normal");
        tasks(first, first, task("2", "동일 제목", "2026-11-30T14:59:59Z", "normal"));
        View root = apply(remote(true, 200));
        assertEquals(2, group(root, R.id.widget_entries).getChildCount());
    }

    @Test public void overdueThenImportantThenNearestDeadline() throws Exception {
        tasks(task("1", "나중", "2026-11-30T14:59:59Z", "normal"),
                task("2", "중요", "2026-11-29T14:59:59Z", "important"),
                task("3", "지연", "2026-11-22T14:59:59Z", "normal"),
                task("4", "가까움", "2026-11-24T14:59:59Z", "normal"));
        ViewGroup rows = group(apply(remote(true, 200)), R.id.widget_entries);
        String[] expected = {"지연", "중요", "가까움", "나중"};
        for (int i = 0; i < expected.length; i++) assertEquals(expected[i], text(rows.getChildAt(i), R.id.widget_entry_title));
    }

    @Test public void dailyTaskWindowAppliesOnlyToCalendar() throws Exception {
        JSONObject task = task("1", "일주일 업무", "2026-11-30T14:59:59Z", "normal");
        for (int day = 0; day <= 7; day++) assertTrue(CalendarWidgets.taskOccurs(task, now.toLocalDate().plusDays(day), now));
        assertFalse(CalendarWidgets.taskOccurs(task, now.toLocalDate().minusDays(1), now));
        assertFalse(CalendarWidgets.taskOccurs(task, now.toLocalDate().plusDays(8), now));
        JSONObject distant = task("2", "먼 마감", "2026-12-01T14:59:59Z", "normal");
        assertFalse(CalendarWidgets.taskOccurs(distant, now.toLocalDate(), now));
        JSONObject planned = new JSONObject().put("timing", "planned");
        assertFalse(CalendarWidgets.taskOccurs(planned, now.toLocalDate(), now));
        JSONObject late = task("3", "지연", "2026-11-22T14:59:59Z", "normal");
        assertTrue(CalendarWidgets.taskOccurs(late, now.toLocalDate(), now));
        assertFalse(CalendarWidgets.taskOccurs(late, now.toLocalDate().plusDays(1), now));
        tasks(task);
        View root = apply(remote(false, 300));
        assertEquals("일주일 업무", text(root, R.id.widget_entry_title));
        remote(true, 300).reapply(context, root);
        assertEquals(1, group(root, R.id.widget_entries).getChildCount());
        assertEquals(0, group(root, R.id.widget_grid).getChildCount());
    }

    @Test public void sixWeekMonthFitsMinimumMonthHeight() {
        ZonedDateTime august = ZonedDateTime.parse("2026-08-23T16:50:00+09:00[Asia/Seoul]");
        View root = apply(CalendarWidgets.buildViews(context, 42, false, 240, august));
        assertEquals(7, group(root, R.id.widget_grid).getChildCount());
        float density = context.getResources().getDisplayMetrics().density;
        root.measure(View.MeasureSpec.makeMeasureSpec((int) (320 * density), View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec((int) (240 * density), View.MeasureSpec.EXACTLY));
        root.layout(0, 0, root.getMeasuredWidth(), root.getMeasuredHeight());
        View entries = root.findViewById(R.id.widget_entries);
        assertTrue("Agenda must fit below the six-week grid", entries.getBottom() <= root.getHeight() - root.getPaddingBottom());
    }
}
