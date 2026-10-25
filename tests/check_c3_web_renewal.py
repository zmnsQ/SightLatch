#!/usr/bin/env python3
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[1];src=root/'firmware/c3-web/IPhoneHIDBridge'
json_include=Path(os.environ.get('ARDUINOJSON_INCLUDE',root/'build/c3-web/toolchain/user/libraries/ArduinoJson/src'))
bridge=(src/'Bridge.cpp').read_text()
def block(a,b): return bridge[bridge.index(a):bridge.index(b)]
parts=block('static bool parseControlRequest(', '// Software control')+block('static void armHandler()', 'static bool validCredentials(')
harness=r'''
#include <string>
#include <array>
#include <atomic>
#include <cassert>
#include <iostream>
#include <ArduinoJson.h>
#include "ProtocolPrimitives.h"
#define SIGHTLATCH_SOFTWARE_CONTROL 1
using String=std::string;using hidpilot::timeBefore;
static uint32_t clockMs=1000;static uint32_t millis(){return clockMs;}
static bool armed=false,calibrationMode=false,renewableSession=false,linkReady=true;
static uint32_t nextRenewalSequence=1,armedUntil=0,nextSequence=1,lastAcceptedAt=0;
static std::atomic<bool> emergency{false};
static String bootId(32,'b'),controlEpoch(32,'e'),sessionId,lastError;
struct Peer{uint32_t epoch=1;};static Peer peer;static Peer peerSnapshot(){return peer;}
static bool usable(){return linkReady;}static bool releaseReports(){return true;}
static constexpr uint32_t ARM_LEASE_MS=300000;
static constexpr int WL_CONNECTED=3,portMAX_DELAY=0;static void* stateLock=nullptr;
static void xSemaphoreTake(void*,int){}static void xSemaphoreGive(void*){}
struct WiFiClass{bool connected=true;int status(){return connected?WL_CONNECTED:0;}}WiFi;
struct Receipt{};static std::array<Receipt,8>receipts;
static String randomId(){return String(32,'s');}
struct HTTP{String body;String arg(const char*){return body;}}http;
static bool allowed=true;static int code=0;static String reason;
static bool authorized(){return allowed;}
static void error(int value,const char* text){code=value;reason=text;}
static void statusHandler(){code=200;}
PRODUCTION
static void reset(){armed=false;calibrationMode=false;renewableSession=false;linkReady=true;nextRenewalSequence=1;
clockMs=1000;emergency=false;peer.epoch=1;WiFi.connected=true;controlEpoch=String(32,'e');bootId=String(32,'b');allowed=true;code=0;}
static void arm(const char* mode="renewable_task"){JsonDocument d;d["boot_id"]=bootId;d["control_epoch"]=controlEpoch;d["mode"]=mode;http.body="";serializeJson(d,http.body);armHandler();}
static JsonDocument request(){JsonDocument d;d["boot_id"]=bootId;d["session_id"]=sessionId;d["control_epoch"]=controlEpoch;d["hid_generation"]=peer.epoch;
d["renewal_sequence"]=nextRenewalSequence;d["issued_at_ms"]=clockMs;d["ttl_ms"]=1500;d["lease_ms"]=30000;return d;}
static void submit(JsonDocument& d){http.body="";serializeJson(d,http.body);code=0;renewHandler();}
int main(){
reset();arm();assert(code==200&&armed&&renewableSession&&armedUntil==31000);const auto session=sessionId;
clockMs=17000;auto d=request();submit(d);assert(code==200&&armedUntil==47000&&nextRenewalSequence==2&&sessionId==session);
const auto oldEnd=armedUntil;submit(d);assert(code==409&&armedUntil==oldEnd); // replay never extends
clockMs=18000;arm();assert(code==200&&armedUntil==oldEnd&&nextRenewalSequence==2); // repeated ARM is not renewal
for(const char* field:{"boot_id","session_id","control_epoch"}){d=request();d[field]=String(32,'x');submit(d);assert(code==409&&armedUntil==oldEnd);}
d=request();d["hid_generation"]=2;submit(d);assert(code==409);d=request();d["extra"]=1;submit(d);assert(code==400);
d=request();d["lease_ms"]=30001;submit(d);assert(code==400);d=request();d["ttl_ms"]=1501;submit(d);assert(code==400);
d=request();d["issued_at_ms"]=clockMs+1;submit(d);assert(code==408);
d=request();d["issued_at_ms"]=clockMs-1500;submit(d);assert(code==408);
d=request();d["lease_ms"]=500;d["issued_at_ms"]=clockMs-500;submit(d);assert(code==408);
for(int which=0;which<6;which++){reset();arm();d=request();if(which==0)armed=false;if(which==1)emergency=true;if(which==2)linkReady=false;if(which==3)WiFi.connected=false;if(which==4)calibrationMode=true;if(which==5)clockMs=armedUntil;submit(d);assert(code==409);}
reset();arm("task");assert(armedUntil==301000&&!renewableSession);d=request();submit(d);assert(code==409);
reset();arm("calibration");assert(armedUntil==61000&&!renewableSession);d=request();submit(d);assert(code==409);
reset();arm();d=request();armed=false;controlEpoch=String(32,'f');submit(d);assert(code==409&&!armed); // STOP cannot revive
reset();clockMs=0xfffff000;arm();clockMs+=15000;d=request();submit(d);assert(code==200&&timeBefore(clockMs,armedUntil)); // millis wrap
std::cout<<"PASS: actual ARM and renewal handlers; same session, one sequence, TTL, no replay/reARM, STOP/expiry/link/mode/generation and wrap guards\n";
}
'''.replace('PRODUCTION',parts)
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'test.cpp';p.write_text(harness);binary=Path(tmp)/'test'
 subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror','-I'+str(src),'-I'+str(json_include),str(p),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
