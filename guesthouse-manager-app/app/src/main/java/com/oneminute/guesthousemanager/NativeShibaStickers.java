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
    private static final int[][] FRAMES={{30,110,277,384},{280,110,548,384},{565,110,810,384},{827,110,1068,388},{1076,134,1374,390},{1397,108,1634,384},{1640,105,1890,385},{30,450,273,723},{280,450,566,725},{574,450,817,725},{829,451,1065,725},{1084,447,1362,725},{1380,448,1646,725},{1650,465,1890,724},{20,120,267,380},{290,120,555,380},{570,120,820,380},{850,124,1100,380},{1120,124,1372,380},{1384,118,1618,380},{1640,132,1890,380},{15,475,277,728},{305,470,535,725},{560,480,814,725},{840,470,1082,728},{1083,480,1350,728},{1360,452,1628,732},{1650,470,1899,725}};
    private static final Bitmap[] ATLASES=new Bitmap[2];
    private static final Pattern TOKEN=Pattern.compile("\\[시바:[^\\]\\r\\n]{1,20}\\]");
    static String token(int index){return "[시바:"+LABELS[index]+"]";}
    private static int index(String token){for(int i=0;i<LABELS.length;i++)if(token(i).equals(token))return i;return -1;}
    static String preview(String value){Matcher matcher=TOKEN.matcher(value==null?"":value);StringBuffer result=new StringBuffer();while(matcher.find()){int index=index(matcher.group());matcher.appendReplacement(result,Matcher.quoteReplacement(index<0?matcher.group():"🐕 "+LABELS[index]));}matcher.appendTail(result);return result.toString();}
    static synchronized Drawable drawable(Context context,int index,int pixels){
        int pack=index/14,cell=index%14;
        if(ATLASES[pack]==null)try(InputStream stream=context.getAssets().open(FILES[pack])){ATLASES[pack]=BitmapFactory.decodeStream(stream);}catch(Exception ignored){}
        if(ATLASES[pack]==null)return null;
        Drawable result=new Sprite(ATLASES[pack],index);result.setBounds(0,0,pixels,pixels);return result;
    }
    static CharSequence render(Context context,String value,int pixels){SpannableString result=new SpannableString(value);decorate(context,result,pixels);return result;}
    static void decorate(Context context,Spannable text,int pixels){
        for(ImageSpan span:text.getSpans(0,text.length(),ImageSpan.class))text.removeSpan(span);
        Matcher matcher=TOKEN.matcher(text);while(matcher.find()){int index=index(matcher.group());if(index<0)continue;Drawable art=drawable(context,index,pixels);if(art!=null)text.setSpan(new ImageSpan(art,ImageSpan.ALIGN_BOTTOM),matcher.start(),matcher.end(),Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);}
    }
    private static final class Sprite extends Drawable {
        final Bitmap atlas;final Rect source;final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG|Paint.FILTER_BITMAP_FLAG);
        Sprite(Bitmap atlas,int index){this.atlas=atlas;int[] frame=FRAMES[index];source=new Rect(frame[0],frame[1],frame[2],frame[3]);}
        @Override public void draw(Canvas canvas){Rect box=getBounds();float scale=Math.min(box.width()/(float)source.width(),box.height()/(float)source.height()),w=source.width()*scale,h=source.height()*scale;RectF destination=new RectF(box.exactCenterX()-w/2,box.exactCenterY()-h/2,box.exactCenterX()+w/2,box.exactCenterY()+h/2);canvas.drawBitmap(atlas,source,destination,paint);}
        @Override public void setAlpha(int alpha){paint.setAlpha(alpha);invalidateSelf();}
        @Override public void setColorFilter(ColorFilter filter){paint.setColorFilter(filter);invalidateSelf();}
        @Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
    }
}
