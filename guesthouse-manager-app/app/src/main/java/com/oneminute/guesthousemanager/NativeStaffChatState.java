package com.oneminute.guesthousemanager;

import org.json.*;
import java.util.*;
import java.util.regex.*;

final class NativeStaffChatState {
    private final Map<String,JSONObject> entries=new HashMap<>();
    static final Pattern CONTRACT=Pattern.compile("\\[OMS-CONTRACT:([0-9a-f-]{36})\\]",Pattern.CASE_INSENSITIVE);
    List<JSONObject> messages=new ArrayList<>();
    void clear(){entries.clear();messages.clear();}
    boolean merge(JSONArray incoming){boolean changed=false;for(int i=0;i<incoming.length();i++){JSONObject item=incoming.optJSONObject(i);if(item==null||item.optString("id").isEmpty())continue;JSONObject previous=entries.put(item.optString("id"),item);if(previous==null||!previous.toString().equals(item.toString()))changed=true;}
        messages=new ArrayList<>(entries.values());messages.sort((a,b)->{int order=a.optString("created_at").compareTo(b.optString("created_at"));return order==0?a.optString("id").compareTo(b.optString("id")):order;});return changed;}
    List<JSONObject> media(){List<JSONObject> result=new ArrayList<>();for(JSONObject m:messages)if(m.optString("attachment_type").matches("(image|video)/.+"))result.add(m);return result;}
    static String clean(String body){return CONTRACT.matcher(body==null?"":body).replaceAll("").trim();}
    static String contract(String body){Matcher matcher=CONTRACT.matcher(body==null?"":body);return matcher.find()?matcher.group(1):null;}
    static String pendingId(String previousSignature,String signature,String previousId){return signature.equals(previousSignature)&&previousId!=null&&!previousId.isEmpty()?previousId:UUID.randomUUID().toString();}
}
