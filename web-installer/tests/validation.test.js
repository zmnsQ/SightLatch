import {test} from 'node:test';import assert from 'node:assert/strict';import {validateDevice,validateImage,validateManifest} from '../validation.js';
test('rejects other chips and undersized/unknown flash',()=>{for(const x of [['ESP32-S2',4096],['ESP32-C6',4096],['ESP32-C3',2048],['ESP32-C3',undefined]])assert.throws(()=>validateDevice(...x));validateDevice('ESP32-C3',4096)});
test('refuses invalid images and manifests',()=>{assert.throws(()=>validateImage(new Uint8Array(100)));assert.throws(()=>validateManifest({version:'wrong'},'usb'))});
test('validates a merged C3 image and refuses classic ESP32',()=>{const b=new Uint8Array(0x11000);b[0]=b[0x10000]=0xe9;b[12]=b[0x1000c]=5;b[2]=2;b[3]=0x20;b[0x8000]=0xaa;b[0x8001]=0x50;validateImage(b);b[12]=0;assert.throws(()=>validateImage(b))});
test('requires explicit C3 zero-offset checksummed variants',()=>{const m={version:'0.2.3',builds:[{variant:'usb',chipFamily:'ESP32-C3',parts:[{path:'firmware/test.bin',offset:0,sha256:'a'.repeat(64)}]}]};validateManifest(m,'usb');assert.throws(()=>validateManifest(m,'uart'));m.builds[0].parts[0].offset=4096;assert.throws(()=>validateManifest(m,'usb'))});

test('rejects altered app chip high byte, flash parameters and partition header',()=>{const b=new Uint8Array(0x11000);b[0]=b[0x10000]=0xe9;b[12]=b[0x1000c]=5;b[2]=2;b[3]=0x20;b[0x8000]=0xaa;b[0x8001]=0x50;for(const offset of [0x1000d,2,3,0x8000,0x8001]){const copy=b.slice();copy[offset]^=1;assert.throws(()=>validateImage(copy));}});

import {families} from '../validation.js';
test('every family requires matching physical chip and image headers',()=>{for(const [family,spec] of Object.entries(families)){validateDevice(family,4096,family);const b=new Uint8Array(0x11000);for(const offset of [spec.boot,0x10000]){b[offset]=0xe9;b[offset+12]=spec.chip;}b[spec.boot+2]=2;b[spec.boot+3]=spec.header;b[0x8000]=0xaa;b[0x8001]=0x50;validateImage(b,family);for(const other of Object.keys(families)){if(other===family)continue;assert.throws(()=>validateDevice(family,4096,other));assert.throws(()=>validateImage(b,other));}}});
test('classic native USB and duplicate family variant are rejected',()=>{const b={chipFamily:'ESP32',variant:'usb',parts:[{path:'firmware/test.bin',offset:0,sha256:'a'.repeat(64)}]};assert.throws(()=>validateManifest({version:'0.2.3',builds:[b]},'usb','ESP32'));b.variant='uart';validateManifest({version:'0.2.3',builds:[b]},'uart','ESP32');assert.throws(()=>validateManifest({version:'0.2.3',builds:[b,b]},'uart','ESP32'));});

import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
test('packaged images match only their own chip family and recorded digest',()=>{const m=JSON.parse(readFileSync(new URL('../public/firmware/manifest.json',import.meta.url)));for(const build of m.builds){validateManifest(m,build.variant,build.chipFamily);const bytes=new Uint8Array(readFileSync(new URL('../public/'+build.parts[0].path,import.meta.url)));validateImage(bytes,build.chipFamily);assert.equal(createHash('sha256').update(bytes).digest('hex'),build.parts[0].sha256);for(const family of Object.keys(families)){if(family!==build.chipFamily)assert.throws(()=>validateImage(bytes,family));}}});
test('S3 boot parameters and both chip ID bytes are checked',()=>{const b=new Uint8Array(0x11000);b[0]=b[0x10000]=0xe9;b[12]=b[0x1000c]=9;b[2]=2;b[3]=0x2f;b[0x8000]=0xaa;b[0x8001]=0x50;validateImage(b,'ESP32-S3');for(const offset of [12,13,0x1000c,0x1000d,2,3,0x8000,0x8001]){const bad=b.slice();bad[offset]^=1;assert.throws(()=>validateImage(bad,'ESP32-S3'));}});

import {deviceDiagnostics} from '../validation.js';
test('device diagnostics whitelist excludes credentials and non-finite values',()=>{const d=JSON.parse(deviceDiagnostics({boot_id:'a'.repeat(32),uptime_ms:123,reset_reason:4,ble_connected:false,token:'secret',ssid:'private',password:'secret',free_heap_bytes:Infinity}));assert.deepEqual(d,{boot_id:'a'.repeat(32),uptime_ms:123,reset_reason:4,ble_connected:false});assert.deepEqual(JSON.parse(deviceDiagnostics({boot_id:'not-a-boot-id'})),{});});
test('connection diagnostics distinguish admission from authentication without exposing arbitrary strings',()=>{
  const status={ble_stack:'nimble',firmware_source_sha256:'b'.repeat(64),connection_attempts:2,connection_admissions:1,connection_rejects:1,last_connection_rejection:'pairing_window_closed',security_start_events:1,last_security_start_code:0,last_security_start_accepted:true,auth_events:0,hid_connected:false};
  assert.deepEqual(JSON.parse(deviceDiagnostics(status)),status);
  const invalid={ble_stack:'private-device-name',firmware_source_sha256:'secret',last_connection_rejection:'token=secret',connection_attempts:NaN,last_security_start_accepted:'true',password:'private'};
  assert.deepEqual(JSON.parse(deviceDiagnostics(invalid)),{});
});
