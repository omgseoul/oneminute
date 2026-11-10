const {JSDOM}=require('jsdom'),fs=require('fs'),assert=require('node:assert/strict');
const w=new JSDOM('',{url:'https://omgworks24.com',runScripts:'outside-only'}).window;
w.eval(fs.readFileSync('staff-chat-client.js','utf8'));
const bytes=Buffer.alloc(2*1048576+237,91),session={accessToken:'fixture'};
let requests=[],cancelAt=-1,malformed=false,controller;
w.omgSupabase={rpc:async(name,args)=>{
 requests.push(args);const part=args.p_data.part_index;
 if(part===cancelAt)controller.abort();
 const data={ok:true,byte_length:bytes.length,part_size:1048576,mime_type:'video/mp4'};
 if(args.p_action==='download_part')Object.assign(data,{part_index:part,chunk:bytes.subarray(part*1048576,Math.min(bytes.length,(part+1)*1048576)-(malformed?1:0)).toString('base64')});
 return {data};
}};
(async()=>{try{
 let progress=[];const blob=await w.StaffChat.download(session,'employee:fixture','message',{onProgress:(n,total)=>progress.push([n,total])});
 assert.equal(blob.size,bytes.length);assert.equal(blob.type,'video/mp4');
 assert.deepEqual(progress.map(x=>x[0]),[0,1048576,2097152,bytes.length]);
 assert(progress.every(x=>x[1]===bytes.length));assert.equal(requests.length,4);
 const read=await new Promise(resolve=>{const r=new w.FileReader();r.onload=()=>resolve(Buffer.from(r.result));r.readAsArrayBuffer(blob);});assert(read.equals(bytes));
 requests=[];controller=new w.AbortController();cancelAt=0;
 await assert.rejects(()=>w.StaffChat.download(session,'peer','id',{signal:controller.signal}),/취소|중지/);
 assert.equal(requests.length,2,'cancel stops all later parts');
 cancelAt=-1;malformed=true;await assert.rejects(()=>w.StaffChat.download(session,'peer','id'),/첨부 파일/);
 console.log('PASS exact bytes and percentages, last partial part, cancellation, malformed part rejection');
}finally{w.close();}})().catch(e=>{console.error(e);process.exitCode=1});
