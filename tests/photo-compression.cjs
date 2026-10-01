// Tests the shared codec using native canvas decoding/resampling/encoding.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const {createCanvas,loadImage}=require('@napi-rs/canvas'),sharp=require('sharp');
const context={File,Blob,Date,Image:function(){},URL,createImageBitmap:async f=>loadImage(Buffer.from(await f.arrayBuffer())),document:{createElement:()=>{const c=createCanvas(1,1);c.toBlob=(cb,mime,q)=>cb(new Blob([c.encodeSync('jpeg',Math.round(q*100))],{type:mime}));return c;}}};
context.window=context;vm.runInNewContext(fs.readFileSync('photo-codec.js','utf8'),context);
(async()=>{
 const c=createCanvas(3200,2400),ctx=c.getContext('2d'),data=ctx.createImageData(3200,2400);let seed=27;for(let i=0;i<data.data.length;i++){seed=(seed*1664525+1013904223)>>>0;data.data[i]=i%4===3?255:seed>>>24;}ctx.putImageData(data,0,0);
 const original=new File([c.encodeSync('jpeg',95)],'camera.jpg',{type:'image/jpeg'}),result=await context.OMGPhoto.photo(original),meta=await sharp(Buffer.from(await result.arrayBuffer())).metadata();
 assert.equal(result.type,'image/jpeg');assert.ok(result.size<=300*1024);assert.ok(meta.width<=1600&&meta.height<=1600);assert.ok(result.size<original.size/4);
 const small=createCanvas(180,100);const png=new File([small.encodeSync('png')],'small.png',{type:'image/png'}),jpg=await context.OMGPhoto.photo(png),m=await sharp(Buffer.from(await jpg.arrayBuffer())).metadata();assert.equal(m.width,180);assert.equal(m.height,100);
 await assert.rejects(()=>context.OMGPhoto.photo(new File(['bad'],'fake.txt',{type:'text/plain'})));
 console.log(`PASS: noisy camera photo ${(original.size/1048576).toFixed(2)}MB -> ${Math.round(result.size/1024)}KB, ${meta.width}x${meta.height}; small photo never upscaled; non-image rejected`);
})().catch(e=>{console.error(e);process.exit(1)});
