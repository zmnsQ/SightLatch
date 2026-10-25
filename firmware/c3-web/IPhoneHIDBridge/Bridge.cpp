/* SightLatch BLE bridge. Hardware behavior requires board/iPhone verification.
 * Public C3 test build: Arduino 3.3.11 + independent NimBLE-Arduino 2.5.1.
 * HTTP is plaintext: isolated trusted LAN only. See ../README.md.
 * No external BLE keyboard/mouse library and no cloud server required.
 */
#include <Arduino.h>
#include <WiFi.h>
#include <ESPmDNS.h>
#include <WebServer.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>
#include "nimble/porting/nimble/include/nimble/nimble_port.h"
#include "nimble/nimble/include/nimble/nimble_npl.h"
#include "nimble/nimble/host/src/ble_gap_priv.h"
#include <esp_partition.h>
#include <esp_err.h>
#include "src/HidReportMap.h"
#include "PublicIdentity.h"
#include "RelativeAbsoluteAdapter.h"
#include "AbsoluteActionPolicy.h"
#include "CalibrationProbePolicy.h"
#include <esp_system.h>
#include <atomic>
#include <Preferences.h>
#include "ProtocolPrimitives.h"
#include "NetworkLifecycle.h"
#if __has_include("BuildProvenance.h")
#include "BuildProvenance.h"
#else
#define SIGHTLATCH_BUILD_SOURCE_SHA256 "unrecorded"
#endif
using hidpilot::timeBefore;
using hidpilot::asciiKey;
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#if __has_include("config.h")
#include "config.h"
#else
#include "config.default.h"
#endif
#if !defined(CONFIG_IDF_TARGET_ESP32C3)
#error "This public test build only supports ESP32-C3 (USB or UART variant)."
#endif
static constexpr char FIRMWARE_VERSION[]="0.3.3-c3-web";
static constexpr char DEVICE_NAME[]="SightLatch C3 HID";
static_assert(sizeof(DEVICE_NAME)-1==17,"Reviewed primary advertisement name.");
static constexpr uint32_t MAX_TTL = 5000, MIN_INTERVAL = 50;
static constexpr size_t MAX_BODY = 1024, MAX_TEXT = 64;
class ObservedWebServer final : public WebServer {
 public:
  using WebServer::WebServer;
  bool listenerOpen() { return static_cast<bool>(_server); }
};
static ObservedWebServer http(80);
static NimBLEServer *bleServer;
static NimBLECharacteristic *keyboardReport, *mouseReport, *consumerReport;
static SemaphoreHandle_t stateLock;
static std::atomic<bool> connected{false}, encrypted{false}, bonded{false}, emergency{false};
static std::atomic<uint32_t> pairUntil{0};
static std::atomic<uint16_t> connId{0xffff};
static std::atomic<uint32_t> authEvents{0}, authRejects{0}, disconnectEvents{0};
static std::atomic<uint32_t> connectionAttempts{0}, connectionAdmissions{0}, connectionRejects{0};
enum class ConnectionRejection { None, PairingWindowClosed, ExistingConnection };
static std::atomic<ConnectionRejection> lastConnectionRejection{ConnectionRejection::None};
static std::atomic<uint32_t> securityStartEvents{0};
static std::atomic<int> lastSecurityStartCode{0};
static std::atomic<bool> lastSecurityStartAccepted{false};
static std::atomic<uint32_t> safetyStackFree{0};
static std::atomic<int> lastDisconnectReason{-1}, lastEncryptionStatus{-1};
static std::atomic<uint32_t> notifyEvents{0}, notifyErrors{0};
static std::atomic<int> lastNotifyCode{0};
static std::atomic<int> lastNotifyStatus{-1};
struct ReportTelemetry {
  std::atomic<uint32_t> events{0}, errors{0}, subscriptionEvents{0};
  std::atomic<int> status{-1}, code{0}, subscription{-1};
};
static ReportTelemetry keyboardTelemetry, mouseTelemetry;
static std::atomic<uint32_t> gapSubscribeEvents{0};
static std::atomic<int> gapSubscribeHandle{-1}, gapSubscribeNotify{-1}, gapSubscribeIndicate{-1};
static std::atomic<uint32_t> wifiEventState{0}, wifiDisconnects{0}, wifiGotIP{0}, wifiLostIP{0};
static std::atomic<uint32_t> wifiLastEventAt{0};
static std::atomic<int> wifiLastEvent{-1}, wifiDisconnectReason{-1};
static std::atomic<uint32_t> loopTicks{0}, safetyTicks{0}, safetyLastAt{0};
static std::atomic<uint32_t> httpStarts{0}, httpStops{0}, httpStartFailures{0};
static std::atomic<uint32_t> httpRequests{0}, httpCompletions{0}, httpRequestAt{0};
static std::atomic<uint32_t> httpPumpAt{0}, httpPumpMaxMs{0};
static std::atomic<bool> httpHandlerActive{false}, httpPumpActive{false}, httpListenerOpen{false};
static hidpilot::NetworkLifecycle networkLifecycle;
static hidpilot::HTTPListenerRetryPolicy httpListenerRetry;
// Arduino invokes Wi-Fi events serially on its event task. Never call BLE,
// HTTP, mDNS, Preferences, or acquire stateLock from this callback.
static void networkEvent(arduino_event_id_t event,arduino_event_info_t info) {
  bool hasIP=false;
  if(event==ARDUINO_EVENT_WIFI_STA_GOT_IP) {wifiGotIP.fetch_add(1);hasIP=true;}
  else if(event==ARDUINO_EVENT_WIFI_STA_DISCONNECTED) {
    wifiDisconnects.fetch_add(1);wifiDisconnectReason.store(info.wifi_sta_disconnected.reason);
  } else if(event==ARDUINO_EVENT_WIFI_STA_LOST_IP) wifiLostIP.fetch_add(1);
  else if(event!=ARDUINO_EVENT_WIFI_STA_STOP) return;
  wifiLastEvent.store((int)event);wifiLastEventAt.store(millis());
  // Latch loss even if reconnect happens before the safety task's next tick.
  if(!hasIP) emergency.store(true);
  wifiEventState.store(hidpilot::nextNetworkEventState(wifiEventState.load(),hasIP));
}
// Peer callbacks only update small snapshots; hardware dispatch remains under stateLock.
static constexpr uint16_t NO_HANDLE=BLE_HS_CONN_HANDLE_NONE;
struct Peer {
  uint16_t handle=NO_HANDLE;
  uint32_t epoch=0;
  uint8_t reports=0;
  bool encrypted=false,bonded=false,authenticated=false,connectSeen=false;
  bool admissionObserved=false,knownBondAtConnect=false,admitted=false,authenticationAdmitted=false;
};
static Peer peer;
static portMUX_TYPE peerMux=portMUX_INITIALIZER_UNLOCKED;
static uint32_t nextPeerEpoch=0;
static bool bleInitialized=false,identityConfigured=false,advertisementConfigured=false,initialAdvertisingStarted=false;
static unsigned advertisementBytes=0;
static std::atomic<uint32_t> blockedNvsErases{0},storeErrors{0};
static std::atomic<int> lastAuthStatus{-1},lastConnectStatus{-1},lastAdvCompleteReason{-1};
static std::atomic<bool> lastAuthEncrypted{false},lastAuthBonded{false};
static std::atomic<uint8_t> lastReportMaskAtDisconnect{0};
static std::atomic<uint32_t> advCompleteEvents{0};
static hidpilot::RelativeAbsoluteAdapter pointer;
static uint32_t pointerEpoch=0;
static std::atomic<bool> txFault{false};
extern "C" esp_err_t __wrap_nvs_flash_erase(void) {
  blockedNvsErases.fetch_add(1);return ESP_ERR_INVALID_STATE;
}
extern "C" esp_err_t __wrap_nvs_flash_erase_partition(const char *) {
  blockedNvsErases.fetch_add(1);return ESP_ERR_INVALID_STATE;
}
extern "C" esp_err_t __real_esp_partition_erase_range(const esp_partition_t *,size_t,size_t);
extern "C" esp_err_t __wrap_esp_partition_erase_range(const esp_partition_t *partition,size_t offset,size_t size) {
  if(partition&&partition->type==ESP_PARTITION_TYPE_DATA&&partition->subtype==ESP_PARTITION_SUBTYPE_DATA_NVS&&offset==0&&size==partition->size) {
    blockedNvsErases.fetch_add(1);return ESP_ERR_INVALID_STATE;
  }
  return __real_esp_partition_erase_range(partition,offset,size);
}
static Peer peerSnapshot() {
  portENTER_CRITICAL(&peerMux);Peer result=peer;portEXIT_CRITICAL(&peerMux);return result;
}
static bool updatePeer(NimBLEConnInfo &info,bool connectEvent=false) {
  bool accepted=true;
  portENTER_CRITICAL(&peerMux);
  if(peer.handle!=NO_HANDLE&&peer.handle!=info.getConnHandle())accepted=false;
  else {
    // Restored bond callbacks can arrive before onConnect: keep the same epoch/mask.
    if(peer.handle==NO_HANDLE||(connectEvent&&peer.connectSeen)) {
      peer=Peer{};peer.handle=info.getConnHandle();peer.epoch=++nextPeerEpoch;
      if(peer.epoch==0)peer.epoch=++nextPeerEpoch;
    }
    if(connectEvent)peer.connectSeen=true;
    peer.encrypted=info.isEncrypted();peer.bonded=info.isBonded();peer.authenticated=info.isAuthenticated();
    connected.store(true);encrypted.store(peer.encrypted);bonded.store(peer.bonded);connId.store(peer.handle);
  }
  portEXIT_CRITICAL(&peerMux);return accepted;
}
// These notification callbacks are synchronous local ATT transmit results, not peer/UI ACKs.
// NimBLE 2.5.1 ble_gattc.c ble_gatts_notify_custom -> ble_gap_notify_tx_event before return;
// ble_gap.c directly calls listeners. Track one dispatch by tag + conn epoch + value handle.
// Any unobserved/mismatched dispatch poisons this connection; it cannot be reused by a new job.
struct Dispatch {
  bool active=false,seen=false,ambiguous=false;
  uint16_t handle=NO_HANDLE,attribute=0;
  uint32_t epoch=0,tag=0;
  int status=-1;
};
static Dispatch dispatch;
static portMUX_TYPE txMux=portMUX_INITIALIZER_UNLOCKED;
static uint32_t nextDispatchTag=0;
static std::atomic<uint32_t> txOrphans{0},txMismatches{0},repeatPairingRejects{0};
static ReportTelemetry consumerTelemetry;
static ble_gap_event_listener gapDiagnosticsListener{};
static int gapListenerStatus=-1;
static int gapDiagnostics(ble_gap_event *event,void *) {
  if(event->type==BLE_GAP_EVENT_CONNECT)lastConnectStatus.store(event->connect.status);
  else if(event->type==BLE_GAP_EVENT_DISCONNECT)lastDisconnectReason.store(event->disconnect.reason);
  else if(event->type==BLE_GAP_EVENT_ENC_CHANGE) {
    lastEncryptionStatus.store(event->enc_change.status);lastAuthStatus.store(event->enc_change.status);
  } else if(event->type==BLE_GAP_EVENT_ADV_COMPLETE) {
    advCompleteEvents.fetch_add(1);lastAdvCompleteReason.store(event->adv_complete.reason);
  } else if(event->type==BLE_GAP_EVENT_SUBSCRIBE) {
    gapSubscribeEvents.fetch_add(1);gapSubscribeHandle.store(event->subscribe.attr_handle);
    gapSubscribeNotify.store(event->subscribe.cur_notify);gapSubscribeIndicate.store(event->subscribe.cur_indicate);
  } else if(event->type==BLE_GAP_EVENT_NOTIFY_TX&&!event->notify_tx.indication) {
    const uint16_t attr=event->notify_tx.attr_handle;
    ReportTelemetry *r=mouseReport&&attr==mouseReport->getHandle()?&mouseTelemetry:
      keyboardReport&&attr==keyboardReport->getHandle()?&keyboardTelemetry:
      consumerReport&&attr==consumerReport->getHandle()?&consumerTelemetry:nullptr;
    if(!r)return 0;
    const int code=event->notify_tx.status;
    notifyEvents.fetch_add(1);lastNotifyCode.store(code);lastNotifyStatus.store(code==0?0:1);
    r->events.fetch_add(1);r->code.store(code);r->status.store(code==0?0:1);
    if(code!=0){notifyErrors.fetch_add(1);r->errors.fetch_add(1);}
    const Peer value=peerSnapshot();
    portENTER_CRITICAL(&txMux);
    if(dispatch.active&&dispatch.handle==event->notify_tx.conn_handle&&dispatch.attribute==attr&&dispatch.epoch==value.epoch&&!dispatch.seen) {
      dispatch.seen=true;dispatch.status=code;
    } else {
      if(dispatch.active){dispatch.ambiguous=true;txMismatches.fetch_add(1);}
      else txOrphans.fetch_add(1);
      txFault.store(true);emergency.store(true);
    }
    portEXIT_CRITICAL(&txMux);
  }
  return 0;
}
class ReportDiagnostics final:public NimBLECharacteristicCallbacks {
  ReportTelemetry &report;
  uint8_t mask;
 public:
  ReportDiagnostics(ReportTelemetry &value,uint8_t bit):report(value),mask(bit){}
  void onSubscribe(NimBLECharacteristic *,NimBLEConnInfo &info,uint16_t bits) override {
    if(!updatePeer(info))return;
    portENTER_CRITICAL(&peerMux);
    if(peer.handle==info.getConnHandle()) {
      if(bits&1)peer.reports|=mask;else peer.reports&=static_cast<uint8_t>(~mask);
      report.subscription.store(bits);report.subscriptionEvents.fetch_add(1);
    }
    portEXIT_CRITICAL(&peerMux);
  }
};
static ReportDiagnostics keyboardDiagnostics(keyboardTelemetry,2),mouseDiagnostics(mouseTelemetry,1),consumerDiagnostics(consumerTelemetry,4);
// Read/written only on the serialized BLE callback task.
static uint8_t targetAddress[6] = {0};
static String bootId, sessionId, controlEpoch;
static bool armed = false;
static bool calibrationMode = false;
static bool renewableSession = false;
static uint32_t nextRenewalSequence = 1;
static uint32_t armedUntil = 0, nextSequence = 1, lastAcceptedAt = 0;
static String lastId, lastState = "none", lastError;

enum class Kind { Move, Click, ProbeClick, MoveAbsolute, ClickAbsolute, ProbeAbsolute, Scroll, Key, Text, Drag, Release };
static bool isAbsoluteKind(Kind kind) {
  return kind==Kind::MoveAbsolute||kind==Kind::ClickAbsolute||kind==Kind::ProbeAbsolute;
}
struct Job {
  bool active = false;
  Kind kind = Kind::Release;
  String id, text;
  int dx=0, dy=0, wheel=0, button=1, key=0, modifiers=0;
  uint32_t issued=0, ttl=0, duration=0, stepAt=0;
  unsigned phase=0, index=0, steps=0;
  int sentX=0, sentY=0;
  int hidX=0,hidY=0;
  uint32_t hidGeneration=0;
  String controlEpoch,session;
  bool absoluteMayBeDown=false;
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
static bool usable() {
  const Peer value=peerSnapshot();
  return bleInitialized&&!txFault.load()&&value.handle!=NO_HANDLE&&value.admissionObserved&&value.admitted&&value.authenticationAdmitted&&value.encrypted&&value.bonded&&value.reports==7;
}
// Called only under stateLock. A generation loss invalidates our absolute estimate.
static bool pointerKnown() {
  const Peer value=peerSnapshot();
  if(value.handle==NO_HANDLE||value.epoch!=pointerEpoch||txFault.load())pointer.invalidate();
  return pointer.known();
}
enum class HostStage:uint8_t {Idle,Preparing,Queued,Running,Sending,Done,Cancelled,Abandoned};
struct HostDispatch {
  ble_npl_event event{};
  NimBLECharacteristic *report=nullptr;
  uint8_t bytes[8]{};
  size_t count=0;
  uint16_t handle=NO_HANDLE;
  uint32_t epoch=0,deadline=0;
  bool ok=false,releaseOnly=false;
};
static HostDispatch hostDispatch;
static std::atomic<HostStage> hostStage{HostStage::Idle};
static SemaphoreHandle_t hostDone=nullptr;
// Runs on the same host queue as connect/disconnect/encryption/subscription writers.
// No handle can be recycled between final generation validation and notify.
static void hostDispatchRun(ble_npl_event *) {
  HostStage expected=HostStage::Queued;
  if(!hostStage.compare_exchange_strong(expected,HostStage::Running)) {
    if(expected==HostStage::Cancelled)hostStage.store(HostStage::Idle);
    return;
  }
  hostDispatch.ok=false;
  const Peer before=peerSnapshot();
  bool allowed=usable()&&(hostDispatch.releaseOnly||!emergency.load())&&before.handle==hostDispatch.handle&&before.epoch==hostDispatch.epoch&&timeBefore(millis(),hostDispatch.deadline);
  if(allowed) {
    const auto info=bleServer->getPeerInfoByHandle(before.handle);
    allowed=info.getConnHandle()==before.handle&&info.isEncrypted()&&info.isBonded();
  }
  if(allowed) {
    expected=HostStage::Running;
    if(hostStage.compare_exchange_strong(expected,HostStage::Sending)) {
      uint32_t tag;
      portENTER_CRITICAL(&txMux);
      const bool idle=!dispatch.active;
      tag=++nextDispatchTag;if(!tag)tag=++nextDispatchTag;
      if(idle) {
        dispatch=Dispatch{};dispatch.active=true;dispatch.handle=before.handle;
        dispatch.attribute=hostDispatch.report->getHandle();dispatch.epoch=before.epoch;dispatch.tag=tag;
      }
      portEXIT_CRITICAL(&txMux);
      if(idle) {
        const bool accepted=hostDispatch.report->notify(hostDispatch.bytes,hostDispatch.count,before.handle);
        portENTER_CRITICAL(&txMux);const Dispatch result=dispatch;
        const bool observed=result.active&&result.tag==tag&&result.seen&&!result.ambiguous&&result.status==0;
        if(observed&&accepted)dispatch.active=false;
        portEXIT_CRITICAL(&txMux);
        hostDispatch.ok=accepted&&observed&&usable()&&timeBefore(millis(),hostDispatch.deadline);
      }
    }
  }
  expected=hostStage.load();
  if(expected==HostStage::Abandoned) {
    // Caller timed out: no success receipt, no queue reuse on this connection.
    bleServer->disconnect(hostDispatch.handle);hostStage.store(HostStage::Idle);return;
  }
  // CAS allows a caller timeout to abandon this exact event before its result is consumed.
  if(expected==HostStage::Running||expected==HostStage::Sending) {
    if(hostStage.compare_exchange_strong(expected,HostStage::Done)){xSemaphoreGive(hostDone);return;}
    if(expected==HostStage::Abandoned){bleServer->disconnect(hostDispatch.handle);hostStage.store(HostStage::Idle);}
  }
}
static bool dispatchReport(NimBLECharacteristic *report,const uint8_t *bytes,size_t count,bool releaseOnly=false,uint32_t expectedEpoch=0) {
  if(!usable()||!hostDone||count>sizeof(hostDispatch.bytes)||(!releaseOnly&&(!armed||emergency.load())))return false;
  const Peer route=peerSnapshot();
  if(expectedEpoch&&route.epoch!=expectedEpoch)return false;
  if(hostStage.load()==HostStage::Done&&xSemaphoreTake(hostDone,0)==pdTRUE)hostStage.store(HostStage::Idle);
  HostStage expected=HostStage::Idle;
  if(!hostStage.compare_exchange_strong(expected,HostStage::Preparing)) {
    pointer.invalidate();txFault.store(true);emergency.store(true);return false;
  }
  hostDispatch.report=report;hostDispatch.handle=route.handle;hostDispatch.epoch=route.epoch;
  hostDispatch.count=count;memcpy(hostDispatch.bytes,bytes,count);hostDispatch.ok=false;
  hostDispatch.releaseOnly=releaseOnly;hostDispatch.deadline=millis()+100;
  if(!releaseOnly) {
    if(job.active&&timeBefore(job.issued+job.ttl,hostDispatch.deadline))hostDispatch.deadline=job.issued+job.ttl;
    if(timeBefore(armedUntil,hostDispatch.deadline))hostDispatch.deadline=armedUntil;
  }
  hostStage.store(HostStage::Queued,std::memory_order_release);
  ble_npl_eventq_put(nimble_port_get_dflt_eventq(),&hostDispatch.event);
  bool consumed=false,success=false;
  if(xSemaphoreTake(hostDone,pdMS_TO_TICKS(100)+1)==pdTRUE&&hostStage.load()==HostStage::Done) {
    consumed=true;success=hostDispatch.ok;hostStage.store(HostStage::Idle);
  } else {
    expected=HostStage::Queued;
    if(!hostStage.compare_exchange_strong(expected,HostStage::Cancelled)) {
      expected=HostStage::Running;
      if(!hostStage.compare_exchange_strong(expected,HostStage::Abandoned)) {
        expected=HostStage::Sending;
        hostStage.compare_exchange_strong(expected,HostStage::Abandoned);
      }
    }
    // A just-completed result is consumed only to drain it; timeout is never success.
    if(hostStage.load()==HostStage::Done&&xSemaphoreTake(hostDone,0)==pdTRUE)hostStage.store(HostStage::Idle);
  }
  const Peer after=peerSnapshot();
  success=consumed&&success&&after.epoch==route.epoch&&after.handle==route.handle&&usable();
  if(!success){pointer.invalidate();txFault.store(true);emergency.store(true);}
  return success;
}
static bool sendKeyboard(uint8_t key=0,uint8_t modifiers=0) {
  uint8_t bytes[8]={modifiers,0,key,0,0,0,0,0};return dispatchReport(keyboardReport,bytes,sizeof(bytes),key==0&&modifiers==0);
}
static bool sendMouse(uint8_t buttons=0,int dx=0,int dy=0,int wheel=0,bool explicitMove=false) {
  pointerKnown();
  hidpilot::AbsolutePosition planned;
  if(!pointer.plan(dx,dy,calibrationMode&&explicitMove,planned)) {
    // An unknown neutral release must never initialize the mouse at (0,0) or center.
    return buttons==0&&dx==0&&dy==0&&wheel==0;
  }
  const uint8_t bytes[7]={buttons,static_cast<uint8_t>(planned.x),static_cast<uint8_t>(planned.x>>8),
    static_cast<uint8_t>(planned.y),static_cast<uint8_t>(planned.y>>8),static_cast<uint8_t>(static_cast<int8_t>(wheel)),0};
  const Peer before=peerSnapshot();
  if(!dispatchReport(mouseReport,bytes,sizeof(bytes),buttons==0&&dx==0&&dy==0&&wheel==0&&!explicitMove))return false;
  const Peer after=peerSnapshot();
  if(before.epoch!=after.epoch||before.handle!=after.handle){pointer.invalidate();return false;}
  pointer.commit(planned);pointerEpoch=before.epoch;return true;
}
// Coordinates are explicit HID logical values, never inferred screen pixels.
// The generation check is repeated inside dispatchReport before queue routing.
static bool sendAbsoluteMouse(uint8_t buttons,int x,int y,uint32_t generation,bool releaseOnly=false) {
  if(x<0||x>10000||y<0||y>10000||!generation)return false;
  const Peer before=peerSnapshot();
  if(before.handle==NO_HANDLE||before.epoch!=generation)return false;
  const uint8_t bytes[7]={buttons,static_cast<uint8_t>(x),static_cast<uint8_t>(x>>8),
    static_cast<uint8_t>(y),static_cast<uint8_t>(y>>8),0,0};
  if(!dispatchReport(mouseReport,bytes,sizeof(bytes),releaseOnly,generation))return false;
  const Peer after=peerSnapshot();
  if(after.handle!=before.handle||after.epoch!=generation){pointer.invalidate();return false;}
  pointer.commit({static_cast<uint16_t>(x),static_cast<uint16_t>(y)});pointerEpoch=generation;
  return true;
}
static bool releaseReports() {
  // Preserve known XY across ARM/STOP/lease transitions; only releases have no delta.
  if(!usable())return false;
  const bool key=sendKeyboard();const bool mouse=sendMouse();return key&&mouse;
}
static void finishJob(const char *state,const char *reason="") {
  // Cancelling an absolute job before down sends no new positioning report.
  // A possible down is released only on its original BLE generation.
  const bool released=isAbsoluteKind(job.kind)
    ? (!job.absoluteMayBeDown||sendAbsoluteMouse(0,job.hidX,job.hidY,job.hidGeneration,true))
    : releaseReports();
  if(released&&isAbsoluteKind(job.kind))job.absoluteMayBeDown=false;
  if(String(state)=="completed"&&!released){state="aborted";reason="hid_notify_failed";}
  if(job.active&&String(state)=="completed"&&(int32_t)(millis()-job.issued)>(int32_t)job.ttl){state="aborted";reason="expired_during_execution";}
  if(job.active) {
    lastId=job.id;lastState=state;
    for(auto &r:receipts)if(r.id==job.id)r.state=state;
  }
  job.active=false;job.text="";lastError=reason;
}
static void disarm(const char *reason) {
  finishJob("aborted",reason);armed=false;calibrationMode=false;renewableSession=false;nextRenewalSequence=1;sessionId="";nextSequence=1;controlEpoch=randomId();
}
extern "C" int __real_ble_gap_repeat_pairing_event(const struct ble_gap_repeat_pairing *);
extern "C" int __wrap_ble_gap_repeat_pairing_event(const struct ble_gap_repeat_pairing *event) {
  if(!pairingOpen()) {repeatPairingRejects.fetch_add(1);return BLE_GAP_REPEAT_PAIRING_IGNORE;}
  return __real_ble_gap_repeat_pairing_event(event);
}
// NimBLE delays its onConnect until remote-version/features complete. SMP/CCCD
// events may precede it. Capture the pre-SMP bond at the actual HCI connection
// allocation boundary, before any later packet can create a new bond.
// Called from ble_hs_hci_evt.c into ble_gap.c: independently verified link wrap.
extern "C" int __real_ble_gap_rx_conn_complete(struct ble_gap_conn_complete *,uint8_t);
extern "C" int __wrap_ble_gap_rx_conn_complete(struct ble_gap_conn_complete *event,uint8_t instance) {
  const int result=__real_ble_gap_rx_conn_complete(event,instance);
  if(result!=0||event->status!=0||!bleServer)return result;
  auto info=bleServer->getPeerInfoByHandle(event->connection_handle);
  if(info.getConnHandle()!=event->connection_handle)return result;
  const bool knownBond=NimBLEDevice::isBonded(info.getIdAddress());
  const bool admitted=knownBond||pairingOpen();
  if(!updatePeer(info)) {bleServer->disconnect(event->connection_handle);return result;}
  portENTER_CRITICAL(&peerMux);
  if(peer.handle==info.getConnHandle()) {
    peer.admissionObserved=true;peer.knownBondAtConnect=knownBond;peer.admitted=admitted;
  }
  portEXIT_CRITICAL(&peerMux);
  if(!admitted) {
    connectionRejects.fetch_add(1);lastConnectionRejection.store(ConnectionRejection::PairingWindowClosed);
    bleServer->disconnect(info.getConnHandle());
  }
  return result;
}
class ServerCallbacks final:public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *server,NimBLEConnInfo &info) override {
    connectionAttempts.fetch_add(1);
    const Peer admission=peerSnapshot();
    const bool admitted=admission.handle==info.getConnHandle()&&admission.admissionObserved&&admission.admitted;
    if(!admitted) {
      server->disconnect(info.getConnHandle());return;
    }
    if(!updatePeer(info,true)) {
      connectionRejects.fetch_add(1);lastConnectionRejection.store(ConnectionRejection::ExistingConnection);
      server->disconnect(info.getConnHandle());return;
    }
    connectionAdmissions.fetch_add(1);
    server->updateConnParams(info.getConnHandle(),12,24,0,400);
  }
  void onAuthenticationComplete(NimBLEConnInfo &info) override {
    authEvents.fetch_add(1);lastAuthEncrypted.store(info.isEncrypted());lastAuthBonded.store(info.isBonded());
    const Peer admission=peerSnapshot();
    const bool admissionAllowed=admission.handle==info.getConnHandle()&&admission.admissionObserved&&admission.admitted&&
      (admission.knownBondAtConnect||admission.authenticationAdmitted||pairingOpen());
    if(!admissionAllowed||!updatePeer(info)||!info.isEncrypted()) {
      authRejects.fetch_add(1);emergency.store(true);bleServer->disconnect(info.getConnHandle());
    } else {
      portENTER_CRITICAL(&peerMux);
      if(peer.handle==info.getConnHandle())peer.authenticationAdmitted=true;
      portEXIT_CRITICAL(&peerMux);pairUntil.store(0);
    }
  }
  void onIdentity(NimBLEConnInfo &info) override {updatePeer(info);}
  void onDisconnect(NimBLEServer *,NimBLEConnInfo &info,int reason) override {
    lastDisconnectReason.store(reason);disconnectEvents.fetch_add(1);
    bool owned=false;
    portENTER_CRITICAL(&peerMux);
    if(peer.handle==info.getConnHandle()) {
      owned=true;lastReportMaskAtDisconnect.store(peer.reports);peer=Peer{};
      connected.store(false);encrypted.store(false);bonded.store(false);connId.store(NO_HANDLE);
      keyboardTelemetry.subscription.store(0);mouseTelemetry.subscription.store(0);consumerTelemetry.subscription.store(0);
      emergency.store(true);pairUntil.store(0);
    }
    portEXIT_CRITICAL(&peerMux);
    // A new epoch is allowed only after the old connection actually terminates.
    if(owned) {portENTER_CRITICAL(&txMux);dispatch=Dispatch{};portEXIT_CRITICAL(&txMux);txFault.store(false);}
  }
};
class DeviceCallbacks final:public NimBLEDeviceCallbacks {
  int onStoreStatus(ble_store_status_event *event,void *) override {
    if(event->event_code==BLE_STORE_EVENT_FULL)return 0;
    storeErrors.fetch_add(1);return BLE_HS_ESTORE_CAP;
  }
};

// US keyboard layout only. Chinese/UTF-8 must be rejected, never silently mangled.
// No delays while holding a key: each tick performs at most one small HID step.
static void stepJob(uint32_t now) {
  if(!job.active || timeBefore(now,job.stepAt)) return;
  if((int32_t)(now-job.issued)>(int32_t)job.ttl) {finishJob("aborted","expired_during_execution");return;}
  lastState="running";
  if(isAbsoluteKind(job.kind)) {
    const Peer route=peerSnapshot();
    if(!armed||emergency.load()||stopPressed()||!usable()||WiFi.status()!=WL_CONNECTED||
       !timeBefore(now,armedUntil)||route.epoch!=job.hidGeneration||
       job.controlEpoch!=controlEpoch||job.session!=sessionId||
       (job.kind==Kind::ProbeAbsolute&&!calibrationMode)||(job.kind==Kind::ClickAbsolute&&calibrationMode)) {
      finishJob("aborted","absolute_context_changed");return;
    }
    if(job.phase==0) {
      if(!sendAbsoluteMouse(0,job.hidX,job.hidY,job.hidGeneration)){finishJob("aborted","hid_notify_failed");return;}
      if(job.kind==Kind::MoveAbsolute){finishJob("completed");return;}
      job.phase=1;job.stepAt=millis()+hidpilot::ABSOLUTE_SETTLE_MS;return;
    }
    if(job.phase==1) {
      job.absoluteMayBeDown=true; // A lost local result cannot prove no down was sent.
      if(!sendAbsoluteMouse(1,job.hidX,job.hidY,job.hidGeneration)){finishJob("aborted","hid_notify_failed");return;}
      job.phase=2;job.stepAt=millis()+hidpilot::ABSOLUTE_HOLD_MS;return;
    }
    if(!sendAbsoluteMouse(0,job.hidX,job.hidY,job.hidGeneration,true)){finishJob("aborted","hid_notify_failed");return;}
    job.absoluteMayBeDown=false;finishJob("completed");return;
  }
  if(job.kind==Kind::Move) {if(!sendMouse(0,job.dx,job.dy,0,true)){finishJob("aborted","hid_notify_failed");return;}finishJob("completed");return;}
  if(job.kind==Kind::Scroll) {if(!sendMouse(0,0,0,job.wheel)){finishJob("aborted","hid_notify_failed");return;}finishJob("completed");return;}
  if(job.kind==Kind::Release) {finishJob("completed");return;}
  if(job.kind==Kind::Click || job.kind==Kind::ProbeClick || job.kind==Kind::Key) {
    if(job.phase++==0) {
      const bool sent=job.kind==Kind::Key?sendKeyboard(job.key,job.modifiers):sendMouse(job.button);
      if(!sent){finishJob("aborted","hid_notify_failed");return;}
      // Probe hold starts after local ATT dispatch, never before queue latency.
      job.stepAt=(job.kind==Kind::ProbeClick?millis():now)+40;
    } else finishJob("completed");
    return;
  }
  if(job.kind==Kind::Text) {
    if(job.index>=job.text.length()) {finishJob("completed");return;}
    if(job.phase==0) {
      uint8_t key,mods; asciiKey(job.text[job.index],key,mods);
      if(!sendKeyboard(key,mods)){finishJob("aborted","hid_notify_failed");return;} job.phase=1;
    } else {if(!sendKeyboard()){finishJob("aborted","hid_notify_failed");return;}job.phase=0;job.index++;}
    job.stepAt=now+25;return;
  }
  if(job.kind==Kind::Drag) {
    if(job.phase++==0) {if(!sendMouse(job.button)){finishJob("aborted","hid_notify_failed");return;}job.stepAt=now+20;return;}
    if(job.index>=job.steps) {finishJob("completed");return;}
    job.index++;
    int tx=job.dx*(int)job.index/(int)job.steps;
    int ty=job.dy*(int)job.index/(int)job.steps;
    if(!sendMouse(job.button,tx-job.sentX,ty-job.sentY)){finishJob("aborted","hid_notify_failed");return;}
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
    pointerKnown();
    if(txFault.load()&&connected.load())bleServer->disconnect(connId.load());
    if(emergency.exchange(false)) {
      disarm("stopped_or_ble_lost");pairUntil.store(0);
    }
    if(armed && (!usable() || WiFi.status()!=WL_CONNECTED || !timeBefore(now,armedUntil)))
      disarm("link_or_arm_lease_lost");
    if(armDown && !armWasDown) {armDownAt=now;longHandled=false;}
    if(armDown && !longHandled && (uint32_t)(now-armDownAt)>=2000) {
      longHandled=true;disarm("pairing_window");
      // Pair only with no existing connection; disconnect explicitly first.
      if(connected.load()) bleServer->disconnect(connId.load());
      else {pairUntil.store(now+PAIR_WINDOW_MS);NimBLEDevice::getAdvertising()->start();}
    }
    if(!armDown && armWasDown && !longHandled && (uint32_t)(now-armDownAt)>=60 && !stopDown) {
      if(armed) disarm("physical_disarm");
      else if(usable() && WiFi.status()==WL_CONNECTED) {
        releaseReports(); calibrationMode=false;renewableSession=false;nextRenewalSequence=1;armed=true;armedUntil=now+ARM_LEASE_MS;
        sessionId=randomId();nextSequence=1;lastAcceptedAt=0;lastError="";
        for(auto &r:receipts) r=Receipt{};
      }
    }
    armWasDown=armDown;
    uint32_t until=pairUntil.load();
    if(until && !timeBefore(now,until)) {
      pairUntil.store(0);NimBLEDevice::getAdvertising()->stop();
      if(connected.load()&&!encrypted.load()) bleServer->disconnect(connId.load());
    }
    if(armed && !stopDown) stepJob(now);
    xSemaphoreGive(stateLock);
    safetyStackFree.store(uxTaskGetStackHighWaterMark(nullptr));
    safetyLastAt.store(millis());safetyTicks.fetch_add(1);
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
// Read-only diagnostics: no credentials, text, addresses, or pairing changes.
static const char *notifyStatusName(int status) {
  return status==0?"local_att_tx_success":status<0?"none":"local_att_tx_error";
}
static void reportDiagnosticFields(JsonObject d,const ReportTelemetry &report) {
  d["notify_events"]=report.events.load();d["notify_errors"]=report.errors.load();
  d["last_status"]=notifyStatusName(report.status.load());d["last_code"]=report.code.load();
  // -1 means this stack has not provided subscription observations.
  d["subscription"]=report.subscription.load();d["subscription_events"]=report.subscriptionEvents.load();
}
static void diagnosticFields(JsonDocument &d) {
  d["ble_stack"]="nimble-arduino-2.5.1";
  const Peer value=peerSnapshot();
  d["device_name"]=DEVICE_NAME;d["identity_type"]="static_random";d["identity_configured"]=identityConfigured;
  d["adv_active"]=bleInitialized&&NimBLEDevice::getAdvertising()->isAdvertising();
  d["adv_configured"]=advertisementConfigured;d["adv_initial_start_ok"]=initialAdvertisingStarted;
  d["adv_payload_bytes"]=advertisementBytes;d["adv_name_in_primary"]=true;d["scan_response_enabled"]=false;
  d["gap_listener_status"]=gapListenerStatus;
  d["encrypted"]=value.encrypted;d["bonded"]=value.bonded;d["report_mask"]=value.reports;
  d["ble_connection_epoch"]=value.epoch;d["known_bond_at_connect"]=value.knownBondAtConnect;
  d["peer_admitted"]=value.admissionObserved&&value.admitted;d["repeat_pairing_rejects"]=repeatPairingRejects.load();
  d["last_auth_encrypted"]=lastAuthEncrypted.load();d["last_auth_bonded"]=lastAuthBonded.load();
  d["last_auth_status"]=lastAuthStatus.load();d["last_connect_status"]=lastConnectStatus.load();
  d["last_report_mask_at_disconnect"]=lastReportMaskAtDisconnect.load();
  d["adv_complete_events"]=advCompleteEvents.load();d["last_adv_complete_reason"]=lastAdvCompleteReason.load();
  d["nvs_erase_blocked"]=blockedNvsErases.load();d["store_errors"]=storeErrors.load();
  d["tx_fault"]=txFault.load();d["tx_orphan_events"]=txOrphans.load();d["tx_mismatch_events"]=txMismatches.load();
  d["hid_completion_evidence"]="local_att_tx_only";
  d["calibration_probe_supported"]=true;
  d["absolute_pointer_supported"]=true;d["absolute_probe_supported"]=true;
  d["pointer_mode"]="absolute";d["hid_report_mode"]="absolute";
  d["relative_adapter_supported"]=true;
  d["relative_logical_step"]=hidpilot::RelativeAbsoluteAdapter::STEP;
  hidpilot::AbsolutePosition submitted;
  const bool known=pointerKnown()&&pointerEpoch==value.epoch&&pointer.read(submitted);
  d["pointer_position_known"]=known;d["absolute_position_known"]=known;
  d["hid_generation"]=value.epoch;
  if(known){d["absolute_hid_x"]=submitted.x;d["absolute_hid_y"]=submitted.y;}
  else {d["absolute_hid_x"]=nullptr;d["absolute_hid_y"]=nullptr;}
  d["firmware_source_sha256"]=SIGHTLATCH_BUILD_SOURCE_SHA256;d["source_id"]=SIGHTLATCH_BUILD_SOURCE_SHA256;
  d["initialized"]=bleInitialized;d["connected"]=connected.load();d["ready"]=usable();
  d["connection_attempts"]=connectionAttempts.load();d["connection_admissions"]=connectionAdmissions.load();
  d["connection_rejects"]=connectionRejects.load();
  switch(lastConnectionRejection.load()) {
    case ConnectionRejection::None:d["last_connection_rejection"]="none";break;
    case ConnectionRejection::PairingWindowClosed:d["last_connection_rejection"]="pairing_window_closed";break;
    case ConnectionRejection::ExistingConnection:d["last_connection_rejection"]="existing_connection";break;
  }
  d["security_start_events"]=securityStartEvents.load();
  d["last_security_start_code"]=lastSecurityStartCode.load();
  d["last_security_start_accepted"]=lastSecurityStartAccepted.load();
  d["reset_reason"]=(int)esp_reset_reason();
  d["auth_events"]=authEvents.load();d["auth_rejects"]=authRejects.load();
  d["disconnect_events"]=disconnectEvents.load();
  d["last_disconnect_reason"]=lastDisconnectReason.load();
  d["last_encryption_status"]=lastEncryptionStatus.load();
  d["notify_events"]=notifyEvents.load();d["notify_errors"]=notifyErrors.load();
  d["last_notify_code"]=lastNotifyCode.load();
  d["last_notify_status"]=notifyStatusName(lastNotifyStatus.load());
  JsonObject reports=d["hid_reports"].to<JsonObject>();
  reportDiagnosticFields(reports["keyboard"].to<JsonObject>(),keyboardTelemetry);
  reportDiagnosticFields(reports["mouse"].to<JsonObject>(),mouseTelemetry);
  reportDiagnosticFields(reports["consumer"].to<JsonObject>(),consumerTelemetry);
  if(keyboardReport)reports["keyboard"]["value_handle"]=keyboardReport->getHandle();
  if(mouseReport)reports["mouse"]["value_handle"]=mouseReport->getHandle();
  d["gap_subscribe_events"]=gapSubscribeEvents.load();d["gap_last_subscribe_handle"]=gapSubscribeHandle.load();
  d["gap_last_subscribe_notify"]=gapSubscribeNotify.load();d["gap_last_subscribe_indicate"]=gapSubscribeIndicate.load();
  const uint32_t now=millis();
  const int wifiStatus=WiFi.status();
  d["wifi_status"]=wifiStatus;
  if(wifiStatus==WL_CONNECTED)d["wifi_rssi_dbm"]=WiFi.RSSI();
  else d["wifi_rssi_dbm"]=nullptr;
  d["wifi_disconnect_events"]=wifiDisconnects.load();d["wifi_last_disconnect_reason"]=wifiDisconnectReason.load();
  d["wifi_got_ip_events"]=wifiGotIP.load();d["wifi_lost_ip_events"]=wifiLostIP.load();
  d["wifi_event_state"]=wifiEventState.load();d["wifi_last_event"]=wifiLastEvent.load();
  if(wifiLastEvent.load()>=0)d["wifi_last_event_age_ms"]=(uint32_t)(now-wifiLastEventAt.load());
  d["loop_ticks"]=loopTicks.load();d["safety_ticks"]=safetyTicks.load();
  if(safetyTicks.load())d["safety_last_tick_age_ms"]=(uint32_t)(now-safetyLastAt.load());
  d["http_listener_open"]=httpListenerOpen.load();d["http_listener_starts"]=httpStarts.load();
  d["http_listener_stops"]=httpStops.load();d["http_listener_start_failures"]=httpStartFailures.load();
  d["http_requests"]=httpRequests.load();d["http_completions"]=httpCompletions.load();
  d["http_handler_active"]=httpHandlerActive.load();
  if(httpHandlerActive.load())d["http_handler_age_ms"]=(uint32_t)(now-httpRequestAt.load());
  d["http_pump_active"]=httpPumpActive.load();d["http_pump_max_ms"]=httpPumpMaxMs.load();
  if(httpPumpActive.load())d["http_pump_age_ms"]=(uint32_t)(now-httpPumpAt.load());
  d["free_heap_bytes"]=ESP.getFreeHeap();
  d["min_free_heap_bytes"]=ESP.getMinFreeHeap();
  d["safety_stack_free_bytes"]=safetyStackFree.load();
}
static void statusHandler() {
  if(!authorized()) return;
  JsonDocument d;
  xSemaphoreTake(stateLock,portMAX_DELAY);
  d["ok"]=true;d["boot_id"]=bootId;d["control_epoch"]=controlEpoch;d["uptime_ms"]=millis();
  d["session_renewal_supported"]=bool(SIGHTLATCH_SOFTWARE_CONTROL);
  d["renewable_session"]=armed&&renewableSession;
  d["next_renewal_sequence"]=nextRenewalSequence;
  d["control_lease_mode"]=!armed?"none":calibrationMode?"calibration":"task";
  const uint32_t statusNow=millis();
  d["lease_remaining_ms"]=armed&&timeBefore(statusNow,armedUntil)?armedUntil-statusNow:0;
  d["armed"]=armed;d["hid_connected"]=usable();d["ble_connected"]=connected.load();
  d["session_id"]=sessionId;d["next_sequence"]=nextSequence;d["max_ttl_ms"]=MAX_TTL;
  d["busy"]=job.active;d["last_action_id"]=lastId;d["last_action_state"]=lastState;
  d["last_error"]=lastError;d["pairing_open"]=pairingOpen();
  d["accessory_setup_service_uuid"]=nullptr;
  d["control_mode"]=SIGHTLATCH_SOFTWARE_CONTROL?"software":"physical";
  d["firmware_version"]=FIRMWARE_VERSION;diagnosticFields(d);
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
  else if(type=="probe_click") j.kind=Kind::ProbeClick;
  else if(type=="move_absolute")j.kind=Kind::MoveAbsolute;
  else if(type=="click_absolute")j.kind=Kind::ClickAbsolute;
  else if(type=="probe_absolute")j.kind=Kind::ProbeAbsolute;
  else if(type=="scroll") j.kind=Kind::Scroll;
  else if(type=="key") j.kind=Kind::Key;
  else if(type=="text") j.kind=Kind::Text;
  else if(type=="drag") j.kind=Kind::Drag;
  else if(type=="release_all") j.kind=Kind::Release;
  else return false;
  if(isAbsoluteKind(j.kind)) {
    if(!hidpilot::absoluteActionKeysAllowed(d.as<JsonObjectConst>())||
       !d["control_epoch"].is<const char *>()||strlen(d["control_epoch"].as<const char *>())!=32||
       !d["hid_generation"].is<uint32_t>()||d["hid_generation"].as<uint32_t>()==0||
       !boundedInt(d["hid_x"],0,10000,j.hidX)||!boundedInt(d["hid_y"],0,10000,j.hidY))return false;
    j.hidGeneration=d["hid_generation"].as<uint32_t>();j.controlEpoch=d["control_epoch"].as<String>();
    return true;
  }
  if(j.kind==Kind::ProbeClick) {j.button=1;return hidpilot::calibrationProbeKeysAllowed(d.as<JsonObjectConst>());}
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
  else if(!calibrationMode && (candidate.kind==Kind::ProbeClick||candidate.kind==Kind::ProbeAbsolute)){code=403;failure="calibration_probe_only";}
  else if(calibrationMode && candidate.kind!=Kind::Release && candidate.kind!=Kind::ProbeClick &&
          candidate.kind!=Kind::MoveAbsolute && candidate.kind!=Kind::ProbeAbsolute &&
          (candidate.kind!=Kind::Move || !hidpilot::calibrationMoveAllowed(candidate.dx,candidate.dy)))
    {code=403;failure="calibration_action_not_allowed";}
  else if(d["boot_id"].as<String>()!=bootId||d["session_id"].as<String>()!=sessionId)
    {code=409;failure="session_mismatch";}
  else if(isAbsoluteKind(candidate.kind)&&(candidate.controlEpoch!=controlEpoch||candidate.hidGeneration!=peerSnapshot().epoch))
    {code=409;failure="absolute_generation_mismatch";}
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
    else if(!isAbsoluteKind(candidate.kind)&&!pointerKnown()&&(!calibrationMode||candidate.kind!=Kind::Move)&&candidate.kind!=Kind::Release){code=409;failure="pointer_position_unknown";}
    else if(job.active){code=409;failure="busy";}
    else if(lastAcceptedAt && (uint32_t)(now-lastAcceptedAt)<MIN_INTERVAL){code=429;failure="rate_limited";}
    else {
      // Reserve enough remaining TTL for the bounded action to finish.
      uint32_t required=candidate.kind==Kind::Text?candidate.text.length()*50+100:
        candidate.kind==Kind::Drag?candidate.duration+100:
        (candidate.kind==Kind::ClickAbsolute||candidate.kind==Kind::ProbeAbsolute)?hidpilot::ABSOLUTE_CLICK_REQUIRED_MS:100;
      int32_t age=(int32_t)(now-issued);if(age<0)age=0;
      if(required>ttl-(uint32_t)age){code=408;failure="insufficient_ttl_for_action";}
      else {
        candidate.id=id;candidate.active=true;candidate.issued=issued;candidate.ttl=ttl;candidate.stepAt=now;candidate.session=sessionId;
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
static bool parseControlRequest(String &expectedBoot,String &expectedEpoch,bool *calibration=nullptr,bool *renewable=nullptr) {
  String body=http.arg("plain");JsonDocument d;
  if(body.length()>256||deserializeJson(d,body)||!d["boot_id"].is<String>()||!d["control_epoch"].is<String>()) {
    error(400,"invalid_control_request");return false;
  }
  if(calibration) {
    String mode=d["mode"]|"task";
    if((!d["mode"].isNull()&&!d["mode"].is<String>())||(mode!="task"&&mode!="calibration"&&mode!="renewable_task")) {
      error(400,"invalid_control_mode");return false;
    }
    *calibration=mode=="calibration";
    if(renewable)*renewable=mode=="renewable_task";
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
  if(!NimBLEDevice::getAdvertising()->start()){pairUntil.store(0);xSemaphoreGive(stateLock);error(503,"advertising_failed");return;}
  xSemaphoreGive(stateLock);
  JsonDocument d;d["ok"]=true;d["pairing_open"]=true;d["boot_id"]=bootId;
  xSemaphoreTake(stateLock,portMAX_DELAY);d["control_epoch"]=controlEpoch;xSemaphoreGive(stateLock);respond(200,d);
#else
  error(403,"physical_control_required");
#endif
}
// A dismissed UI may cancel only the unarmed pairing generation it opened.
// Never translate this operation to unconditional STOP on an older firmware.
static void cancelPairingHandler() {
  if(!authorized())return;
#if SIGHTLATCH_SOFTWARE_CONTROL
  String expectedBoot,expectedEpoch;
  if(!parseControlRequest(expectedBoot,expectedEpoch))return;
  xSemaphoreTake(stateLock,portMAX_DELAY);
  if(expectedBoot!=bootId||expectedEpoch!=controlEpoch||armed||!pairingOpen()) {
    xSemaphoreGive(stateLock);error(409,"pairing_window_changed");return;
  }
  pairUntil.store(0);controlEpoch=randomId();
  NimBLEDevice::getAdvertising()->stop();
  if(connected.load()&&!encrypted.load())bleServer->disconnect(connId.load());
  JsonDocument d;d["ok"]=true;d["pairing_open"]=false;d["boot_id"]=bootId;
  d["control_epoch"]=controlEpoch;
  xSemaphoreGive(stateLock);respond(200,d);
#else
  error(403,"physical_control_required");
#endif
}
static void armHandler() {
  if(!authorized()) return;
#if SIGHTLATCH_SOFTWARE_CONTROL
  String expectedBoot,expectedEpoch;bool requestedCalibration=false,requestedRenewable=false;
  if(!parseControlRequest(expectedBoot,expectedEpoch,&requestedCalibration,&requestedRenewable))return;
  xSemaphoreTake(stateLock,portMAX_DELAY);
  if(expectedBoot!=bootId||expectedEpoch!=controlEpoch) {
    xSemaphoreGive(stateLock);error(409,"control_epoch_mismatch");return;
  }
  if(emergency.load()||!usable()||WiFi.status()!=WL_CONNECTED) {
    xSemaphoreGive(stateLock);error(409,"hid_or_wifi_unavailable");return;
  }
  // An explicit absolute target needs no cached current position. Legacy
  // relative actions still reject unknown position in actionHandler.
  if(armed&&(calibrationMode!=requestedCalibration||renewableSession!=requestedRenewable)) {
    xSemaphoreGive(stateLock);error(409,"control_mode_mismatch");return;
  }
  // An accidental retry must not extend the lease or change an active session.
  if(!armed) {
    if(!releaseReports()){xSemaphoreGive(stateLock);error(503,"hid_notify_failed");return;}
    calibrationMode=requestedCalibration;renewableSession=requestedRenewable;nextRenewalSequence=1;armed=true;
    armedUntil=millis()+(renewableSession?30000U:hidpilot::controlLeaseMs(calibrationMode,ARM_LEASE_MS));
    sessionId=randomId();nextSequence=1;lastAcceptedAt=0;lastError="";
    for(auto &r:receipts) r=Receipt{};
  }
  xSemaphoreGive(stateLock);statusHandler();
#else
  error(403,"physical_control_required");
#endif
}
// A renewal can only extend the same still-live session. It never creates an ARM.
static void renewHandler() {
  if(!authorized())return;
#if SIGHTLATCH_SOFTWARE_CONTROL
  String body=http.arg("plain");JsonDocument d;
  if(body.length()>512||deserializeJson(d,body)||d.size()!=8||
     !d["boot_id"].is<String>()||!d["session_id"].is<String>()||!d["control_epoch"].is<String>()||
     !d["hid_generation"].is<uint32_t>()||!d["renewal_sequence"].is<uint32_t>()||
     !d["issued_at_ms"].is<uint32_t>()||!d["ttl_ms"].is<uint32_t>()||!d["lease_ms"].is<uint32_t>()) {
    error(400,"invalid_renewal_request");return;
  }
  const uint32_t issued=d["issued_at_ms"],ttl=d["ttl_ms"],lease=d["lease_ms"],sequence=d["renewal_sequence"];
  if(ttl<100||ttl>1500||lease<100||lease>30000||sequence==0||sequence==UINT32_MAX) {
    error(400,"invalid_renewal_bounds");return;
  }
  xSemaphoreTake(stateLock,portMAX_DELAY);
  const uint32_t now=millis();
  if(!armed||!renewableSession||calibrationMode||emergency.load()||!usable()||WiFi.status()!=WL_CONNECTED||
     !timeBefore(now,armedUntil)||d["boot_id"].as<String>()!=bootId||d["session_id"].as<String>()!=sessionId||
     d["control_epoch"].as<String>()!=controlEpoch||d["hid_generation"].as<uint32_t>()!=peerSnapshot().epoch||
     sequence!=nextRenewalSequence) {
    xSemaphoreGive(stateLock);error(409,"renewal_session_mismatch");return;
  }
  // Unsigned subtraction rejects future timestamps and is wrap-safe for these short deadlines.
  if(uint32_t(now-issued)>=ttl||uint32_t(now-issued)>=lease) {
    xSemaphoreGive(stateLock);error(408,"renewal_expired");return;
  }
  armedUntil=issued+lease;nextRenewalSequence++;
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
      response["firmware_version"]=FIRMWARE_VERSION;
      response["type"]="response";response["command"]=command;response["request_id"]=d["request_id"]|"";
      response["boot_id"]=bootId;response["uptime_ms"]=millis();
      response["ble_connected"]=connected.load();response["hid_connected"]=usable();
      if(stateLock)xSemaphoreTake(stateLock,portMAX_DELAY);
      diagnosticFields(response);response["ip"]=WiFi.localIP().toString();
      if(stateLock)xSemaphoreGive(stateLock);
      serializeJson(response,Serial);Serial.println();continue;
    }
    if(command=="stop") {
      if(stateLock){xSemaphoreTake(stateLock,portMAX_DELAY);controlEpoch=randomId();emergency.store(true);xSemaphoreGive(stateLock);}
      JsonDocument response;response["type"]="response";response["command"]=command;response["request_id"]=d["request_id"]|"";
      response["ok"]=true;response["stop_requested"]=true;serializeJson(response,Serial);Serial.println();continue;
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

static void trackedRequest(void (*handler)()) {
  httpRequestAt.store(millis());httpRequests.fetch_add(1);httpHandlerActive.store(true);
  handler();
  httpHandlerActive.store(false);httpCompletions.fetch_add(1);
}
static void maintainNetwork() {
  const auto transition=networkLifecycle.update(wifiEventState.load(),WiFi.status()==WL_CONNECTED);
  if(transition.close) {
    http.client().stop();http.close();MDNS.end();
    httpListenerOpen.store(false);httpStops.fetch_add(1);
    httpListenerRetry.reset();
  }
  if(transition.start)httpListenerRetry.reset();
  if(transition.start || httpListenerRetry.due(millis(),networkLifecycle.serving(),httpListenerOpen.load())) {
    // Socket lifetimes follow GOT_IP, including same-IP reconnections.
    // Failed starts retry the listener only, with 500ms..5s capped backoff.
    http.begin();httpStarts.fetch_add(1);httpListenerOpen.store(http.listenerOpen());
    if(!httpListenerOpen.load())httpStartFailures.fetch_add(1);
    httpListenerRetry.attempted(millis(),httpListenerOpen.load());
  }
  if(transition.start) {
    // No credential writes, pairing, ARM, or extra Wi-Fi reconnect policy here.
    if(MDNS.begin("hidbridge"))MDNS.addService("http","tcp",80);
    Serial.print("Local IP: ");Serial.println(WiFi.localIP());
  }
}

void setup() {
  Serial.begin(115200);
  Serial.printf("SightLatch reset_reason=%d\n",(int)esp_reset_reason());
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
  if(!NimBLEDevice::init(DEVICE_NAME)){Serial.println("BLE init failed; HID disabled.");return;}
  identityConfigured=configurePublicIdentity();
  if(!identityConfigured){Serial.println("BLE identity failed; HID disabled.");return;}
  gapListenerStatus=ble_gap_event_listener_register(&gapDiagnosticsListener,gapDiagnostics,nullptr);
  if(gapListenerStatus!=0){Serial.println("BLE diagnostics unavailable; HID disabled.");return;}
  NimBLEDevice::setDeviceCallbacks(new DeviceCallbacks());
  NimBLEDevice::setSecurityAuth(true,false,true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  bleServer=NimBLEDevice::createServer();bleServer->setCallbacks(new ServerCallbacks());
  bleServer->advertiseOnDisconnect(true);
  auto *hid=new NimBLEHIDDevice(bleServer);
  mouseReport=hid->getInputReport(1);keyboardReport=hid->getInputReport(2);consumerReport=hid->getInputReport(3);hid->getOutputReport(2);
  mouseReport->setCallbacks(&mouseDiagnostics);keyboardReport->setCallbacks(&keyboardDiagnostics);consumerReport->setCallbacks(&consumerDiagnostics);
  hid->setManufacturer("iPhone Agent Harness");hid->setPnp(2,0x303A,0x1001,0x0103);hid->setHidInfo(0,1);
  hid->getReportMap()->setValue(iah::reportMap,sizeof(iah::reportMap));hid->setBatteryLevel(100);
  bleServer->start();auto *adv=NimBLEDevice::getAdvertising();
  NimBLEAdvertisementData primary;
  bool built=primary.setFlags(BLE_HS_ADV_F_DISC_GEN|BLE_HS_ADV_F_BREDR_UNSUP);
  built=primary.setAppearance(HID_MOUSE)&&built;
  built=primary.setCompleteServices(hid->getHidService()->getUUID())&&built;
  built=primary.setName(DEVICE_NAME,true)&&built;
  advertisementBytes=primary.getPayload().size();
  if(!built||advertisementBytes!=30||advertisementBytes>31){Serial.println("BLE advertisement invalid; HID disabled.");return;}
  adv->enableScanResponse(false);advertisementConfigured=adv->setAdvertisementData(primary);
  if(!advertisementConfigured){Serial.println("BLE advertisement failed; HID disabled.");return;}
  hostDone=xSemaphoreCreateBinary();
  if(!hostDone){Serial.println("BLE routing unavailable; HID disabled.");return;}
  ble_npl_event_init(&hostDispatch.event,hostDispatchRun,nullptr);
  initialAdvertisingStarted=adv->start();bleInitialized=initialAdvertisingStarted;
  if(!bleInitialized){Serial.println("BLE advertising failed; HID disabled.");return;}
  if(xTaskCreatePinnedToCore(safetyTask,"hid-safety",8192,nullptr,3,nullptr,tskNO_AFFINITY)!=pdPASS) {
    Serial.println("Safety task failed; halted.");for(;;)delay(1000);
  }
  WiFi.onEvent(networkEvent);
  WiFi.mode(WIFI_STA);WiFi.setAutoReconnect(true);WiFi.begin(wifiSSID.c_str(),wifiPassword.c_str());
  const char *headers[]={"Authorization"};http.collectHeaders(headers,1);
  http.on("/v1/status",HTTP_GET,[](){trackedRequest(statusHandler);});
  http.on("/v1/action",HTTP_POST,[](){trackedRequest(actionHandler);});
  http.on("/v1/stop",HTTP_POST,[](){trackedRequest(stopHandler);});
  http.on("/v1/pair",HTTP_POST,[](){trackedRequest(pairHandler);});
  http.on("/v1/arm",HTTP_POST,[](){trackedRequest(armHandler);});
  http.on("/v1/renew",HTTP_POST,[](){trackedRequest(renewHandler);});
  http.on("/v1/cancel_pairing",HTTP_POST,[](){trackedRequest(cancelPairingHandler);});
  http.onNotFound([](){trackedRequest([](){error(404,"not_found");});});
  bridgeReady=true;
  Serial.println("SightLatch started DISARMED. Verified bond may reconnect; explicit ARM required.");
}
void loop() {
  loopTicks.fetch_add(1);
  serialProvision();
  if(!bridgeReady){delay(5);return;}
  maintainNetwork();
  if(networkLifecycle.serving()) {
    const uint32_t started=millis();httpPumpAt.store(started);httpPumpActive.store(true);
    http.handleClient();
    httpPumpActive.store(false);
    const uint32_t duration=millis()-started;
    if(duration>httpPumpMaxMs.load())httpPumpMaxMs.store(duration);
  }
  delay(2);
}
