#pragma once
#include <stdint.h>
namespace hidpilot {
struct AbsolutePosition {uint16_t x=0,y=0;};
// Relative LAN units remain relative: integrate each accepted delta, then clamp.
// The initial estimate may only be created by an explicit calibration move.
class RelativeAbsoluteAdapter {
  bool valid_=false;
  AbsolutePosition position_;
  static uint16_t clamp(int value){return value<0?0:value>10000?10000:static_cast<uint16_t>(value);}
 public:
  static constexpr int STEP=40;
  bool known()const{return valid_;}
  bool read(AbsolutePosition &out)const {if(!valid_)return false;out=position_;return true;}
  void invalidate(){valid_=false;}
  bool plan(int dx,int dy,bool calibrationMove,AbsolutePosition &out)const {
    if(!valid_&&(!calibrationMove||(dx==0&&dy==0)))return false;
    const int x=valid_?position_.x:5000,y=valid_?position_.y:5000;
    out.x=clamp(x+dx*STEP);out.y=clamp(y+dy*STEP);return true;
  }
  void commit(const AbsolutePosition &value){position_=value;valid_=true;}
};
}
