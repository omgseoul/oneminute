package com.oneminute.guesthousemanager;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import androidx.core.content.ContextCompat;

public class AcknowledgeReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String id = intent.getStringExtra("alertId");
        Intent stop = new Intent(context, EmergencyAlarmService.class)
                .setAction(EmergencyAlarmService.ACTION_STOP);
        ContextCompat.startForegroundService(context, stop);
        SupabaseMessageReceipt.acknowledge(context, id);
    }
}
