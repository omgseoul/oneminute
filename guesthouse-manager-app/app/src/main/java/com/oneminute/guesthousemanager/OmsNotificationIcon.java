package com.oneminute.guesthousemanager;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import androidx.appcompat.content.res.AppCompatResources;

/** Full-color OMS logo for the notification drawer; status icons remain system-tinted. */
final class OmsNotificationIcon {
    private static Bitmap logo;
    private OmsNotificationIcon() {}

    static synchronized Bitmap largeIcon(Context context) {
        if (logo == null) {
            Drawable drawable = AppCompatResources.getDrawable(context, R.drawable.ic_oms_notification_color);
            Bitmap rendered = Bitmap.createBitmap(192, 192, Bitmap.Config.ARGB_8888);
            drawable.setBounds(0, 0, rendered.getWidth(), rendered.getHeight());
            drawable.draw(new Canvas(rendered));
            logo = rendered;
        }
        return logo;
    }
}
