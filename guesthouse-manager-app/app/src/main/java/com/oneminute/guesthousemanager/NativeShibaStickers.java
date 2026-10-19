package com.oneminute.guesthousemanager;

import android.content.Context;
import android.graphics.*;
import android.graphics.drawable.Drawable;
import android.text.*;
import android.text.style.ImageSpan;
import java.io.InputStream;
import java.util.regex.*;

/** The same two immutable local atlases and message tokens as shiba-stickers.js. */
final class NativeShibaStickers {
    static final String[] LABELS={"환영해요","체크인","체크아웃","청소 중","청소 완료","수건 보충","침구 교체","짐 보관","비번 안내","조용히","금연","수리 중","확인 완료","감사해요","방긋","ㅋㅋㅋ","사랑해","최고","오케이","고마워","미안해","엉엉","화났어","헉!","음…","잘 자","축하해","파이팅"};
    private static final String[] FILES={"shiba-guest.webp","shiba-daily.webp"};
    private static final Bitmap[] ATLASES=new Bitmap[2];
    private static final Pattern TOKEN=Pattern.compile("\\[시바:[^\\]\\r\\n]{1,20}\\]");
    static String token(int index){return "[시바:"+LABELS[index]+"]";}
    private static int index(String token){for(int i=0;i<LABELS.length;i++)if(token(i).equals(token))return i;return -1;}
    static String preview(String value){Matcher matcher=TOKEN.matcher(value==null?"":value);StringBuffer result=new StringBuffer();while(matcher.find()){int index=index(matcher.group());matcher.appendReplacement(result,Matcher.quoteReplacement(index<0?matcher.group():"🐕 "+LABELS[index]));}matcher.appendTail(result);return result.toString();}
    static synchronized Drawable drawable(Context context,int index,int pixels){
        int pack=index/14,cell=index%14;
        if(ATLASES[pack]==null)try(InputStream stream=context.getAssets().open(FILES[pack])){ATLASES[pack]=BitmapFactory.decodeStream(stream);}catch(Exception ignored){}
        if(ATLASES[pack]==null)return null;
        Drawable result=new Sprite(ATLASES[pack],cell);result.setBounds(0,0,pixels,pixels);return result;
    }
    static CharSequence render(Context context,String value,int pixels){SpannableString result=new SpannableString(value);decorate(context,result,pixels);return result;}
    static void decorate(Context context,Spannable text,int pixels){
        for(ImageSpan span:text.getSpans(0,text.length(),ImageSpan.class))text.removeSpan(span);
        Matcher matcher=TOKEN.matcher(text);while(matcher.find()){int index=index(matcher.group());if(index<0)continue;Drawable art=drawable(context,index,pixels);if(art!=null)text.setSpan(new ImageSpan(art,ImageSpan.ALIGN_BOTTOM),matcher.start(),matcher.end(),Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);}
    }
    private static final class Sprite extends Drawable {
        final Bitmap atlas;final Rect source;final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG|Paint.FILTER_BITMAP_FLAG);
        Sprite(Bitmap atlas,int cell){this.atlas=atlas;int column=cell%7,row=cell/7;source=new Rect(Math.round(column*atlas.getWidth()/7f),Math.round(row*atlas.getHeight()/2f),Math.round((column+1)*atlas.getWidth()/7f),Math.round((row+1)*atlas.getHeight()/2f));}
        @Override public void draw(Canvas canvas){Rect box=getBounds();float scale=Math.min(box.width()/(float)source.width(),box.height()/(float)source.height()),w=source.width()*scale,h=source.height()*scale;RectF destination=new RectF(box.exactCenterX()-w/2,box.exactCenterY()-h/2,box.exactCenterX()+w/2,box.exactCenterY()+h/2);canvas.drawBitmap(atlas,source,destination,paint);}
        @Override public void setAlpha(int alpha){paint.setAlpha(alpha);invalidateSelf();}
        @Override public void setColorFilter(ColorFilter filter){paint.setColorFilter(filter);invalidateSelf();}
        @Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
    }
}
