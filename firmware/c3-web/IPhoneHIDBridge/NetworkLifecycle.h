#pragma once
#include <stdint.h>

namespace hidpilot {
// A single atomic snapshot preserves the final readiness and the fact that an
// intervening disconnect occurred, even when both events arrive between ticks.
inline uint32_t nextNetworkEventState(uint32_t previous, bool hasIP) {
  return ((previous & ~uint32_t{1}) + uint32_t{2}) | (hasIP ? 1u : 0u);
}
struct NetworkTransition { bool close; bool start; };
class NetworkLifecycle {
 public:
  NetworkTransition update(uint32_t eventState, bool connected) {
    const bool ready = (eventState & 1u) && connected;
    const bool changed = eventState != appliedState;
    NetworkTransition result{active && (!ready || changed), ready && (!active || changed)};
    appliedState = eventState;
    active = ready;
    return result;
  }
  bool serving() const { return active; }
 private:
  uint32_t appliedState = 0;
  bool active = false;
};
// Wi-Fi readiness does not guarantee socket/bind/listen succeeded. Retry only a
// failed listener start; link transitions and successful starts clear the timer.
class HTTPListenerRetryPolicy {
 public:
  void reset() { pending=false; delayMs=500; nextAttemptAt=0; }
  bool due(uint32_t now, bool networkReady, bool listenerOpen) const {
    return pending && networkReady && !listenerOpen && static_cast<int32_t>(now-nextAttemptAt)>=0;
  }
  void attempted(uint32_t now, bool listenerOpen) {
    if(listenerOpen) {reset();return;}
    pending=true;nextAttemptAt=now+delayMs;
    delayMs=delayMs>=2500 ? 5000 : delayMs*2;
  }
 private:
  bool pending=false;
  uint32_t delayMs=500, nextAttemptAt=0;
};
}  // namespace hidpilot
