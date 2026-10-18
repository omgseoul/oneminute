package com.oneminute.guesthousemanager;

import android.content.Context;
import android.graphics.Matrix;
import android.view.*;
import androidx.appcompat.widget.AppCompatImageView;

/** Pinch and double-tap zoom; horizontal swipe changes media only at the original scale. */
final class StaffChatZoomImage extends AppCompatImageView {
    interface Move {void move(int delta);}
    private final Matrix transform=new Matrix();
    private final ScaleGestureDetector scales;
    private final GestureDetector taps;
    private float scale=1,lastX,lastY,downX,downY;
    private final Move move;
    StaffChatZoomImage(Context c,Move move){
        super(c);this.move=move;setScaleType(ScaleType.FIT_CENTER);
        scales=new ScaleGestureDetector(c,new ScaleGestureDetector.SimpleOnScaleGestureListener(){@Override public boolean onScale(ScaleGestureDetector d){float next=Math.max(1,Math.min(5,scale*d.getScaleFactor()));float ratio=next/scale;transform.postScale(ratio,ratio,d.getFocusX(),d.getFocusY());scale=next;setImageMatrix(transform);return true;}});
        taps=new GestureDetector(c,new GestureDetector.SimpleOnGestureListener(){@Override public boolean onDown(MotionEvent e){return true;}@Override public boolean onDoubleTap(MotionEvent e){if(scale>1)reset();else{transform.set(getImageMatrix());setScaleType(ScaleType.MATRIX);transform.postScale(2.5f,2.5f,e.getX(),e.getY());scale=2.5f;setImageMatrix(transform);}return true;}});
    }
    private void reset(){scale=1;setScaleType(ScaleType.FIT_CENTER);}
    @Override public boolean onTouchEvent(MotionEvent e){
        if(e.getActionMasked()==MotionEvent.ACTION_DOWN){downX=lastX=e.getX();downY=lastY=e.getY();transform.set(getImageMatrix());setScaleType(ScaleType.MATRIX);}
        taps.onTouchEvent(e);scales.onTouchEvent(e);
        if(e.getActionMasked()==MotionEvent.ACTION_MOVE&&!scales.isInProgress()&&scale>1&&e.getPointerCount()==1){transform.postTranslate(e.getX()-lastX,e.getY()-lastY);setImageMatrix(transform);}
        if(e.getActionMasked()==MotionEvent.ACTION_UP&&!scales.isInProgress()&&scale==1){float dx=e.getX()-downX,dy=e.getY()-downY;if(Math.abs(dx)>StaffChatUi.dp(getContext(),55)&&Math.abs(dx)>Math.abs(dy)*1.5)move.move(dx<0?1:-1);else performClick();reset();}
        lastX=e.getX();lastY=e.getY();return true;
    }
    @Override public boolean performClick(){super.performClick();return true;}
}
