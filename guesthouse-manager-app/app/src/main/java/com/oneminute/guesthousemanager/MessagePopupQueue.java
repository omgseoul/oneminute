package com.oneminute.guesthousemanager;

import org.json.JSONArray;
import org.json.JSONObject;

/** FIFO + receipt dedupe, serialized together so activity/process recreation is safe. */
final class MessagePopupQueue {
    private final JSONArray pending, confirmed;
    MessagePopupQueue(String saved) {
        JSONObject data;
        try { data=new JSONObject(saved); } catch(Exception e){ data=new JSONObject(); }
        pending=data.optJSONArray("pending") == null ? new JSONArray() : data.optJSONArray("pending");
        confirmed=data.optJSONArray("confirmed") == null ? new JSONArray() : data.optJSONArray("confirmed");
    }
    boolean offer(JSONObject item) {
        String id=item.optString("alertId","");
        if(id.isEmpty())return false;
        for(int i=0;i<confirmed.length();i++)if(id.equals(confirmed.optString(i)))return false;
        for(int i=0;i<pending.length();i++)if(id.equals(pending.optJSONObject(i).optString("alertId")))return false;
        pending.put(item);return true;
    }
    JSONObject peek(){return pending.optJSONObject(0);}
    int size(){return pending.length();}
    boolean confirm(String id){
        JSONObject first=peek();if(first==null||!first.optString("alertId").equals(id))return false;
        pending.remove(0);confirmed.put(id);while(confirmed.length()>1000)confirmed.remove(0);return true;
    }
    String save(){try{return new JSONObject().put("pending",pending).put("confirmed",confirmed).toString();}catch(Exception e){throw new IllegalStateException(e);}}
}
