import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash,webcrypto} from 'node:crypto';
import {JSDOM} from 'jsdom';
import * as validation from '../validation.js';

const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const html=readFileSync(new URL('../index.html',import.meta.url),'utf8');
const script=readFileSync(new URL('../src.js',import.meta.url),'utf8').replace(/^import .*;$/gm,'');
function fixture(){
 const app=new Uint8Array(32);app[0]=0xe9;app[12]=5;
 const boot=new Uint8Array(32).fill(0xe9),partitions=new Uint8Array(32).fill(0xaa);
 const update={application:{path:'firmware/test-app.bin',offset:65536,size:app.length,sha256:hash(app)},compatibility:{fromVersion:'0.2.2',bootloader:{offset:0,size:boot.length,sha256:hash(boot)},partitions:{offset:32768,size:partitions.length,sha256:hash(partitions)}}};
 const manifest={version:'0.2.3',core:'3.3.5',builds:['usb','uart'].map(variant=>({variant,chipFamily:'ESP32-C3',parts:[{path:'firmware/test.bin',offset:0,sha256:'a'.repeat(64)}],update:structuredClone(update)}))};
 return{app,boot,partitions,manifest};
}
async function setup({confirm=true,chip='ESP32-C3',badLayout=false,badApp=false}={}){
 const data=fixture(),dom=new JSDOM(html,{url:'https://example.test/install/',runScripts:'outside-only'}),w=dom.window,reads=[],writes=[];let requests=0;
 w.isSecureContext=true;Object.assign(w,validation);w.TextEncoder=TextEncoder;w.TextDecoder=TextDecoder;
 Object.defineProperty(w.crypto,'subtle',{value:webcrypto.subtle});
 Object.defineProperty(w.navigator,'serial',{value:{requestPort:async()=>{requests++;return{};}}});
 w.Transport=class{async disconnect(){}};
 w.ESPLoader=class{
  constructor(){this.chip={CHIP_NAME:chip};}
  async main(){}async getFlashSize(){return 4096;}async after(){}
  async readFlash(offset,size){reads.push({offset,size});const bytes=new Uint8Array(offset===0?data.boot:data.partitions);if(badLayout)bytes[0]^=1;return bytes;}
  async writeFlash(options){writes.push(options);}
 };
 w.SparkMD5={hashBinary:()=>''};w.confirm=()=>confirm;
 w.fetch=async url=>String(url).endsWith('-app.bin')?{ok:true,arrayBuffer:async()=>{const b=new Uint8Array(data.app);if(badApp)b[20]^=1;return b.buffer;}}:{ok:true,json:async()=>data.manifest};
 w.eval(script);const settle=()=>new Promise(r=>setTimeout(r,30));await settle();
 return{w,reads,writes,settle,get requests(){return requests;},close:()=>w.close()};
}
function enableUpgrade(w){const checkbox=w.document.getElementById('updateConsent');checkbox.checked=true;checkbox.dispatchEvent(new w.Event('change'));}

test('upgrade manifest rejects NVS reads, bootloader writes, invalid variants and wrong origin version',()=>{
 const {manifest}=fixture();validation.validateUpdateManifest(manifest,'usb');
 for(const mutate of [u=>u.application.offset=0,u=>u.application.size=0x300001,u=>u.compatibility.fromVersion='0.2.1',u=>u.compatibility.bootloader.size=0x9001,u=>u.compatibility.partitions.offset=0x9000,u=>u.compatibility.partitions.size=4097]){
  const copy=structuredClone(manifest);mutate(copy.builds[0].update);assert.throws(()=>validation.validateUpdateManifest(copy,'usb'));
 }
 assert.throws(()=>validation.validateUpdateManifest(manifest,'usb','ESP32'));
});
test('upgrade requires its own explicit action and preserves configuration ranges',async()=>{
 const x=await setup();try{
  assert.equal(x.requests,0);assert.equal(x.writes.length,0);assert.ok(x.w.document.getElementById('upgrade').disabled);
  enableUpgrade(x.w);assert.equal(x.requests,0);x.w.document.getElementById('upgrade').click();await x.settle();
  assert.equal(x.requests,1);assert.deepEqual(x.reads,[{offset:0,size:32},{offset:32768,size:32}]);
  assert.equal(x.writes.length,1);assert.equal(x.writes[0].eraseAll,false);assert.equal(x.writes[0].fileArray.length,1);assert.equal(x.writes[0].fileArray[0].address,65536);
  assert.match(x.w.document.getElementById('upgradeStatus').textContent,/原配置区域未擦写/);
 }finally{x.close();}
});
test('incompatible flash layout never falls back to eraseAll',async()=>{
 const x=await setup({badLayout:true});try{enableUpgrade(x.w);x.w.document.getElementById('upgrade').click();await x.settle();assert.equal(x.writes.length,0);assert.equal(x.reads.length,1);assert.match(x.w.document.getElementById('upgradeStatus').textContent,/不匹配.*未擦写/);}finally{x.close();}
});
test('bad application digest and wrong physical chip are rejected before writing',async()=>{
 for(const options of [{badApp:true},{chip:'ESP32-S3'}]){const x=await setup(options);try{enableUpgrade(x.w);x.w.document.getElementById('upgrade').click();await x.settle();assert.equal(x.writes.length,0);assert.equal(x.reads.length,0);}finally{x.close();}}
});
test('canceling compatible upgrade never writes flash',async()=>{
 const x=await setup({confirm:false});try{enableUpgrade(x.w);x.w.document.getElementById('upgrade').click();await x.settle();assert.equal(x.writes.length,0);assert.match(x.w.document.getElementById('upgradeStatus').textContent,/已取消升级/);}finally{x.close();}
});
test('all packaged application updates match selected family, size and digest',()=>{
 const manifest=JSON.parse(readFileSync(new URL('../public/firmware/manifest.json',import.meta.url)));
 for(const build of manifest.builds){const update=validation.validateUpdateManifest(manifest,build.variant,build.chipFamily),app=update.application,bytes=new Uint8Array(readFileSync(new URL('../public/'+app.path,import.meta.url)));validation.validateApplication(bytes,build.chipFamily,app.size);assert.equal(hash(bytes),app.sha256);for(const family of Object.keys(validation.families)){if(family!==build.chipFamily)assert.throws(()=>validation.validateApplication(bytes,family,app.size));}}
});
