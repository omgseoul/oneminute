package com.oneminute.guesthousemanager;
import android.util.LruCache;
import org.json.*;
import java.util.List;
/** Short-lived, memory-only and session-isolated recent room snapshots. */
final class NativeChatSnapshots {
 private static final LruCache<String,String> cache=new LruCache<String,String>(4*1024*1024){protected int sizeOf(String key,String value){return value.length()*2;}};
 static synchronized void put(String scope,String peer,List<JSONObject> messages,JSONObject profile){try{JSONArray rows=new JSONArray();for(int i=Math.max(0,messages.size()-50);i<messages.size();i++)rows.put(messages.get(i));String value=new JSONObject().put("at",System.currentTimeMillis()).put("messages",rows).put("profile",profile).toString();if(value.length()<1024*1024)cache.put(scope+":"+peer,value);}catch(Exception ignored){}}
 static synchronized JSONObject get(String scope,String peer){try{String value=cache.get(scope+":"+peer);if(value==null)return null;JSONObject snapshot=new JSONObject(value);if(System.currentTimeMillis()-snapshot.getLong("at")>120000){cache.remove(scope+":"+peer);return null;}return snapshot;}catch(Exception ignored){return null;}}
 static synchronized void clear(){cache.evictAll();}
}
