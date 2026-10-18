package com.oneminute.guesthousemanager;

import android.content.Context;
import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.Drawable;
import android.view.*;
import android.widget.*;

final class StaffChatUi {
    static final int INK=Color.rgb(25,51,79),BLUE=Color.rgb(36,103,189),BG=Color.rgb(244,247,252),SOFT=Color.rgb(223,236,252),MUTED=Color.rgb(125,146,169);
    static int dp(Context c,float value){return Math.round(value*c.getResources().getDisplayMetrics().density);}
    static GradientDrawable background(int color,float radius,Context c){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(c,radius));return d;}
    static TextView text(Context c,String value,int size,int color){TextView v=new TextView(c);v.setText(value);v.setTextSize(size);v.setTextColor(color);v.setGravity(Gravity.CENTER_VERTICAL);return v;}
    static TextView button(Context c,String value,String description){TextView v=text(c,value,16,BLUE);v.setGravity(Gravity.CENTER);v.setPadding(dp(c,8),0,dp(c,8),0);v.setMinHeight(dp(c,44));v.setMinWidth(dp(c,44));v.setContentDescription(description);v.setBackground(background(0xffedf3fb,13,c));v.setClickable(true);v.setFocusable(true);return v;}
    static ImageButton icon(Context c,String symbol,String description){ImageButton v=new ImageButton(c);v.setImageDrawable(new Symbol(symbol));v.setContentDescription(description);v.setBackground(background(0xffedf3fb,13,c));v.setPadding(dp(c,11),dp(c,11),dp(c,11),dp(c,11));v.setMinimumWidth(dp(c,44));v.setMinimumHeight(dp(c,44));return v;}
    static LinearLayout column(Context c){LinearLayout v=new LinearLayout(c);v.setOrientation(LinearLayout.VERTICAL);return v;}
    static LinearLayout row(Context c){LinearLayout v=new LinearLayout(c);v.setOrientation(LinearLayout.HORIZONTAL);v.setGravity(Gravity.CENTER_VERTICAL);return v;}
    static LinearLayout.LayoutParams weighted(){return new LinearLayout.LayoutParams(0,-2,1);}
    static final String[] EMOJIS={"😀","😄","😊","🙂","😉","😍","🥰","😘","😎","🤔","😅","😂","🤣","🥲","😭","😢","😮","😴","😡","🙏","👍","👎","👏","🙌","👌","✌️","👋","💪","❤️","🧡","💛","💚","💙","💜","💕","💯","✅","❌","❗","❓","🎉","🎂","🎁","⭐","✨","🔥","☀️","☕","🍀","🌸","🏠","🛏️","🧹","🧼"};
    static final class Smile extends Drawable {
        private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
        @Override public void draw(Canvas canvas){Rect b=getBounds();float x=b.exactCenterX(),y=b.exactCenterY(),r=Math.min(b.width(),b.height())*.39f;paint.setColor(0xff93a9c1);paint.setStrokeWidth(Math.max(2,r*.12f));paint.setStyle(Paint.Style.STROKE);canvas.drawCircle(x,y,r,paint);canvas.drawArc(x-r*.5f,y-r*.4f,x+r*.5f,y+r*.6f,20,140,false,paint);paint.setStyle(Paint.Style.FILL);canvas.drawCircle(x-r*.35f,y-r*.2f,r*.085f,paint);canvas.drawCircle(x+r*.35f,y-r*.2f,r*.085f,paint);}
        @Override public void setAlpha(int alpha){paint.setAlpha(alpha);}
        @Override public void setColorFilter(android.graphics.ColorFilter filter){paint.setColorFilter(filter);}
        @Override public int getOpacity(){return android.graphics.PixelFormat.TRANSLUCENT;}
    }
    static final class Symbol extends Drawable {
        private final String symbol;private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
        Symbol(String symbol){this.symbol=symbol;}
        @Override public void draw(Canvas canvas){Rect b=getBounds();canvas.save();canvas.translate(b.left,b.top);canvas.scale(b.width()/24f,b.height()/24f);paint.setColor(BLUE);paint.setStrokeWidth(1.7f);paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);paint.setStyle(Paint.Style.STROKE);Path path=new Path();
            if("photo".equals(symbol)){canvas.drawRoundRect(3,3,21,21,3,3,paint);canvas.drawCircle(8,8,1.5f,paint);path.moveTo(3,17);path.lineTo(8,12);path.lineTo(12,16);path.lineTo(15,13);path.lineTo(21,19);canvas.drawPath(path,paint);}
            else if("search".equals(symbol)){canvas.drawCircle(10.5f,10.5f,7,paint);canvas.drawLine(16,16,21,21,paint);}
            else if("back".equals(symbol)){path.moveTo(15,5);path.lineTo(8,12);path.lineTo(15,19);canvas.drawPath(path,paint);}
            else if("plus".equals(symbol)){canvas.drawLine(12,4,12,20,paint);canvas.drawLine(4,12,20,12,paint);}
            else for(int x:new int[]{4,14})for(int y:new int[]{4,14})canvas.drawRoundRect(x,y,x+6,y+6,1,1,paint);
            canvas.restore();}
        @Override public void setAlpha(int a){paint.setAlpha(a);}@Override public void setColorFilter(ColorFilter f){paint.setColorFilter(f);}@Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
    }
}
