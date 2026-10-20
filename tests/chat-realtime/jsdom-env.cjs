const {webcrypto}=require('node:crypto');const {indexedDB}=require('fake-indexeddb');const fs=require('fs');
module.exports=w=>{w.HTMLMediaElement.prototype.pause=()=>{};Object.defineProperty(w.crypto,'subtle',{value:webcrypto.subtle});w.TextEncoder=TextEncoder;w.indexedDB=indexedDB;w.eval(fs.readFileSync('chat-outbox.js','utf8'));};
