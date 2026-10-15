#pragma once
#include <stdint.h>

// Shared by the firmware and host regression tests; no Arduino dependencies.
namespace hidpilot {
inline bool timeBefore(uint32_t now, uint32_t deadline) {
  return (int32_t)(deadline-now)>0;
}
inline bool asciiKey(char c,uint8_t &key,uint8_t &mods) {
  mods=0; key=0;
  if(c < 32 || c > 126) return false;
  if(c>='a'&&c<='z') {key=4+c-'a';return true;}
  if(c>='A'&&c<='Z') {key=4+c-'A';mods=2;return true;}
  if(c>='1'&&c<='9') {key=30+c-'1';return true;}
  if(c=='0') {key=39;return true;}
  switch(c) {
    case ' ':key=44;return true;
  }
  const char *plain="-=[]\\;'`,./";
  const char *shift="_+{}|:\"~<>?";
  const uint8_t usage[]={45,46,47,48,49,51,52,53,54,55,56};
  for(unsigned i=0;i<11;i++) {
    if(c==plain[i]){key=usage[i];return true;}
    if(c==shift[i]){key=usage[i];mods=2;return true;}
  }
  const char *numbers="!@#$%^&*()";
  for(unsigned i=0;i<10;i++) if(c==numbers[i]) {key=i==9?39:30+i;mods=2;return true;}
  return false;
}

}
