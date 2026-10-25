#!/usr/bin/env python3
"""Run the actual public identity function with deterministic SDK boundaries."""
from pathlib import Path
import hashlib,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
header=(root/'firmware/c3-web/IPhoneHIDBridge/PublicIdentity.h').read_text()
function=header[header.index('inline bool configurePublicIdentity()'):]
chips=[bytes((2,0,0,0,0,1)),bytes((2,0,0,0,0,2))]
def array(data):return ','.join(str(x) for x in data)
digests=[hashlib.sha256(b'SightLatch-C3-public-BLE-v1'+chip).digest() for chip in chips]
harness=r'''
#include <array>
#include <cassert>
#include <cstring>
#include <cstdint>
#include <iostream>
static int chipIndex=0,macResult=0,hashResult=0,addrCalls=0,typeCalls=0;
static bool addrResult=true,typeResult=true;
static constexpr int ESP_OK=0,BLE_OWN_ADDR_RANDOM=1;
static const uint8_t chips[2][6]={CHIPS};
static const uint8_t digests[2][32]={DIGESTS};
static int esp_efuse_mac_get_default(uint8_t* value){memcpy(value,chips[chipIndex],6);return macResult;}
static int mbedtls_sha256(const uint8_t* input,size_t size,uint8_t* out,int is224){
 static const char domain[]="SightLatch-C3-public-BLE-v1";
 assert(!is224&&size==sizeof(domain)-1+6);
 assert(memcmp(input,domain,sizeof(domain)-1)==0&&memcmp(input+sizeof(domain)-1,chips[chipIndex],6)==0);
 memcpy(out,digests[chipIndex],32);return hashResult;
}
struct NimBLEDevice {
 static std::array<uint8_t,6> last;
 static bool setOwnAddr(uint8_t* value){addrCalls++;memcpy(last.data(),value,6);return addrResult;}
 static bool setOwnAddrType(int type){typeCalls++;assert(type==BLE_OWN_ADDR_RANDOM);return typeResult;}
};
std::array<uint8_t,6>NimBLEDevice::last{};
PRODUCTION
static void reset(){macResult=hashResult=addrCalls=typeCalls=0;addrResult=typeResult=true;}
int main(){
 reset();assert(configurePublicIdentity());auto first=NimBLEDevice::last;
 assert((first[5]&0xc0)==0xc0&&(first[0]&3)==1&&addrCalls==1&&typeCalls==1);
 assert(configurePublicIdentity()&&NimBLEDevice::last==first);
 chipIndex=1;assert(configurePublicIdentity()&&NimBLEDevice::last!=first);
 reset();macResult=-1;assert(!configurePublicIdentity()&&!addrCalls&&!typeCalls);
 reset();hashResult=-1;assert(!configurePublicIdentity()&&!addrCalls&&!typeCalls);
 reset();addrResult=false;assert(!configurePublicIdentity()&&addrCalls==1&&!typeCalls);
 reset();typeResult=false;assert(!configurePublicIdentity()&&addrCalls==1&&typeCalls==1);
 std::cout<<"PASS actual public identity: domain/factory-input, per-chip stability, static-random bits and fail-closed SDK errors; no device access\n";
}
'''.replace('CHIPS',','.join('{'+array(x)+'}' for x in chips)).replace('DIGESTS',','.join('{'+array(x)+'}' for x in digests)).replace('PRODUCTION',function)
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'test.cpp';p.write_text(harness);binary=Path(tmp)/'test'
 subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror',str(p),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
