#include "../firmware/IPhoneHIDBridge/ProtocolPrimitives.h"
#include <cassert>
#include <cstdio>
int main() {
  using hidpilot::acceptAuthentication;
  // Reproduce prior logic: first success closes the window, then a duplicate
  // successful ENC_CHANGE is incorrectly rejected despite the same secure link.
  bool connected=true, secure=true, window=true, encrypted=false;
  assert(connected && secure && window);
  encrypted=true;window=false;
  assert(!(connected && secure && window)); // old callback disconnects
  assert(acceptAuthentication(connected,secure,window,encrypted));
  // Truth table: only an open window or this link's prior authentication admits.
  for(int c=0;c<2;c++)for(int s=0;s<2;s++)for(int w=0;w<2;w++)for(int p=0;p<2;p++)
    assert(acceptAuthentication(c,s,w,p)==(c&&s&&(w||p)));
  // Connection callbacks clear encrypted before admitting a new connection.
  encrypted=false;
  assert(!acceptAuthentication(true,true,false,encrypted));
  assert(acceptAuthentication(true,true,true,encrypted));
  assert(!acceptAuthentication(true,false,true,true));
  assert(!acceptAuthentication(false,true,true,true));
  assert(hidpilot::controlLeaseMs(true,300000)==60000);
  assert(hidpilot::controlLeaseMs(false,300000)==300000);
  assert(hidpilot::controlLeaseMs(true,10000)==10000);
  for(int x=-127;x<=127;x++)for(int y=-127;y<=127;y++)
    assert(hidpilot::calibrationMoveAllowed(x,y)==(x>=-10&&x<=10&&y>=-10&&y<=10));
  puts("Authentication regression and fail-closed truth table passed");
}
