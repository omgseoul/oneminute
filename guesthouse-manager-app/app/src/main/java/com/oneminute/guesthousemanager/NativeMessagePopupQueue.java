package com.oneminute.guesthousemanager;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import org.json.JSONObject;

final class NativeMessagePopupQueue {
    private static final String[] FIELDS={"alertId","senderLabel","message","messageType","guestContext"};
    private static SharedPreferences prefs(Context c){return c.getSharedPreferences("omg_message_popup_queue",0);}
    static String scope(Context c){SharedPreferences p=c.getSharedPreferences("omg_push",0);String role=p.getString("role",""),member=p.getString("member_id","");return (role.equals("owner")||role.equals("staff"))&&!member.isEmpty()?role+":"+member:"";}
    private static MessagePopupQueue load(Context c){SharedPreferences p=prefs(c);String scope=scope(c);if(!scope.equals(p.getString("scope","")))p.edit().clear().putString("scope",scope).commit();return new MessagePopupQueue(p.getString("data","{}"));}
    private static void save(Context c,MessagePopupQueue q){prefs(c).edit().putString("data",q.save()).commit();}
    static synchronized void clear(Context c){prefs(c).edit().clear().commit();}
    static synchronized boolean offer(Context c,Intent intent){
        String scope=scope(c);if(scope.isEmpty()||"work_confirmation".equals(intent.getStringExtra("messageType")))return false;
        String incoming=intent.getStringExtra("popupScope");if(incoming!=null&&!scope.equals(incoming))return false;
        intent.putExtra("popupScope",scope);
        try{JSONObject item=new JSONObject();for(String key:FIELDS)item.put(key,intent.getStringExtra(key));
            item.put("notificationId",intent.getIntExtra("notificationId",NativeMessageBadge.ID));
            MessagePopupQueue q=load(c);boolean added=q.offer(item);save(c,q);return added;
        }catch(Exception e){return false;}
    }
    static synchronized Intent peek(Context c){if(scope(c).isEmpty())return null;JSONObject item=load(c).peek();if(item==null)return null;Intent i=new Intent(c,MessageAlertActivity.class).putExtra("popupScope",scope(c));for(String key:FIELDS)i.putExtra(key,item.optString(key,""));return i.putExtra("notificationId",item.optInt("notificationId",NativeMessageBadge.ID));}
    static synchronized int size(Context c){return scope(c).isEmpty()?0:load(c).size();}
    static synchronized void confirm(Context c,String id){MessagePopupQueue q=load(c);q.confirm(id);save(c,q);}
    static void launch(Context c){Intent first=peek(c);if(first!=null)c.startActivity(first.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_SINGLE_TOP));}
}
