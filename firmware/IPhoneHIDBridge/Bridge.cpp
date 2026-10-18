/* SightLatch BLE bridge. Hardware behavior requires board/iPhone verification.
 * Targets: ESP32-C3 (official NimBLE), ESP32-S3 (Bluedroid), Arduino-ESP32 3.3.5.
 * HTTP is plaintext: isolated trusted LAN only. See ../README.md.
 * No external BLE keyboard/mouse library and no cloud server required.
 */
#include <Arduino.h>
#include <WiFi.h>
#include <ESPmDNS.h>
#include <WebServer.h>
#include <ArduinoJson.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEHIDDevice.h>
#include <BLESecurity.h>
#include <BLE2902.h>
#include <esp_system.h>
#include <atomic>
#include <Preferences.h>
#include "ProtocolPrimitives.h"
using hidpilot::timeBefore;
using hidpilot::asciiKey;
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#if __has_include("config.h")
#include "config.h"
#else
#include "config.default.h"
#endif
#if (!defined(CONFIG_IDF_TARGET_ESP32S3) && !defined(CONFIG_IDF_TARGET_ESP32C3)) || (!defined(CONFIG_BLUEDROID_ENABLED) && !defined(CONFIG_NIMBLE_ENABLED))
#error "Supported targets: ESP32-C3 / ESP32-S3 with official BLE stack."
#endif

static constexpr uint32_t MAX_TTL = 5000, MIN_INTERVAL = 50;
static constexpr size_t MAX_BODY = 1024, MAX_TEXT = 64;
static WebServer http(80);
static BLEServer *bleServer;
static BLECharacteristic *keyboardReport, *mouseReport;
static SemaphoreHandle_t stateLock;
static std::atomic<bool> connected{false}, encrypted{false}, emergency{false};
static std::atomic<uint32_t> pairUntil{0};
static std::atomic<uint16_t> connId{0xffff};
// Read/written only on the serialized Bluedroid callback task.
static uint8_t targetAddress[6] = {0};
static String bootId, sessionId, controlEpoch;
static bool armed = false;
static uint32_t armedUntil = 0, nextSequence = 1, lastAcceptedAt = 0;
static String lastId, lastState = "none", lastError;

// One keyboard report (8 bytes) and one relative mouse report (4 bytes).
// These describe standard HID usages, not absolute touch contacts.
static uint8_t reportMap[] = {
  0x05,0x01, 0x09,0x06, 0xA1,0x01, 0x85,0x01,
  0x05,0x07, 0x19,0xE0, 0x29,0xE7, 0x15,0x00, 0x25,0x01,
  0x75,0x01, 0x95,0x08, 0x81,0x02,
  0x75,0x08, 0x95,0x01, 0x81,0x01,
  0x19,0x00, 0x29,0x65, 0x15,0x00, 0x25,0x65,
  0x75,0x08, 0x95,0x06, 0x81,0x00, 0xC0,
  0x05,0x01, 0x09,0x02, 0xA1,0x01, 0x85,0x02,
  0x09,0x01, 0xA1,0x00,
  0x05,0x09, 0x19,0x01, 0x29,0x03, 0x15,0x00, 0x25,0x01,
  0x75,0x01, 0x95,0x03, 0x81,0x02,
  0x75,0x05, 0x95,0x01, 0x81,0x01,
  0x05,0x01, 0x09,0x30, 0x09,0x31, 0x09,0x38,
  0x15,0x81, 0x25,0x7F, 0x75,0x08, 0x95,0x03, 0x81,0x06,
  0xC0,0xC0
};

enum class Kind { Move, Click, Scroll, Key, Text, Drag, Release };
struct Job {
  bool active = false;
  Kind kind = Kind::Release;
  String id, text;
  int dx=0, dy=0, wheel=0, button=1, key=0, modifiers=0;
  uint32_t issued=0, ttl=0, duration=0, stepAt=0;
  unsigned phase=0, index=0, steps=0;
  int sentX=0, sentY=0;
};
static Job job;
struct Receipt { String id, body, state; uint32_t sequence=0; };
static Receipt receipts[16];
static unsigned receiptCursor = 0;
#ifndef SIGHTLATCH_SOFTWARE_CONTROL
#define SIGHTLATCH_SOFTWARE_CONTROL 0
#endif
#if !SIGHTLATCH_SOFTWARE_CONTROL
static_assert(STOP_GPIO != ARM_GPIO, "Use two distinct external button GPIOs");
#endif
static bool stopPressed() {
#if SIGHTLATCH_SOFTWARE_CONTROL
  return false;
#else
  return digitalRead(STOP_GPIO)==LOW;
#endif
}
static bool armPressed() {
#if SIGHTLATCH_SOFTWARE_CONTROL
  return false;
#else
  return digitalRead(ARM_GPIO)==LOW;
#endif
}
static String wifiSSID=WIFI_SSID, wifiPassword=WIFI_PASSWORD, controlToken=CONTROL_TOKEN;
static Preferences preferences;
static bool bridgeReady=false;
static String serialLine;
static bool serialOverflow=false;


static String randomId() {
  char b[33];
  snprintf(b,sizeof(b),"%08lx%08lx%08lx%08lx",(unsigned long)esp_random(),
    (unsigned long)esp_random(),(unsigned long)esp_random(),(unsigned long)esp_random());
  return String(b);
}
static bool pairingOpen() {
  uint32_t until=pairUntil.load();
  return until!=0 && timeBefore(millis(),until);
}
static bool usable() { return connected.load() && encrypted.load(); }
static void sendKeyboard(uint8_t key=0, uint8_t modifiers=0) {
  if(!usable()) return;
  uint8_t bytes[8]={modifiers,0,key,0,0,0,0,0};
  keyboardReport->setValue(bytes,sizeof(bytes)); keyboardReport->notify();
}
static void sendMouse(uint8_t buttons=0,int dx=0,int dy=0,int wheel=0) {
  if(!usable()) return;
  uint8_t bytes[4]={buttons,(uint8_t)(int8_t)dx,(uint8_t)(int8_t)dy,(uint8_t)(int8_t)wheel};
  mouseReport->setValue(bytes,sizeof(bytes)); mouseReport->notify();
}
static void releaseReports() { sendKeyboard(); sendMouse(); }
// Called only under stateLock; BLE callbacks only update atomic flags.
static void finishJob(const char *state,const char *reason="") {
  releaseReports();
  if(job.active) {
    lastId=job.id; lastState=state;
    for(auto &r:receipts) if(r.id==job.id) r.state=state;
  }
  job.active=false; job.text=""; lastError=reason;
}
static void disarm(const char *reason) {
  finishJob("aborted",reason); armed=false; sessionId=""; nextSequence=1;controlEpoch=randomId();
}

class ServerCallbacks final : public BLEServerCallbacks {
#if defined(CONFIG_BLUEDROID_ENABLED)
  void onConnect(BLEServer *server,esp_ble_gatts_cb_param_t *p) override {
    if(!pairingOpen() || connected.exchange(true)) { server->disconnect(p->connect.conn_id); return; }
    connId.store(p->connect.conn_id); encrypted.store(false);
    memcpy(targetAddress,p->connect.remote_bda,sizeof(targetAddress));
    server->getAdvertising()->stop();
    // Encryption requested with SC; NoInputNoOutput is NOT MITM-resistant.
    esp_ble_set_encryption(p->connect.remote_bda,ESP_BLE_SEC_ENCRYPT);
  }
  void onDisconnect(BLEServer *,esp_ble_gatts_cb_param_t *p) override {
    if(p->disconnect.conn_id!=connId.load()) return;
    encrypted.store(false); connected.store(false); connId.store(0xffff);
    emergency.store(true); pairUntil.store(0);
    // Deliberately do not auto-advertise/re-arm after loss of target.
  }
#else
  void onConnect(BLEServer *server,ble_gap_conn_desc *p) override {
    if(!pairingOpen()||connected.exchange(true)){server->disconnect(p->conn_handle);return;}
    connId.store(p->conn_handle);encrypted.store(false);
    server->getAdvertising()->stop();
    BLESecurity::startSecurity(p->conn_handle);
  }
  void onDisconnect(BLEServer *,ble_gap_conn_desc *p) override {
    if(p->conn_handle!=connId.load())return;
    encrypted.store(false);connected.store(false);connId.store(0xffff);
    emergency.store(true);pairUntil.store(0);
  }
#endif
};
class SecurityCallbacks final : public BLESecurityCallbacks {
  uint32_t onPassKeyRequest() override { return 0; }
  void onPassKeyNotify(uint32_t) override {}
  bool onSecurityRequest() override { return pairingOpen(); }
  bool onConfirmPIN(uint32_t) override { return false; }
  #if defined(CONFIG_BLUEDROID_ENABLED)
  void onAuthenticationComplete(esp_ble_auth_cmpl_t result) override {
    if(memcmp(targetAddress,result.bd_addr,sizeof(targetAddress))!=0) return;
    bool ok=result.success && connected.load() && pairingOpen() &&
      (result.auth_mode & ESP_LE_AUTH_REQ_SC_ONLY);
    encrypted.store(ok);
    if(ok) pairUntil.store(0);
    else { emergency.store(true); if(connId.load()!=0xffff) bleServer->disconnect(connId.load()); }
  }
#else
  void onAuthenticationComplete(ble_gap_conn_desc *p) override {
    if(!p||p->conn_handle!=connId.load())return;
    // SC-only is enforced in ble_hs_cfg; Just Works is deliberately not MITM-authenticated.
    bool ok=p->sec_state.encrypted&&p->sec_state.key_size==16&&connected.load()&&pairingOpen();
    encrypted.store(ok);
    if(ok)pairUntil.store(0);
    else {emergency.store(true);bleServer->disconnect(p->conn_handle);}
  }
#endif
};

// US keyboard layout only. Chinese/UTF-8 must be rejected, never silently mangled.
// No delays while holding a key: each tick performs at most one small HID step.
static void stepJob(uint32_t now) {
  if(!job.active || timeBefore(now,job.stepAt)) return;
  if((int32_t)(now-job.issued)>(int32_t)job.ttl) {finishJob("aborted","expired_during_execution");return;}
  lastState="running";
  if(job.kind==Kind::Move) {sendMouse(0,job.dx,job.dy);finishJob("completed");return;}
  if(job.kind==Kind::Scroll) {sendMouse(0,0,0,job.wheel);finishJob("completed");return;}
  if(job.kind==Kind::Release) {finishJob("completed");return;}
  if(job.kind==Kind::Click || job.kind==Kind::Key) {
    if(job.phase++==0) {
      if(job.kind==Kind::Click) sendMouse(job.button);
      else sendKeyboard(job.key,job.modifiers);
      job.stepAt=now+40;
    } else finishJob("completed");
    return;
  }
  if(job.kind==Kind::Text) {
    if(job.index>=job.text.length()) {finishJob("completed");return;}
    if(job.phase==0) {
      uint8_t key,mods; asciiKey(job.text[job.index],key,mods);
      sendKeyboard(key,mods); job.phase=1;
    } else {sendKeyboard();job.phase=0;job.index++;}
    job.stepAt=now+25;return;
  }
  if(job.kind==Kind::Drag) {
    if(job.phase++==0) {sendMouse(job.button);job.stepAt=now+20;return;}
    if(job.index>=job.steps) {finishJob("completed");return;}
    job.index++;
    int tx=job.dx*(int)job.index/(int)job.steps;
    int ty=job.dy*(int)job.index/(int)job.steps;
    sendMouse(job.button,tx-job.sentX,ty-job.sentY);
    job.sentX=tx;job.sentY=ty;job.stepAt=now+20;
  }
}

static void safetyTask(void *) {
  bool armWasDown=false, longHandled=false;
  uint32_t armDownAt=0;
  for(;;) {
    const uint32_t now=millis();
    bool stopDown=stopPressed();
    bool armDown=armPressed();
    if(stopDown) emergency.store(true);
    xSemaphoreTake(stateLock,portMAX_DELAY);
    if(emergency.exchange(false)) {
      disarm("stopped_or_ble_lost");pairUntil.store(0);bleServer->getAdvertising()->stop();
    }
    if(armed && (!usable() || WiFi.status()!=WL_CONNECTED || !timeBefore(now,armedUntil)))
      disarm("link_or_arm_lease_lost");
    if(armDown && !armWasDown) {armDownAt=now;longHandled=false;}
    if(armDown && !longHandled && (uint32_t)(now-armDownAt)>=2000) {
      longHandled=true;disarm("pairing_window");
      // Pair only with no existing connection; disconnect explicitly first.
      if(connected.load()) bleServer->disconnect(connId.load());
      else {pairUntil.store(now+PAIR_WINDOW_MS);bleServer->getAdvertising()->start();}
    }
    if(!armDown && armWasDown && !longHandled && (uint32_t)(now-armDownAt)>=60 && !stopDown) {
      if(armed) disarm("physical_disarm");
      else if(usable() && WiFi.status()==WL_CONNECTED) {
        releaseReports(); armed=true;armedUntil=now+ARM_LEASE_MS;
        sessionId=randomId();nextSequence=1;lastAcceptedAt=0;lastError="";
        for(auto &r:receipts) r=Receipt{};
      }
    }
    armWasDown=armDown;
    uint32_t until=pairUntil.load();
    if(until && !timeBefore(now,until)) {
      pairUntil.store(0);bleServer->getAdvertising()->stop();
      if(connected.load()&&!encrypted.load()) bleServer->disconnect(connId.load());
    }
    if(armed && !stopDown) stepJob(now);
    xSemaphoreGive(stateLock);
    vTaskDelay(pdMS_TO_TICKS(10));
  }
}

static void respond(int code,JsonDocument &doc) {
  String body;serializeJson(doc,body);http.sendHeader("Cache-Control","no-store");
  http.send(code,"application/json",body);
}
static void error(int code,const char *message) {
  JsonDocument d;d["ok"]=false;d["error"]=message;respond(code,d);
}
static bool authorized() {
  const String candidate=http.header("Authorization");
  const String expected=String("Bearer ")+controlToken;
  if(candidate.length()!=expected.length()) {error(401,"unauthorized");return false;}
  uint8_t difference=0;
  for(size_t i=0;i<expected.length();i++) difference|=(uint8_t)(candidate[i]^expected[i]);
  if(difference) {error(401,"unauthorized");return false;}
  return true;
}
static void statusHandler() {
  if(!authorized()) return;
  JsonDocument d;
  xSemaphoreTake(stateLock,portMAX_DELAY);
  d["ok"]=true;d["boot_id"]=bootId;d["control_epoch"]=controlEpoch;d["uptime_ms"]=millis();
  d["armed"]=armed;d["hid_connected"]=usable();d["ble_connected"]=connected.load();
  d["session_id"]=sessionId;d["next_sequence"]=nextSequence;d["max_ttl_ms"]=MAX_TTL;
  d["busy"]=job.active;d["last_action_id"]=lastId;d["last_action_state"]=lastState;
  d["last_error"]=lastError;d["pairing_open"]=pairingOpen();
  d["control_mode"]=SIGHTLATCH_SOFTWARE_CONTROL?"software":"physical";
  d["firmware_version"]="0.2.0-c3";
  d["transport_security"]="plaintext_http_trusted_lan_only";
  xSemaphoreGive(stateLock);respond(200,d);
}
static bool boundedInt(JsonVariantConst value,int min,int max,int &out) {
  if(!value.is<int>()) return false;
  int n=value.as<int>();if(n<min||n>max)return false;out=n;return true;
}
static bool parseJob(JsonDocument &d,Job &j) {
  String type=d["type"]|"";
  if(type=="move") j.kind=Kind::Move;
  else if(type=="click") j.kind=Kind::Click;
  else if(type=="scroll") j.kind=Kind::Scroll;
  else if(type=="key") j.kind=Kind::Key;
  else if(type=="text") j.kind=Kind::Text;
  else if(type=="drag") j.kind=Kind::Drag;
  else if(type=="release_all") j.kind=Kind::Release;
  else return false;
  if(j.kind==Kind::Move||j.kind==Kind::Drag)
    if(!boundedInt(d["dx"],-127,127,j.dx)||!boundedInt(d["dy"],-127,127,j.dy))return false;
  if(j.kind==Kind::Click||j.kind==Kind::Drag) {
    if(!boundedInt(d["button"],1,4,j.button)||(j.button!=1&&j.button!=2&&j.button!=4))return false;
  }
  if(j.kind==Kind::Scroll && !boundedInt(d["wheel"],-127,127,j.wheel))return false;
  if(j.kind==Kind::Key) {
    if(!boundedInt(d["key"],4,101,j.key))return false;
    if(!d["modifiers"].isNull()&&!boundedInt(d["modifiers"],0,255,j.modifiers))return false;
  }
  if(j.kind==Kind::Text) {
    if(!d["text"].is<const char *>())return false;
    j.text=d["text"].as<String>();
    if(j.text.length()==0||j.text.length()>MAX_TEXT)return false;
    for(size_t i=0;i<j.text.length();i++) {uint8_t key,mods;if(!asciiKey(j.text[i],key,mods))return false;}
  }
  if(j.kind==Kind::Drag) {
    int duration;if(!boundedInt(d["duration_ms"],100,1000,duration))return false;
    j.duration=duration;j.steps=(duration+19)/20;
  }
  return true;
}

static void actionHandler() {
  if(!authorized())return;
  String body=http.arg("plain");
  if(body.length()==0||body.length()>MAX_BODY){error(413,"body_size");return;}
  JsonDocument d;
  if(deserializeJson(d,body) || !d.is<JsonObject>()){error(400,"invalid_json");return;}
  if(!d["id"].is<const char *>()||!d["session_id"].is<const char *>()||
     !d["boot_id"].is<const char *>()||!d["sequence"].is<uint32_t>()||
     !d["issued_at_ms"].is<uint32_t>()||!d["ttl_ms"].is<uint32_t>()) {
    error(400,"missing_envelope");return;
  }
  String id=d["id"].as<String>();
  if(id.length()<8||id.length()>64){error(400,"invalid_id");return;}
  Job candidate;
  if(!parseJob(d,candidate)){error(400,"invalid_action_or_non_ascii");return;}
  uint32_t sequence=d["sequence"],issued=d["issued_at_ms"],ttl=d["ttl_ms"];
  if(ttl==0||ttl>MAX_TTL||sequence==0||sequence==UINT32_MAX){error(400,"invalid_envelope");return;}
  JsonDocument result;int code=202;const char *failure=nullptr;
  xSemaphoreTake(stateLock,portMAX_DELAY);
  const uint32_t now=millis();
  if(!armed||emergency.load()||stopPressed()) {code=423;failure="not_armed";}
  else if(d["boot_id"].as<String>()!=bootId||d["session_id"].as<String>()!=sessionId)
    {code=409;failure="session_mismatch";}
  else {
    Receipt *duplicate=nullptr;
    for(auto &r:receipts) if(r.id==id){duplicate=&r;break;}
    if(duplicate) {
      if(duplicate->sequence!=sequence||duplicate->body!=body){code=409;failure="id_payload_conflict";}
      else {code=200;result["duplicate"]=true;result["state"]=duplicate->state;}
    } else if(sequence!=nextSequence){code=409;failure="sequence_mismatch";}
    else if((int32_t)(now-issued)<-250 || (int32_t)(now-issued)>(int32_t)ttl)
      {code=408;failure="expired_or_future";}
    else if(!usable()||WiFi.status()!=WL_CONNECTED){code=503;failure="hid_or_wifi_unavailable";}
    else if(job.active){code=409;failure="busy";}
    else if(lastAcceptedAt && (uint32_t)(now-lastAcceptedAt)<MIN_INTERVAL){code=429;failure="rate_limited";}
    else {
      // Reserve enough remaining TTL for the bounded action to finish.
      uint32_t required=candidate.kind==Kind::Text?candidate.text.length()*50+100:
        candidate.kind==Kind::Drag?candidate.duration+100:100;
      int32_t age=(int32_t)(now-issued);if(age<0)age=0;
      if(required>ttl-(uint32_t)age){code=408;failure="insufficient_ttl_for_action";}
      else {
        candidate.id=id;candidate.active=true;candidate.issued=issued;candidate.ttl=ttl;candidate.stepAt=now;
        job=candidate;nextSequence++;lastAcceptedAt=now;lastId=id;lastState="queued";lastError="";
        Receipt &r=receipts[receiptCursor++%16];r.id=id;r.body=body;r.sequence=sequence;r.state="queued";
        result["duplicate"]=false;result["state"]="queued";
      }
    }
  }
  if(failure){result["ok"]=false;result["error"]=failure;}
  else {result["ok"]=true;result["id"]=id;result["accepted"]=true;}
  result["next_sequence"]=nextSequence;
  xSemaphoreGive(stateLock);respond(code,result);
}
static void stopHandler() {
  if(!authorized())return;
  // Invalidate already-issued ARM/PAIR requests synchronously before acknowledging STOP.
  xSemaphoreTake(stateLock,portMAX_DELAY);
  controlEpoch=randomId();emergency.store(true);
  xSemaphoreGive(stateLock);
  // Safety task handles release even if the HTTP connection disappears.
  JsonDocument d;d["ok"]=true;d["stop_requested"]=true;respond(202,d);
}

// A request may only authorize the exact control generation the user observed.
static bool parseControlRequest(String &expectedBoot,String &expectedEpoch) {
  String body=http.arg("plain");JsonDocument d;
  if(body.length()>256||deserializeJson(d,body)||!d["boot_id"].is<String>()||!d["control_epoch"].is<String>()) {
    error(400,"invalid_control_request");return false;
  }
  expectedBoot=d["boot_id"].as<String>();expectedEpoch=d["control_epoch"].as<String>();
  if(expectedBoot.length()!=32||expectedEpoch.length()!=32){error(400,"invalid_control_request");return false;}
  return true;
}
// Software control is opt-in by build; legacy externally wired builds keep physical gates.
static void pairHandler() {
  if(!authorized()) return;
#if SIGHTLATCH_SOFTWARE_CONTROL
  String expectedBoot,expectedEpoch;
  if(!parseControlRequest(expectedBoot,expectedEpoch))return;
  xSemaphoreTake(stateLock,portMAX_DELAY);
  if(expectedBoot!=bootId||expectedEpoch!=controlEpoch) {
    xSemaphoreGive(stateLock);error(409,"control_epoch_mismatch");return;
  }
  if(emergency.load()) {xSemaphoreGive(stateLock);error(409,"stop_pending");return;}
  if(connected.load()) { xSemaphoreGive(stateLock);error(409,"already_connected");return; }
  disarm("pairing_window");pairUntil.store(millis()+PAIR_WINDOW_MS);
  if(!bleServer->getAdvertising()->start()){pairUntil.store(0);xSemaphoreGive(stateLock);error(503,"advertising_failed");return;}
  xSemaphoreGive(stateLock);
  JsonDocument d;d["ok"]=true;d["pairing_open"]=true;d["boot_id"]=bootId;
  xSemaphoreTake(stateLock,portMAX_DELAY);d["control_epoch"]=controlEpoch;xSemaphoreGive(stateLock);respond(200,d);
#else
  error(403,"physical_control_required");
#endif
}
static void armHandler() {
  if(!authorized()) return;
#if SIGHTLATCH_SOFTWARE_CONTROL
  String expectedBoot,expectedEpoch;
  if(!parseControlRequest(expectedBoot,expectedEpoch))return;
  xSemaphoreTake(stateLock,portMAX_DELAY);
  if(expectedBoot!=bootId||expectedEpoch!=controlEpoch) {
    xSemaphoreGive(stateLock);error(409,"control_epoch_mismatch");return;
  }
  if(emergency.load()||!usable()||WiFi.status()!=WL_CONNECTED) {
    xSemaphoreGive(stateLock);error(409,"hid_or_wifi_unavailable");return;
  }
  // An accidental retry must not extend the lease or change an active session.
  if(!armed) {
    releaseReports();armed=true;armedUntil=millis()+ARM_LEASE_MS;
    sessionId=randomId();nextSequence=1;lastAcceptedAt=0;lastError="";
    for(auto &r:receipts) r=Receipt{};
  }
  xSemaphoreGive(stateLock);statusHandler();
#else
  error(403,"physical_control_required");
#endif
}
static bool validCredentials(const String &ssid,const String &password,const String &token) {
  if(ssid.length()==0||ssid.length()>32||ssid.startsWith("YOUR_")||password.length()>63||
     token.length()<32||token.length()>128||token.startsWith("REPLACE_")) return false;
  for(size_t i=0;i<token.length();i++) if(token[i]<33||token[i]>126)return false;
  return true;
}
// Local USB serial only. Never echo credentials; no network provisioning endpoint.
static void serialProvision() {
  while(Serial.available()) {
    char c=Serial.read();
    if(c=='\r')continue;
    if(c!='\n') {
      if(serialLine.length()<768&&!serialOverflow)serialLine+=c;
      else {serialOverflow=true;serialLine="";}
      continue;
    }
    if(serialOverflow){Serial.println("{\"ok\":false,\"error\":\"line_too_long\"}");serialOverflow=false;continue;}
    JsonDocument d;
    bool parsed=!deserializeJson(d,serialLine);serialLine="";
    if(!parsed){Serial.println("{\"ok\":false,\"error\":\"invalid_json\"}");continue;}
    String command=d["command"]|"";
    if(command=="status") {
      JsonDocument response;response["ok"]=true;response["configured"]=bridgeReady;
      response["firmware_version"]="0.2.0-c3";response["ip"]=WiFi.localIP().toString();
      serializeJson(response,Serial);Serial.println();continue;
    }
    if(command!="configure" || !d["ssid"].is<String>() || !d["password"].is<String>() || !d["token"].is<String>() ||
       !validCredentials(d["ssid"].as<String>(),d["password"].as<String>(),d["token"].as<String>())) {
      Serial.println("{\"ok\":false,\"error\":\"invalid_configuration\"}");continue;
    }
    if(bridgeReady) {emergency.store(true);delay(30);}
    // One JSON record prevents partially updated credentials after interrupted writes.
    String record;serializeJson(d,record);
    bool saved=preferences.putString("config",record)==record.length();
    record="";
    if(saved){Serial.println("{\"ok\":true,\"configured\":true,\"restarting\":true}");Serial.flush();delay(200);ESP.restart();}
    else Serial.println("{\"ok\":false,\"error\":\"storage_failed\"}");
  }
}

void setup() {
  Serial.begin(115200);
#if !SIGHTLATCH_SOFTWARE_CONTROL
  pinMode(STOP_GPIO,INPUT_PULLUP);pinMode(ARM_GPIO,INPUT_PULLUP);
#endif
  preferences.begin("sightlatch",false);
  JsonDocument stored;
  if(!deserializeJson(stored,preferences.getString("config",""))) {
    wifiSSID=stored["ssid"].as<String>();wifiPassword=stored["password"].as<String>();controlToken=stored["token"].as<String>();
  }
  if(!validCredentials(wifiSSID,wifiPassword,controlToken)) {
    Serial.println("SightLatch unconfigured. Use USB serial configuration. HID disabled.");
    return;
  }
  stateLock=xSemaphoreCreateMutex();
  if(!stateLock){Serial.println("No mutex; halted.");for(;;)delay(1000);}
  bootId=randomId();controlEpoch=randomId();
  BLEDevice::init(BLE_DEVICE_NAME);
  bleServer=BLEDevice::createServer();bleServer->setCallbacks(new ServerCallbacks());
  bleServer->advertiseOnDisconnect(false);
  BLEDevice::setSecurityCallbacks(new SecurityCallbacks());
  BLESecurity *security=new BLESecurity();
  security->setAuthenticationMode(ESP_LE_AUTH_REQ_SC_BOND);
#if defined(CONFIG_NIMBLE_ENABLED)
  ble_hs_cfg.sm_sc_only=1; // Refuse legacy pairing, preserve the original SC boundary.
#endif
  security->setCapability(ESP_IO_CAP_NONE);
  security->setKeySize(16);
  security->setInitEncryptionKey(ESP_BLE_ENC_KEY_MASK|ESP_BLE_ID_KEY_MASK);
  security->setRespEncryptionKey(ESP_BLE_ENC_KEY_MASK|ESP_BLE_ID_KEY_MASK);
  auto *hid=new BLEHIDDevice(bleServer);
  keyboardReport=hid->inputReport(1);mouseReport=hid->inputReport(2);
  hid->manufacturer()->setValue("Local prototype");
  // Development placeholder IDs only; do not claim another vendor's identity.
  hid->pnp(0x02,0x0000,0x0000,0x0001);hid->hidInfo(0,1);
  hid->reportMap(reportMap,sizeof(reportMap));hid->startServices();hid->setBatteryLevel(100);
  auto *adv=bleServer->getAdvertising();adv->setAppearance(HID_MOUSE);
  adv->addServiceUUID(hid->hidService()->getUUID());adv->setScanResponse(true);
  // No advertising until an explicit authenticated software request or physical long press.
  if(xTaskCreatePinnedToCore(safetyTask,"hid-safety",8192,nullptr,3,nullptr,tskNO_AFFINITY)!=pdPASS) {
    Serial.println("Safety task failed; halted.");for(;;)delay(1000);
  }
  WiFi.mode(WIFI_STA);WiFi.setAutoReconnect(true);WiFi.begin(wifiSSID.c_str(),wifiPassword.c_str());
  const char *headers[]={"Authorization"};http.collectHeaders(headers,1);
  http.on("/v1/status",HTTP_GET,statusHandler);
  http.on("/v1/action",HTTP_POST,actionHandler);
  http.on("/v1/stop",HTTP_POST,stopHandler);
  http.on("/v1/pair",HTTP_POST,pairHandler);
  http.on("/v1/arm",HTTP_POST,armHandler);
  http.onNotFound([](){error(404,"not_found");});http.begin();
  bridgeReady=true;
  Serial.println("SightLatch started DISARMED. Explicit pairing and ARM required.");
}
void loop() {
  serialProvision();
  if(!bridgeReady){delay(5);return;}
  static bool printed=false;
  if(WiFi.status()==WL_CONNECTED&&!printed){
    Serial.print("Local IP: ");Serial.println(WiFi.localIP());
    if(MDNS.begin("hidbridge"))MDNS.addService("http","tcp",80);
    printed=true;
  }
  if(WiFi.status()!=WL_CONNECTED&&printed){MDNS.end();printed=false;}
  http.handleClient();delay(2);
}
