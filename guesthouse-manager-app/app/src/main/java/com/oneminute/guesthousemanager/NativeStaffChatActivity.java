package com.oneminute.guesthousemanager;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.net.Uri;
import android.os.*;
import android.text.*;
import android.view.*;
import android.view.inputmethod.InputMethodManager;
import android.widget.*;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.view.*;
import org.json.*;
import java.io.*;
import java.text.SimpleDateFormat;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
import static com.oneminute.guesthousemanager.StaffChatUi.*;

/** Native Android staff conversation list, room, composer, profile and mixed-media viewer. */
public final class NativeStaffChatActivity extends AppCompatActivity {
    interface ApiFactory { NativeStaffChatApi create(Context context) throws Exception; }
    static ApiFactory apiFactory=NativeStaffChatApi::new;
    private static final int PICK_MEDIA=7301;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final NativeStaffChatState state=new NativeStaffChatState();
    private NativeStaffChatApi api;
    private NativeStaffChatMedia media;
    private NativeChatUpload upload;
    private NativeStaffMediaViewer viewer;
    private LinearLayout root,composer;
    private ListView list;
    private EditText input,search;
    private TextView title,status,send,priority,older,attachment;
    private ImageButton attach;
    private ImageButton emoji;
    private ImageView headerAvatar;
    private GridView emojis;
    private BaseAdapter adapter;
    private String peer="",draftKey="",mime="",pendingId="",pendingSignature="",query="";
    private File pendingFile;
    private boolean urgent,canSend=true,sending,preparing,busy,active,destroyed,complete,searching,profileLoading;
    private int generation;
    private JSONArray rooms=new JSONArray(),recipients=new JSONArray();
    private final Set<String> properties=new HashSet<>(),reading=new HashSet<>();
    private final Runnable poll=()->load(false,null);
    private final Runnable readVisible=this::readVisible;
    private JSONObject profile;

    @Override protected void onCreate(Bundle saved){
        super.onCreate(saved);
        try{api=apiFactory.create(this);}catch(Exception e){Toast.makeText(this,e.getMessage(),Toast.LENGTH_LONG).show();finish();return;}
        media=new NativeStaffChatMedia(api);upload=new NativeChatUpload(this);
        try{JSONArray selected=new JSONArray(getIntent().getStringExtra("property_ids")==null?"[]":getIntent().getStringExtra("property_ids"));for(int i=0;i<selected.length();i++)if(selected.optString(i).matches("[0-9a-fA-F-]{36}"))properties.add(selected.optString(i));}catch(Exception ignored){}
        String initial=saved!=null?saved.getString("peer",""):getIntent().getStringExtra("peer");
        if(initial!=null&&!initial.isEmpty()&&!NativeStaffChatApi.validPeer(initial)){finish();return;}
        peer=initial==null?"":initial;build();
    }
    private void build(){
        generation++;busy=false;searching=false;reading.clear();state.clear();complete=false;profile=null;profileLoading=false;query="";canSend=peer.isEmpty();emojis=null;
        WindowCompat.setDecorFitsSystemWindows(getWindow(),false);
        root=column(this);root.setBackgroundColor(BG);setContentView(root);
        ViewCompat.setOnApplyWindowInsetsListener(root,(v,insets)->{androidx.core.graphics.Insets bars=insets.getInsets(WindowInsetsCompat.Type.systemBars()|WindowInsetsCompat.Type.ime());v.setPadding(bars.left,bars.top,bars.right,bars.bottom);return insets;});
        LinearLayout header=row(this);header.setPadding(dp(this,12),dp(this,8),dp(this,12),dp(this,8));ImageButton back=icon(this,"back",peer.isEmpty()?"OMS로 돌아가기":"채팅 목록으로 돌아가기");title=text(this,peer.isEmpty()?"직원 채팅":"대화 불러오는 중…",20,INK);title.setTypeface(null,Typeface.BOLD);title.setPadding(dp(this,12),0,dp(this,8),0);ImageButton searchButton=icon(this,"search","대화 검색");ImageButton extra=icon(this,peer.isEmpty()?"plus":"grid",peer.isEmpty()?"새 대화":"사진·동영상 모아보기");header.addView(back,new LinearLayout.LayoutParams(dp(this,44),dp(this,44)));if(!peer.isEmpty()){FrameLayout avatar=avatar("?",null,32);headerAvatar=(ImageView)avatar.getChildAt(1);LinearLayout.LayoutParams ap=new LinearLayout.LayoutParams(dp(this,32),dp(this,32));ap.leftMargin=dp(this,10);header.addView(avatar,ap);avatar.setOnClickListener(v->showProfile());}else headerAvatar=null;header.addView(title,weighted());header.addView(searchButton,new LinearLayout.LayoutParams(dp(this,44),dp(this,44)));LinearLayout.LayoutParams iconGap=new LinearLayout.LayoutParams(dp(this,44),dp(this,44));iconGap.leftMargin=dp(this,6);header.addView(extra,iconGap);root.addView(header);
        back.setOnClickListener(v->back());searchButton.setOnClickListener(v->{search.setVisibility(search.getVisibility()==View.GONE?View.VISIBLE:View.GONE);if(search.getVisibility()==View.VISIBLE)search.requestFocus();else{query="";search.setText("");refreshList(false);}});extra.setOnClickListener(v->{if(peer.isEmpty())showPeople();else openGallery();});title.setOnClickListener(v->{if(!peer.isEmpty())showProfile();});
        search=new EditText(this);search.setSingleLine(true);search.setTextSize(14);search.setTextColor(INK);search.setHint(peer.isEmpty()?"이름 또는 대화 내용 검색":"내용 검색 · 입력 후 검색을 누르면 이전 대화도 검색");search.setVisibility(View.GONE);search.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH);root.addView(search);
        search.addTextChangedListener(new SimpleWatcher(){@Override public void afterTextChanged(Editable e){query=e.toString().trim().toLowerCase(Locale.ROOT);refreshList(false);}});search.setOnEditorActionListener((v,action,event)->{if(action==android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH&&!peer.isEmpty()){searchHistory(0);return true;}return false;});
        status=text(this,"불러오는 중…",12,MUTED);status.setPadding(dp(this,16),dp(this,3),dp(this,16),dp(this,3));status.setMinHeight(dp(this,22));status.setOnClickListener(v->load(false,null));root.addView(status);
        list=new ListView(this);list.setDivider(null);list.setClipToPadding(false);list.setPadding(dp(this,12),0,dp(this,12),dp(this,8));
        older=button(this,"이전 대화 더 보기","이전 대화 더 보기");older.setVisibility(View.GONE);older.setOnClickListener(v->load(true,null));list.addHeaderView(older,null,false);if(peer.isEmpty()){TextView notices=button(this,"공지 · 시스템 알림 ›","공지 및 시스템 알림 보기");notices.setGravity(Gravity.CENTER_VERTICAL);notices.setPadding(dp(this,14),0,dp(this,14),0);notices.setOnClickListener(v->startActivity(new Intent(this,AttendanceActivity.class).setData(Uri.parse("https://omgworks24.com/messages.html?tab=staff")).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_SINGLE_TOP)));list.addHeaderView(notices,null,false);}list.setStackFromBottom(!peer.isEmpty());root.addView(list,new LinearLayout.LayoutParams(-1,0,1));
        list.setOnScrollListener(new AbsListView.OnScrollListener(){public void onScrollStateChanged(AbsListView v,int s){scheduleRead();}public void onScroll(AbsListView v,int first,int visible,int total){scheduleRead();}});
        if(!peer.isEmpty())buildComposer();else composer=null;
        refreshList(true);if(active)load(false,null);
    }
    private void buildComposer(){
        composer=column(this);composer.setPadding(dp(this,10),dp(this,6),dp(this,10),dp(this,8));composer.setBackgroundColor(Color.WHITE);root.addView(composer);
        attachment=text(this,"",12,MUTED);attachment.setPadding(dp(this,8),dp(this,8),dp(this,8),dp(this,8));attachment.setVisibility(View.GONE);attachment.setOnClickListener(v->{if(sending||preparing)return;new AlertDialog.Builder(this).setMessage("첨부를 취소할까요?").setNegativeButton("유지",null).setPositiveButton("첨부 취소",(d,w)->{if(pendingFile!=null)pendingFile.delete();pendingFile=null;mime="";pendingId="";showAttachment();saveDraft();}).show();});composer.addView(attachment);
        LinearLayout row=row(this);row.setGravity(Gravity.BOTTOM);composer.addView(row);
        priority=button(this,"일반⌄","일반 또는 긴급 선택");priority.setTextSize(12);priority.setMinWidth(dp(this,50));row.addView(priority,new LinearLayout.LayoutParams(dp(this,54),dp(this,44)));priority.setOnClickListener(v->{if(sending)return;urgent=!urgent;paintPriority();pendingId="";saveDraft();});
        attach=icon(this,"photo","사진 또는 동영상 첨부");LinearLayout.LayoutParams small=new LinearLayout.LayoutParams(dp(this,40),dp(this,44));small.setMargins(dp(this,5),0,dp(this,5),0);row.addView(attach,small);attach.setOnClickListener(v->{if(!canSend||sending||preparing)return;Intent pick=new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_MIME_TYPES,new String[]{"image/*","video/*"});try{startActivityForResult(pick,PICK_MEDIA);}catch(Exception e){notice("파일 선택기를 열지 못했습니다.",true);}});
        FrameLayout wrap=new FrameLayout(this);wrap.setBackground(background(0xfff2f7fd,16,this));row.addView(wrap,new LinearLayout.LayoutParams(0,-2,1));
        input=new EditText(this);input.setTextSize(15);input.setTextColor(INK);input.setHintTextColor(0xff91a1b5);input.setHint("메세지 입력");input.setBackgroundColor(Color.TRANSPARENT);input.setMinLines(1);input.setMaxLines(4);input.setMinHeight(dp(this,44));input.setPadding(dp(this,12),dp(this,10),dp(this,38),dp(this,10));input.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE|android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);input.setFilters(new InputFilter[]{new InputFilter.LengthFilter(2000)});input.setContentDescription("메세지 내용");wrap.addView(input,new FrameLayout.LayoutParams(-1,-2));
        emoji=new ImageButton(this);emoji.setImageDrawable(new Smile());emoji.setBackgroundColor(Color.TRANSPARENT);emoji.setPadding(dp(this,6),dp(this,6),dp(this,6),dp(this,6));emoji.setContentDescription("이모지 선택");FrameLayout.LayoutParams ep=new FrameLayout.LayoutParams(dp(this,36),dp(this,44),Gravity.RIGHT|Gravity.BOTTOM);wrap.addView(emoji,ep);
        send=button(this,"➤","메세지 보내기");send.setTextColor(Color.WHITE);send.setBackground(background(0xff82ace1,14,this));LinearLayout.LayoutParams sp=new LinearLayout.LayoutParams(dp(this,42),dp(this,44));sp.setMargins(dp(this,5),0,0,0);row.addView(send,sp);send.setOnClickListener(v->send());
        emojis=new GridView(this);emojis.setNumColumns(7);emojis.setHorizontalSpacing(dp(this,2));emojis.setVerticalSpacing(dp(this,2));emojis.setBackground(background(0xfff8fbff,16,this));emojis.setVisibility(View.GONE);emojis.setAdapter(new BaseAdapter(){public int getCount(){return EMOJIS.length;}public Object getItem(int p){return EMOJIS[p];}public long getItemId(int p){return p;}public View getView(int p,View recycled,ViewGroup parent){TextView cell=text(NativeStaffChatActivity.this,EMOJIS[p],26,INK);cell.setGravity(Gravity.CENTER);cell.setLayoutParams(new AbsListView.LayoutParams(-1,dp(NativeStaffChatActivity.this,42)));cell.setContentDescription(EMOJIS[p]+" 삽입");return cell;}});composer.addView(emojis,new LinearLayout.LayoutParams(-1,Math.min(dp(this,220),getResources().getDisplayMetrics().heightPixels/3)));
        emojis.setOnItemClickListener((parent,view,position,id)->{int a=Math.max(0,input.getSelectionStart()),b=Math.max(a,input.getSelectionEnd());String value=EMOJIS[position];if(input.length()-(b-a)+value.length()<=2000)input.getText().replace(a,b,value);});
        emoji.setOnClickListener(v->{if(!canSend)return;boolean show=emojis.getVisibility()!=View.VISIBLE;if(show)((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(input.getWindowToken(),0);emojis.setVisibility(show?View.VISIBLE:View.GONE);emoji.setContentDescription(show?"이모지 선택 닫기":"이모지 선택");});input.setOnClickListener(v->emojis.setVisibility(View.GONE));
        restoreDraft();input.addTextChangedListener(new SimpleWatcher(){@Override public void afterTextChanged(Editable e){saveDraft();}});paintPriority();showAttachment();enableComposer();
    }
    private void paintPriority(){priority.setText(urgent?"긴급⌄":"일반⌄");priority.setTextColor(urgent?0xffbd354b:0xff486b91);priority.setBackground(background(urgent?0xfffff0f2:0xfff0f4f9,14,this));}
    private File draftDirectory(){File dir=new File(getFilesDir(),"staff-chat-drafts/"+api.scope);dir.mkdirs();return dir;}
    private void restoreDraft(){
        draftKey=api.scope+":"+peer;urgent=false;pendingId="";pendingSignature="";pendingFile=null;mime="";
        try{JSONObject draft=new JSONObject(getSharedPreferences("omg_chat_drafts",MODE_PRIVATE).getString(draftKey,"{}"));input.setText(draft.optString("body"));urgent=draft.optBoolean("urgent");pendingId=draft.optString("client_id");pendingSignature=draft.optString("signature");mime=draft.optString("mime");String path=draft.optString("file");if(!path.isEmpty()){File file=new File(path);if(file.getCanonicalPath().startsWith(draftDirectory().getCanonicalPath()+File.separator)&&file.exists())pendingFile=file;}}catch(Exception ignored){}
    }
    private void saveDraft(){if(input==null||peer.isEmpty()||api==null||!api.valid())return;try{JSONObject draft=new JSONObject().put("body",input.getText().toString()).put("urgent",urgent).put("client_id",pendingId).put("signature",pendingSignature).put("mime",mime).put("file",pendingFile==null?"":pendingFile.getPath());getSharedPreferences("omg_chat_drafts",MODE_PRIVATE).edit().putString(draftKey,draft.toString()).apply();}catch(Exception ignored){}}
    private void showAttachment(){attachment.setVisibility(pendingFile==null?View.GONE:View.VISIBLE);if(pendingFile!=null)attachment.setText((mime.startsWith("video/")?"▶ 동영상":"▧ 사진")+String.format(Locale.KOREA," · %.1fMB · 눌러서 취소",pendingFile.length()/1048576d));}
    private void enableComposer(){if(composer==null)return;boolean enabled=canSend&&!sending&&!preparing;input.setEnabled(enabled);send.setEnabled(enabled);send.setAlpha(enabled?1:.45f);attach.setEnabled(enabled);priority.setEnabled(enabled);emoji.setEnabled(enabled);emojis.setEnabled(enabled);}
    private void notice(String message,boolean error){if(destroyed)return;status.setText(message);status.setTextColor(error?0xffb43c4e:MUTED);}
    private JSONObject data()throws JSONException{return new JSONObject().put("peer",peer);}
    private void load(boolean previous,Runnable ready){
        if(!active||destroyed)return;if(busy){if(ready!=null)main.postDelayed(()->load(previous,ready),200);return;}if(!api.valid()){finish();return;}busy=true;main.removeCallbacks(poll);final int request=generation;final String room=peer;
        JSONObject args;try{args=data();if(previous&&!state.messages.isEmpty()){JSONObject first=state.messages.get(0);args.put("before_time",first.getString("created_at")).put("before_id",first.getString("id"));}}catch(Exception e){busy=false;return;}
        final String anchor=firstVisibleId();final int anchorTop=list.getChildCount()>0?list.getChildAt(0).getTop():0;final boolean atBottom=list.getLastVisiblePosition()>=list.getCount()-2;
        worker.execute(()->{
            try{
                JSONObject result=api.chat(room.isEmpty()?"rooms":"messages",args);
                main.post(()->{
                    if(destroyed||request!=generation)return;
                    if(room.isEmpty()){rooms=result.optJSONArray("rooms");if(rooms==null)rooms=new JSONArray();refreshList(false);}
                    else{JSONArray incoming=result.optJSONArray("messages");if(incoming==null)incoming=new JSONArray();boolean initial=state.messages.isEmpty();boolean changed=state.merge(incoming);if(previous||initial)complete=incoming.length()<50;canSend=result.optBoolean("can_send",false);JSONObject person=result.optJSONObject("peer");if(person!=null&&profile==null)title.setText(person.optString("display_name","근무자"));older.setVisibility(complete?View.GONE:View.VISIBLE);enableComposer();if(changed){refreshList(initial||atBottom&&!previous);if(previous&&!anchor.isEmpty())restoreAnchor(anchor,anchorTop);}if(!canSend)notice("현재 이 계정에 메세지를 보낼 수 없습니다.",true);if(profile==null&&!profileLoading)loadProfile(false);scheduleRead();}
                    if(canSend||room.isEmpty())notice("",false);finishLoad(request,ready);
                });
            }catch(Exception e){main.post(()->{if(!destroyed&&request==generation){notice(e.getMessage()==null?"연결을 확인하고 여기를 눌러 다시 시도해주세요.":e.getMessage(),true);finishLoad(request,ready);}});}
        });
    }
    private void finishLoad(int request,Runnable ready){if(request!=generation)return;busy=false;if(ready!=null)ready.run();if(active)main.postDelayed(poll,peer.isEmpty()?4000:2500);}
    private String firstVisibleId(){int p=list.getFirstVisiblePosition()-list.getHeaderViewsCount();List<JSONObject> shown=shownMessages();return !peer.isEmpty()&&p>=0&&p<shown.size()?shown.get(p).optString("id"):"";}
    private void restoreAnchor(String id,int top){List<JSONObject> shown=shownMessages();for(int i=0;i<shown.size();i++)if(id.equals(shown.get(i).optString("id"))){list.setSelectionFromTop(i+list.getHeaderViewsCount(),top);return;}}
    private List<JSONObject> shownMessages(){List<JSONObject> result=new ArrayList<>();for(JSONObject m:state.messages)if(query.isEmpty()||NativeStaffChatState.clean(m.optString("body")).toLowerCase(Locale.ROOT).contains(query))result.add(m);return result;}
    private List<JSONObject> shownRooms(){List<JSONObject> result=new ArrayList<>();for(int i=0;i<rooms.length();i++){JSONObject r=rooms.optJSONObject(i);if(r==null||!properties.isEmpty()&&!properties.contains(r.optString("property_id")))continue;if(query.isEmpty()||(r.optString("name")+" "+r.optString("preview")+" "+r.optString("property_name")).toLowerCase(Locale.ROOT).contains(query))result.add(r);}return result;}
    private void refreshList(boolean bottom){
        if(list==null)return;final boolean conversations=peer.isEmpty();final List<JSONObject> shown=conversations?shownRooms():shownMessages();
        if(adapter instanceof RowsAdapter){((RowsAdapter)adapter).items=shown;adapter.notifyDataSetChanged();}else{adapter=new RowsAdapter(shown,conversations);list.setAdapter(adapter);}
        if(bottom&&!shown.isEmpty())list.post(()->list.setSelection(list.getCount()-1));
        if(shown.isEmpty()&&status!=null)notice(query.isEmpty()?(conversations?"아직 대화가 없습니다. +를 눌러 대화를 시작하세요.":"첫 메세지를 보내 대화를 시작하세요."):"검색 결과가 없습니다.",false);
    }
    private final class RowsAdapter extends BaseAdapter{
        List<JSONObject> items;final boolean conversations;
        RowsAdapter(List<JSONObject> items,boolean conversations){this.items=items;this.conversations=conversations;}
        public int getCount(){return items.size();}public Object getItem(int p){return items.get(p);}public long getItemId(int p){return items.get(p).optString("id",items.get(p).optString("peer")).hashCode();}
        public View getView(int p,View recycled,ViewGroup parent){return conversations?roomRow(items.get(p)):messageRow(items.get(p),p==0||!date(items.get(p-1).optString("created_at"),false).equals(date(items.get(p).optString("created_at"),false)));}
    }
    private View roomRow(JSONObject room){
        LinearLayout row=row(this);row.setPadding(dp(this,5),dp(this,14),dp(this,5),dp(this,14));FrameLayout avatar=avatar(room.optString("name"),room.optString("profile_image"),48);row.addView(avatar,new LinearLayout.LayoutParams(dp(this,48),dp(this,48)));
        LinearLayout copy=column(this);copy.setPadding(dp(this,12),0,dp(this,8),0);String name=room.optString("name");String home=getSharedPreferences("omg_push",MODE_PRIVATE).getString("property_id","");if(!room.optString("property_id").equals(home)&&!room.optString("property_name").isEmpty())name+=" · "+room.optString("property_name");TextView n=text(this,name,15,INK);n.setTypeface(null,Typeface.BOLD);copy.addView(n);TextView preview=text(this,NativeStaffChatState.clean(room.optString("preview")),12,MUTED);preview.setMaxLines(1);preview.setEllipsize(TextUtils.TruncateAt.END);copy.addView(preview);row.addView(copy,weighted());TextView badge=text(this,(room.optInt("unread")>0?room.optInt("unread")+"\n":"")+date(room.optString("updated_at"),true),10,BLUE);row.addView(badge);row.setOnClickListener(v->openRoom(room.optString("peer")));return row;
    }
    private View messageRow(JSONObject message,boolean newDay){
        boolean mine=message.optBoolean("mine");LinearLayout outer=column(this);outer.setPadding(0,dp(this,5),0,dp(this,5));
        if(newDay){TextView day=text(this,date(message.optString("created_at"),false),11,MUTED);day.setGravity(Gravity.CENTER);day.setPadding(0,dp(this,12),0,dp(this,12));outer.addView(day);}
        LinearLayout content=column(this);content.setPadding(dp(this,12),dp(this,9),dp(this,12),dp(this,9));content.setBackground(background(mine?SOFT:Color.WHITE,16,this));LinearLayout.LayoutParams cp=new LinearLayout.LayoutParams(-2,-2);cp.gravity=mine?Gravity.RIGHT:Gravity.LEFT;outer.addView(content,cp);
        if("urgent".equals(message.optString("priority"))){TextView flag=text(this,"긴급",10,0xffbd354b);content.addView(flag);}
        if(message.optBoolean("broadcast"))content.addView(text(this,"여러 사람에게 보낸 메세지",10,MUTED));
        String type=message.optString("attachment_type");if(type.startsWith("image/")||type.startsWith("video/")){
            FrameLayout picture=new FrameLayout(this);ImageView image=new ImageView(this);image.setScaleType(ImageView.ScaleType.CENTER_CROP);picture.addView(image,new FrameLayout.LayoutParams(-1,-1));boolean video=type.startsWith("video/");media.bind(image,peer,message.optString("id"),video);if(video){TextView play=text(this,"▶",30,Color.WHITE);play.setShadowLayer(4,0,1,Color.BLACK);play.setGravity(Gravity.CENTER);picture.addView(play,new FrameLayout.LayoutParams(-1,-1));}content.addView(picture,new LinearLayout.LayoutParams(Math.min(dp(this,220),getResources().getDisplayMetrics().widthPixels-dp(this,100)),dp(this,140)));picture.setContentDescription(video?"동영상 전체화면 보기":"사진 전체화면 보기");picture.setOnClickListener(v->openMedia(message.optString("id")));
        }
        String clean=NativeStaffChatState.clean(message.optString("body"));if(!clean.isEmpty()){TextView body=text(this,clean,15,INK);body.setMaxWidth(Math.max(dp(this,120),getResources().getDisplayMetrics().widthPixels-dp(this,105)));body.setTextIsSelectable(true);content.addView(body);}
        String contract=NativeStaffChatState.contract(message.optString("body"));if(contract!=null){TextView link=button(this,"근로계약서 확인·서명 ›","근로계약서 확인 및 서명");link.setTextSize(13);content.addView(link);link.setOnClickListener(v->startActivity(new Intent(this,AttendanceActivity.class).setData(Uri.parse("https://omgworks24.com/contracts.html?id="+Uri.encode(contract)+"&from=notification")).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_SINGLE_TOP)));}
        TextView time=text(this,date(message.optString("created_at"),true),10,MUTED);LinearLayout.LayoutParams tp=new LinearLayout.LayoutParams(-2,-2);tp.gravity=mine?Gravity.RIGHT:Gravity.LEFT;time.setPadding(dp(this,3),dp(this,3),dp(this,3),0);outer.addView(time,tp);return outer;
    }
    private FrameLayout avatar(String name,String data,int size){FrameLayout frame=new FrameLayout(this);frame.setBackground(background(SOFT,size/2f,this));frame.setClipToOutline(true);TextView letter=text(this,initial(name),Math.max(15,size/2),BLUE);letter.setGravity(Gravity.CENTER);frame.addView(letter,new FrameLayout.LayoutParams(-1,-1));ImageView image=new ImageView(this);image.setScaleType(ImageView.ScaleType.CENTER_CROP);frame.addView(image,new FrameLayout.LayoutParams(-1,-1));media.avatar(image,data);return frame;}
    private static String initial(String value){return value.isEmpty()?"?":value.substring(0,value.offsetByCodePoints(0,1));}
    private static String date(String value,boolean time){try{SimpleDateFormat format=new SimpleDateFormat(time?"a hh:mm":"yyyy. M. d.",Locale.KOREA);return format.format(Date.from(Instant.parse(value)));}catch(Exception e){return "";}}
    private void scheduleRead(){main.removeCallbacks(readVisible);if(active&&!peer.isEmpty())main.postDelayed(readVisible,300);}
    private void readVisible(){
        if(!active||destroyed||peer.isEmpty()||!hasWindowFocus()||viewer!=null&&viewer.showing())return;
        List<JSONObject> shown=shownMessages();int first=Math.max(0,list.getFirstVisiblePosition()-list.getHeaderViewsCount()),last=Math.min(shown.size()-1,list.getLastVisiblePosition()-list.getHeaderViewsCount());JSONArray ids=new JSONArray();List<JSONObject> acknowledged=new ArrayList<>();
        for(int i=first;i<=last;i++){JSONObject m=shown.get(i);String id=m.optString("id");if(!m.optBoolean("mine")&&m.isNull("read_at")&&reading.add(id)){ids.put(id);acknowledged.add(m);}}
        if(ids.length()==0)return;final int request=generation;final String room=peer;
        worker.execute(()->{boolean ok=false;try{api.chat("read",new JSONObject().put("peer",room).put("ids",ids));ok=true;}catch(Exception ignored){}final boolean succeeded=ok;main.post(()->{if(request!=generation||destroyed)return;for(JSONObject m:acknowledged){reading.remove(m.optString("id"));if(succeeded)try{m.put("read_at",Instant.now().toString());}catch(Exception ignored){}}});});
    }
    private void openRoom(String value){if(!NativeStaffChatApi.validPeer(value))return;saveDraft();main.removeCallbacks(poll);if(viewer!=null)viewer.dismiss();peer=value;adapter=null;input=null;canSend=true;sending=false;preparing=false;build();}
    private void showPeople(){
        notice("대화할 사람을 불러오는 중…",false);int request=generation;
        worker.execute(()->{try{JSONObject result=api.rpc("list_property_messages",new JSONObject());JSONArray people=result.optJSONArray("recipients");main.post(()->{if(destroyed||request!=generation)return;recipients=people==null?new JSONArray():people;notice("",false);peopleDialog();});}catch(Exception e){main.post(()->notice("대화할 사람을 불러오지 못했습니다. 다시 시도해주세요.",true));}});
    }
    private void peopleDialog(){
        LinearLayout box=column(this);EditText filter=new EditText(this);filter.setSingleLine(true);filter.setHint("이름 검색");box.addView(filter);ListView people=new ListView(this);box.addView(people,new LinearLayout.LayoutParams(-1,dp(this,350)));AlertDialog dialog=new AlertDialog.Builder(this).setTitle("대화할 사람").setView(box).setNegativeButton("닫기",null).create();
        Runnable render=()->{List<JSONObject> matches=new ArrayList<>();String q=filter.getText().toString().toLowerCase(Locale.ROOT);for(int i=0;i<recipients.length();i++){JSONObject p=recipients.optJSONObject(i);if(p!=null&&(properties.isEmpty()||properties.contains(p.optString("property_id")))&&p.optString("display_name").toLowerCase(Locale.ROOT).contains(q))matches.add(p);}people.setAdapter(new BaseAdapter(){public int getCount(){return matches.size();}public Object getItem(int p){return matches.get(p);}public long getItemId(int p){return p;}public View getView(int p,View old,ViewGroup parent){JSONObject person=matches.get(p);TextView row=text(NativeStaffChatActivity.this,person.optString("display_name"),15,INK);row.setPadding(dp(NativeStaffChatActivity.this,16),dp(NativeStaffChatActivity.this,14),dp(NativeStaffChatActivity.this,16),dp(NativeStaffChatActivity.this,14));row.setOnClickListener(v->{dialog.dismiss();openRoom(person.optString("recipient_key"));});return row;}});};filter.addTextChangedListener(new SimpleWatcher(){@Override public void afterTextChanged(Editable e){render.run();}});dialog.show();render.run();
    }
    private void showProfile(){if(profile!=null)profileDialog();else loadProfile(true);}
    private void loadProfile(boolean show){
        if(profileLoading)return;profileLoading=true;final String room=peer;final int request=generation;worker.execute(()->{try{JSONObject p=api.rpc("staff_chat_peer_profile",new JSONObject().put("p_peer",room)).getJSONObject("profile");main.post(()->{if(!destroyed&&request==generation){profileLoading=false;profile=p;title.setText(p.optString("display_name","근무자"));if(headerAvatar!=null){media.avatar(headerAvatar,p.optString("profile_image"));((TextView)((FrameLayout)headerAvatar.getParent()).getChildAt(0)).setText(initial(p.optString("display_name","?")));}if(show)profileDialog();}});}catch(Exception e){main.post(()->{if(request!=generation)return;profileLoading=false;if(show)notice("근무자 정보를 불러오지 못했습니다.",true);});}});
    }
    private void profileDialog(){if(profile==null)return;StringBuilder text=new StringBuilder();for(String[] field:new String[][]{{"이름","display_name"},{"직무","job_title"},{"지점 (소속)","property_name"},{"연락처","contact_phone"}})text.append(field[0]).append("  ").append(profile.optString(field[1],"-")).append("\n\n");new AlertDialog.Builder(this).setTitle("근무자 정보").setMessage(text.toString().trim()).setPositiveButton("닫기",null).show();}
    private void searchHistory(int pages){if(pages==0&&searching||complete||peer.isEmpty())return;if(pages==0)searching=true;notice("이전 대화에서 검색 중…",false);int request=generation;load(true,()->{if(request!=generation)return;if(!complete&&pages<19)searchHistory(pages+1);else{searching=false;refreshList(false);notice(complete?"검색을 완료했습니다.":"검색을 다시 누르면 더 이전 대화도 검색합니다.",false);}});}
    private void openMedia(String id){List<JSONObject> items=state.media();if(items.isEmpty())return;if(viewer!=null)viewer.dismiss();viewer=new NativeStaffMediaViewer(this,media,peer,items,id,new NativeStaffMediaViewer.History(){public void older(Runnable ready){load(true,ready);}public List<JSONObject> items(){return state.media();}public boolean complete(){return complete;}});}
    private void openGallery(){collectMedia(0,generation);}
    private void collectMedia(int pages,int request){
        if(request!=generation||destroyed)return;
        if(!state.media().isEmpty()){openMedia(state.media().get(state.media().size()-1).optString("id"));viewer.showGallery(true);return;}
        if(complete){notice("대화에 사진이나 동영상이 없습니다.",false);return;}
        if(pages>=20){notice("더 이전의 미디어를 확인하려면 모아보기를 다시 눌러주세요.",false);return;}
        notice("이전 대화에서 미디어를 불러오는 중…",false);load(true,()->collectMedia(pages+1,request));
    }
    private void send(){
        if(!canSend||sending||preparing||!api.valid())return;String body=input.getText().toString().trim();if(body.isEmpty()&&pendingFile==null)return;if(body.isEmpty())body=mime.startsWith("video/")?"동영상":"사진";
        final String message=body,room=peer,key=draftKey,type=mime;final File file=pendingFile;final int request=generation;
        String signature=message+"\n"+urgent+"\n"+(file==null?"":file.getPath());pendingId=NativeStaffChatState.pendingId(pendingSignature,signature,pendingId);pendingSignature=signature;final String clientId=pendingId;final String level=urgent?"urgent":"normal";saveDraft();sending=true;enableComposer();notice("보내는 중…",false);
        worker.execute(()->{
            try{
                JSONObject args=new JSONObject().put("peer",room).put("body",message).put("priority",level).put("client_id",clientId);
                if(file!=null){if(file.length()>(type.startsWith("video/")?20*1024*1024:1572864))throw new IOException("첨부 파일 크기를 확인해주세요.");byte[] bytes=new byte[(int)file.length()];try(DataInputStream in=new DataInputStream(new FileInputStream(file))){in.readFully(bytes);}args.put("photo","data:"+type+";base64,"+android.util.Base64.encodeToString(bytes,android.util.Base64.NO_WRAP));}
                JSONObject result=api.chat("send",args);getSharedPreferences("omg_chat_drafts",MODE_PRIVATE).edit().remove(key).commit();if(file!=null)file.delete();
                String warning="";if(!result.optBoolean("duplicate"))try{api.notifyMessage(result.getString("message_id"));}catch(Exception e){warning="메세지는 저장됐지만 알림 전달을 확인하지 못했습니다.";}
                final String notification=warning;main.post(()->{if(destroyed||request!=generation)return;input.setText("");pendingFile=null;mime="";pendingId="";pendingSignature="";sending=false;showAttachment();saveDraft();enableComposer();notice(notification,!notification.isEmpty());load(false,null);});
            }catch(Exception e){main.post(()->{if(destroyed||request!=generation)return;sending=false;enableComposer();notice((e.getMessage()==null?"전송하지 못했습니다.":e.getMessage())+" · 보내기를 다시 누르면 중복 없이 재시도합니다.",true);});}
        });
    }
    @Override protected void onActivityResult(int request,int result,Intent data){
        super.onActivityResult(request,result,data);if(request!=PICK_MEDIA||result!=Activity.RESULT_OK||data==null||data.getData()==null||peer.isEmpty())return;
        preparing=true;enableComposer();notice("첨부 파일을 준비하는 중…",false);final int version=generation;upload.prepare(data.getData(),draftDirectory(),new NativeChatUpload.Callback(){public void status(String text){if(!destroyed&&version==generation)notice(text,false);}public void done(File file,String type){if(destroyed||version!=generation){file.delete();return;}if(pendingFile!=null)pendingFile.delete();pendingFile=file;mime=type;pendingId="";preparing=false;showAttachment();saveDraft();enableComposer();notice("",false);}public void failed(String message){if(destroyed||version!=generation)return;preparing=false;enableComposer();notice(message,true);}});
    }
    private void back(){if(viewer!=null&&viewer.showing()){viewer.dismiss();return;}if(emojis!=null&&emojis.getVisibility()==View.VISIBLE){emojis.setVisibility(View.GONE);return;}if(preparing){Toast.makeText(this,"첨부 파일 준비가 끝난 후 이동해주세요.",Toast.LENGTH_SHORT).show();return;}if(!peer.isEmpty()){saveDraft();peer="";adapter=null;input=null;sending=false;build();}else finish();}
    @Override public void onBackPressed(){back();}
    @Override protected void onResume(){super.onResume();active=true;if(api!=null){if(!api.valid()){finish();return;}load(false,null);}}
    @Override protected void onPause(){active=false;main.removeCallbacks(poll);main.removeCallbacks(readVisible);if(viewer!=null)viewer.pause();saveDraft();super.onPause();}
    @Override protected void onSaveInstanceState(Bundle state){state.putString("peer",peer);saveDraft();super.onSaveInstanceState(state);}
    @Override protected void onDestroy(){destroyed=true;active=false;generation++;main.removeCallbacksAndMessages(null);if(viewer!=null)viewer.dismiss();if(upload!=null)upload.close();if(media!=null)media.close();worker.shutdown();super.onDestroy();}
    private abstract static class SimpleWatcher implements TextWatcher{public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){}}
}
