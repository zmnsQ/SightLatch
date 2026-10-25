#!/usr/bin/env python3
"""Compile actual absolute wire/parser/executor functions with host I/O seams only."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / 'firmware/c3-web/IPhoneHIDBridge'
bridge = (source / 'Bridge.cpp').read_text()
json_include = Path(os.environ.get('ARDUINOJSON_INCLUDE',root/'build/c3-web/toolchain/user/libraries/ArduinoJson/src'))

def between(start, end):
    return bridge[bridge.index(start):bridge.index(end)]

parts = [
    between('enum class Kind {', '#ifndef SIGHTLATCH_SOFTWARE_CONTROL'),
    between('static bool sendAbsoluteMouse(', 'static bool releaseReports()'),
    between('static void finishJob(', 'static void disarm('),
    between('static void stepJob(', 'static void safetyTask('),
    between('static bool boundedInt(', 'static void stopHandler()'),
]
dispatch = between('static bool dispatchReport(', 'static bool sendKeyboard(')
assert dispatch.index('route.epoch!=expectedEpoch') < dispatch.index('hostStage.compare_exchange_strong')
assert 'static constexpr char FIRMWARE_VERSION[]="0.3.3-c3-web"' in bridge
assert 'absolute_pointer_supported' in bridge and 'absolute_probe_supported' in bridge
assert 'd["absolute_hid_x"]=nullptr' in bridge and 'd["hid_generation"]=value.epoch' in bridge
assert 'if(!requestedCalibration&&!pointerKnown())' not in bridge
assert 'if(txFault.load()&&connected.load())bleServer->disconnect(connId.load())' in bridge

harness = r'''
#include <string>
#include <vector>
#include <array>
#include <atomic>
#include <cassert>
#include <iostream>
#include <ArduinoJson.h>
#include "RelativeAbsoluteAdapter.h"
#include "AbsoluteActionPolicy.h"
#include "CalibrationProbePolicy.h"
#include "ProtocolPrimitives.h"
using String=std::string;
using hidpilot::timeBefore;
using hidpilot::asciiKey;
static uint32_t clockMs=1000;
static uint32_t millis(){return clockMs;}
struct Peer {uint16_t handle=7;uint32_t epoch=1;};
static Peer peer;
static Peer peerSnapshot(){return peer;}
static constexpr uint16_t NO_HANDLE=0xffff;
static constexpr uint32_t MAX_TTL=5000,MIN_INTERVAL=50;
static constexpr size_t MAX_BODY=1024,MAX_TEXT=64;
static std::atomic<bool> emergency{false};
static bool armed=true,calibrationMode=false,linkReady=true;
static uint32_t armedUntil=60000,nextSequence=1,lastAcceptedAt=0,pointerEpoch=0;
static String bootId(32,'b'),sessionId(32,'s'),controlEpoch(32,'e');
static String lastId,lastState="none",lastError;
static hidpilot::RelativeAbsoluteAdapter pointer;
static bool usable(){return linkReady&&peer.handle!=NO_HANDLE;}
static bool stopPressed(){return false;}
static bool pointerKnown(){if(pointerEpoch!=peer.epoch)pointer.invalidate();return pointer.known();}
static constexpr int WL_CONNECTED=3;
struct WiFiClass {bool connected=true;int status(){return connected?WL_CONNECTED:0;}} WiFi;
static void* stateLock=nullptr;
static constexpr int portMAX_DELAY=0;
static void xSemaphoreTake(void*,int){}
static void xSemaphoreGive(void*){}
struct FakeHTTP {String body;String arg(const char*){return body;}} http;
static int responseCode=0;
static JsonDocument response;
static bool authorized(){return true;}
static void respond(int code,JsonDocument& value){responseCode=code;response.set(value);}
static void error(int code,const char* reason){responseCode=code;response.clear();response["error"]=reason;}
struct NimBLECharacteristic {};
static NimBLECharacteristic mouseObject,*mouseReport=&mouseObject;
static std::vector<std::array<uint8_t,7>> reports;
static bool notifyOK=true;
static bool poisonDown=false;
static int downFailures=0,releaseAttempts=0;
static bool dispatchReport(NimBLECharacteristic*,const uint8_t* bytes,size_t count,bool releaseOnly=false,uint32_t expectedEpoch=0){
  if(releaseOnly)releaseAttempts++;
  if(!notifyOK||!usable()||(expectedEpoch&&expectedEpoch!=peer.epoch))return false;
  if(poisonDown&&bytes[0]==1){downFailures++;linkReady=false;return false;}
  assert(count==7);std::array<uint8_t,7> value{};std::copy(bytes,bytes+7,value.begin());reports.push_back(value);return true;
}
static int legacyReleases=0;
static bool releaseReports(){legacyReleases++;return true;}
static bool sendMouse(uint8_t=0,int=0,int=0,int=0,bool=false){return true;}
static bool sendKeyboard(uint8_t=0,uint8_t=0){return true;}
PRODUCTION
static void reset(){
  clockMs=1000;peer={7,1};emergency=false;armed=true;calibrationMode=false;linkReady=true;
  armedUntil=60000;nextSequence=1;lastAcceptedAt=0;pointerEpoch=0;pointer.invalidate();notifyOK=true;
  reports.clear();job=Job{};lastId="";lastState="none";lastError="";receiptCursor=0;
  WiFi.connected=true;poisonDown=false;downFailures=0;releaseAttempts=0;
  for(auto& receipt:receipts)receipt=Receipt{};
  legacyReleases=0;responseCode=0;response.clear();
}
static JsonDocument request(const char* type="move_absolute",int x=1234,int y=5678){
  JsonDocument d;d["type"]=type;d["id"]="absolute-action-one";d["boot_id"]=bootId;d["session_id"]=sessionId;
  d["sequence"]=nextSequence;d["issued_at_ms"]=clockMs;d["ttl_ms"]=1500;
  d["control_epoch"]=controlEpoch;d["hid_generation"]=peer.epoch;d["hid_x"]=x;d["hid_y"]=y;return d;
}
static void submit(JsonDocument& d){http.body="";serializeJson(d,http.body);actionHandler();}
static void checkXY(const std::array<uint8_t,7>& r,int x,int y,uint8_t button){
  assert(r[0]==button&&(r[1]|(r[2]<<8))==x&&(r[3]|(r[4]<<8))==y&&r[5]==0&&r[6]==0);
}
int main(){
  // Strict eleven-field contract, including exact integer bounds and generations.
  for(const char* type:{"move_absolute","click_absolute","probe_absolute"}){
    reset();auto d=request(type,0,10000);Job parsed;assert(parseJob(d,parsed));
    assert(parsed.hidX==0&&parsed.hidY==10000&&parsed.hidGeneration==1);
    d["dx"]=nullptr;assert(!parseJob(d,parsed));d.remove("dx");
    d["hid_x"]=-1;assert(!parseJob(d,parsed));d["hid_x"]=10001;assert(!parseJob(d,parsed));
    d["hid_x"]=1.5;assert(!parseJob(d,parsed));d["hid_x"]=1;
    d["hid_generation"]=0;assert(!parseJob(d,parsed));d["hid_generation"]=1;
    d.remove("control_epoch");assert(!parseJob(d,parsed));
  }
  reset();auto d=request();d["control_epoch"]=String(32,'f');submit(d);assert(responseCode==409&&!job.active);
  reset();d=request();d["hid_generation"]=2;submit(d);assert(responseCode==409&&!job.active);
  reset();d=request("probe_absolute");submit(d);assert(responseCode==403&&!job.active);
  reset();calibrationMode=true;d=request("click_absolute");submit(d);assert(responseCode==403&&!job.active);
  reset();d=request("click_absolute");d["ttl_ms"]=799;submit(d);assert(responseCode==408&&!job.active);
  // Current position can be unknown: the explicit target is not a relative delta.
  reset();d=request();submit(d);assert(responseCode==202&&job.active&&!pointer.known());
  const auto body=http.body;stepJob(clockMs);assert(lastState=="completed"&&reports.size()==1);
  checkXY(reports.back(),1234,5678,0);hidpilot::AbsolutePosition known;assert(pointer.read(known)&&known.x==1234&&known.y==5678);
  http.body=body;actionHandler();assert(responseCode==200&&reports.size()==1&&nextSequence==2);
  d["hid_x"]=1235;submit(d);assert(responseCode==409&&reports.size()==1);
  reset();pointer.commit({9000,9000});pointerEpoch=1;d=request("move_absolute",10,20);submit(d);stepJob(clockMs);
  checkXY(reports.back(),10,20,0);assert(legacyReleases==0);
  // Actual click/probe executor: move, release the task lock between ticks, settle, fixed down/up.
  for(const char* type:{"click_absolute","probe_absolute"}){
    reset();calibrationMode=String(type)=="probe_absolute";d=request(type);submit(d);assert(responseCode==202);
    stepJob(clockMs);assert(reports.size()==1&&job.phase==1&&job.stepAt==1350);
    clockMs=1349;stepJob(clockMs);assert(reports.size()==1);
    clockMs=1350;stepJob(clockMs);assert(reports.size()==2&&job.absoluteMayBeDown&&job.stepAt==1390);
    clockMs=1389;stepJob(clockMs);assert(reports.size()==2);
    clockMs=1390;stepJob(clockMs);assert(reports.size()==3&&!job.active&&lastState=="completed");
    for(size_t i=0;i<reports.size();i++)checkXY(reports[i],1234,5678,i==1?1:0);
    assert(legacyReleases==0&&pointerEpoch==1);
  }
  // STOP before down cannot create an extra mouse movement or click.
  reset();d=request("click_absolute");submit(d);finishJob("aborted","test_stop");assert(reports.empty());
  reset();d=request("click_absolute");submit(d);stepJob(clockMs);emergency=true;finishJob("aborted","test_stop");assert(reports.size()==1);
  reset();d=request("click_absolute");submit(d);stepJob(clockMs);clockMs=1350;stepJob(clockMs);
  emergency=true;finishJob("aborted","test_stop");assert(reports.size()==3);checkXY(reports.back(),1234,5678,0);
  // A stale job must never release or click on a replacement connection generation.
  reset();d=request("click_absolute");submit(d);stepJob(clockMs);clockMs=1350;stepJob(clockMs);
  peer={8,2};clockMs=1390;stepJob(clockMs);assert(reports.size()==2&&!job.active&&lastState=="aborted");
  finishJob("aborted","late_stop");assert(reports.size()==2&&legacyReleases==0);
  reset();d=request("click_absolute");submit(d);stepJob(clockMs);controlEpoch=String(32,'f');clockMs=1350;stepJob(clockMs);
  assert(reports.size()==1&&lastState=="aborted");controlEpoch=String(32,'e');
  reset();d=request("click_absolute");submit(d);stepJob(clockMs);armedUntil=1349;clockMs=1350;stepJob(clockMs);
  assert(reports.size()==1&&lastState=="aborted");
  reset();d=request("click_absolute");submit(d);stepJob(clockMs);clockMs=1350;stepJob(clockMs);
  clockMs=2501;stepJob(clockMs);assert(reports.size()==3&&lastState=="aborted");checkXY(reports.back(),1234,5678,0);
  reset();d=request("click_absolute");submit(d);stepJob(clockMs);clockMs=1350;stepJob(clockMs);
  armedUntil=1389;clockMs=1390;stepJob(clockMs);assert(reports.size()==3&&lastState=="aborted");
  reset();d=request("click_absolute");submit(d);stepJob(clockMs);poisonDown=true;clockMs=1350;stepJob(clockMs);
  assert(downFailures==1&&releaseAttempts==1&&reports.size()==1&&lastState=="aborted");
  // The old transport poisons uncertain routes; attempted up cannot be claimed as successful.
  assert(!linkReady&&job.absoluteMayBeDown);peer={8,2};finishJob("aborted","new_connection");assert(releaseAttempts==1&&reports.size()==1);
  reset();d=request("click_absolute");submit(d);stepJob(clockMs);notifyOK=false;clockMs=1350;stepJob(clockMs);
  assert(lastState=="aborted"&&reports.size()==1);
  std::cout<<"PASS: actual absolute parser/action envelope/idempotency/executor, direct HID values, fixed settle/down/up, STOP and generation-safe release; local ATT seams only, no UI success assumed\n";
}
'''.replace('PRODUCTION','\n'.join(parts))

with tempfile.TemporaryDirectory() as temp:
    cpp=Path(temp)/'absolute.cpp';cpp.write_text(harness)
    binary=Path(temp)/'absolute'
    subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror',
                    '-I'+str(source),'-I'+str(json_include),str(cpp),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
