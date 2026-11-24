package com.omgworks.calendar;

import android.content.Context;
import android.content.Intent;
import android.widget.RemoteViews;
import android.widget.RemoteViewsService;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONObject;

/** A real collection: the launcher scrolls all tasks without opening the app. */
public final class TaskWidgetService extends RemoteViewsService {
    @Override public RemoteViewsFactory onGetViewFactory(Intent intent) { return new Factory(this); }
    static final class Factory implements RemoteViewsFactory {
        private final Context context;
        private List<JSONObject> items = new ArrayList<>();
        private ZonedDateTime now;
        private String epoch;
        Factory(Context context) { this.context = context; }
        @Override public void onCreate() { onDataSetChanged(); }
        @Override public void onDataSetChanged() {
            now = ZonedDateTime.now(ZoneId.of(CalendarRefresh.preferences(context).getString("zone", "Asia/Seoul")));
            epoch = WidgetTasks.epoch(context);
            items = CalendarRefresh.preferences(context).contains("token")
                    ? CalendarWidgets.sortedTasks(CalendarRefresh.preferences(context), now) : new ArrayList<>();
        }
        @Override public void onDestroy() { items.clear(); }
        @Override public int getCount() { return items.size(); }
        @Override public RemoteViews getViewAt(int position) {
            if (position < 0 || position >= items.size()) return null;
            return CalendarWidgets.taskRow(context, items.get(position), now, epoch);
        }
        @Override public RemoteViews getLoadingView() { return null; }
        @Override public int getViewTypeCount() { return 1; }
        @Override public long getItemId(int position) {
            // FNV-1a keeps IDs stable across removals, refreshes and duplicate titles.
            long hash = 0xcbf29ce484222325L;
            for (char c : items.get(position).optString("id").toCharArray()) { hash ^= c; hash *= 0x100000001b3L; }
            return hash;
        }
        @Override public boolean hasStableIds() { return true; }
    }
}
