// Experimental S3-only wired transport. No Wi-Fi AP, BLE, OTA or plaintext control API.
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
#include <unistd.h>
#include <net/if.h>
#include "sdkconfig.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "driver/gpio.h"
#include "esp_event.h"
#include "esp_http_server.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "bootloader_random.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "cJSON.h"
#include "protocomm.h"
#include "protocomm_security2.h"
#include "session.pb-c.h"
#include "mbedtls/platform_util.h"
#include "usb_link.h"
#include "pairing_verifier.h"
#include "wifi_link.h"
#include "lwip/sockets.h"
#include "lwip/inet.h"
#if !CONFIG_IDF_TARGET_ESP32S3
#error "USB NCM+HID requires ESP32-S3. ESP32-C3 Serial/JTAG cannot run this target."
#endif
#if CONFIG_SIGHTLATCH_PAIR_GPIO == 19 || CONFIG_SIGHTLATCH_PAIR_GPIO == 20
#error "Pair button cannot use USB D-/D+ GPIO19/20"
#endif

static SemaphoreHandle_t lock;
static protocomm_t *pc;
static httpd_handle_t server;
static nvs_handle_t store;
static uint8_t salt[32], verifier[384];
static protocomm_security2_params_t sec = {
    .salt=(const char *)salt, .salt_len=sizeof(salt),
    .verifier=(const char *)verifier, .verifier_len=sizeof(verifier)
};
static int64_t pair_until, session_until, armed_until;
static uint32_t next_sequence=1;
static char control_token[129], wifi_ssid[33], wifi_password[64];
static bool wifi_apply_pending, handshake_in_progress, wifi_transition;
static bool configured, armed, provisioned_in_window;
static bool release_requested=true;
static struct { bool active, sent; int kind,a,b,c; int64_t expires, release_at; } job;
static int64_t now_ms(void) { return esp_timer_get_time()/1000; }
static void disarm(void) { armed=false; armed_until=0; memset(&job,0,sizeof(job)); release_requested=true; }
static bool pairing_open(void) { return now_ms()<pair_until; }
static const char *str(cJSON *o,const char *key) {
    cJSON *v=cJSON_GetObjectItemCaseSensitive(o,key);
    return cJSON_IsString(v)?v->valuestring:NULL;
}
static bool integer(cJSON *o,const char *key,int low,int high,int *out) {
    cJSON *v=cJSON_GetObjectItemCaseSensitive(o,key);
    if(!cJSON_IsNumber(v)||v->valuedouble<low||v->valuedouble>high||v->valuedouble!=(int)v->valuedouble) return false;
    *out=(int)v->valuedouble;return true;
}
static bool ascii(const char *p,size_t low,size_t high) {
    if(!p) return false;
    size_t n=strlen(p); if(n<low||n>high) return false;
    for(size_t i=0;i<n;i++) if((unsigned char)p[i]<32||(unsigned char)p[i]>126) return false;
    return true;
}
static bool token_matches(const char *token) {
    if(!token||strlen(token)>128) return false;
    unsigned diff=(unsigned)(strlen(token)^strlen(control_token));
    size_t n=strlen(token),m=strlen(control_token);
    for(size_t i=0;i<128;i++) diff|=(i<n?(unsigned char)token[i]:0)^(i<m?(unsigned char)control_token[i]:0);
    return configured && diff==0;
}
static esp_err_t reply(const char *error,uint8_t **out,ssize_t *len) {
    cJSON *r=cJSON_CreateObject(); if(!r) return ESP_ERR_NO_MEM;
    cJSON_AddBoolToObject(r,"ok",error==NULL);
    if(error) cJSON_AddStringToObject(r,"error",error);
    cJSON_AddBoolToObject(r,"configured",configured);
    cJSON_AddBoolToObject(r,"wifi_connected",wifi_link_connected());
    cJSON_AddStringToObject(r,"wifi_state",wifi_link_state());
    cJSON_AddBoolToObject(r,"armed",armed);
    cJSON_AddBoolToObject(r,"hid_connected",usb_link_ready());
    cJSON_AddBoolToObject(r,"pairing_open",pairing_open());
    cJSON_AddNumberToObject(r,"next_sequence",next_sequence);
    cJSON_AddStringToObject(r,"transport","usb_ncm_hid_experimental");
    char *s=cJSON_PrintUnformatted(r);cJSON_Delete(r);
    if(!s) return ESP_ERR_NO_MEM;
    *out=(uint8_t *)s;*len=strlen(s);return ESP_OK;
}
static esp_err_t command(uint32_t session_id,const uint8_t *in,ssize_t len,uint8_t **out,ssize_t *outlen,void *ctx) {
    (void)session_id;(void)ctx;
    if(len<2||len>1024) return ESP_ERR_INVALID_SIZE;
    char *body=calloc(1,(size_t)len+1);if(!body)return ESP_ERR_NO_MEM;
    memcpy(body,in,len);
    cJSON *o=cJSON_ParseWithOpts(body,NULL,true);
    mbedtls_platform_zeroize(body,(size_t)len);free(body);
    if(!cJSON_IsObject(o)){cJSON_Delete(o);return ESP_ERR_INVALID_ARG;}
    xSemaphoreTake(lock,portMAX_DELAY);
    const char *error=NULL,*op=str(o,"op");int seq=0;
    if(now_ms()>=session_until) error="session_expired";
    else if(!integer(o,"sequence",1,INT32_MAX,&seq)||(uint32_t)seq!=next_sequence) error="sequence_mismatch";
    else {
        // Consume even rejected operations. Never replay an uncertain request.
        next_sequence++;
        if(!op) error="invalid_operation";
        else if(strcmp(op,"provision")==0) {
            const char *ssid=str(o,"ssid"),*password=str(o,"password"),*token=str(o,"token");
            if(!pairing_open()||provisioned_in_window) error="physical_window_closed";
            else if(!ssid||strlen(ssid)<1||strlen(ssid)>32||!password||
                    !(password[0]==0||ascii(password,8,63))||!ascii(token,32,128)) error="invalid_configuration";
            else {
                cJSON *record=cJSON_CreateObject();
                bool complete=record && cJSON_AddStringToObject(record,"ssid",ssid) &&
                    cJSON_AddStringToObject(record,"password",password) && cJSON_AddStringToObject(record,"token",token);
                char *encoded=complete?cJSON_PrintUnformatted(record):NULL;
                esp_err_t e=encoded?nvs_set_str(store,"config",encoded):ESP_ERR_NO_MEM;
                if(e==ESP_OK)e=nvs_commit(store);
                if(encoded){mbedtls_platform_zeroize(encoded,strlen(encoded));free(encoded);}cJSON_Delete(record);
                if(e!=ESP_OK)error="storage_failed";
                else {strlcpy(control_token,token,sizeof(control_token));strlcpy(wifi_ssid,ssid,sizeof(wifi_ssid));strlcpy(wifi_password,password,sizeof(wifi_password));wifi_apply_pending=true;configured=true;provisioned_in_window=true;pair_until=0;disarm();}
            }
        } else if(!token_matches(str(o,"token"))) error="unauthorized";
        else if(strcmp(op,"status")==0) { /* no side effect */ }
        else if(strcmp(op,"stop")==0) disarm();
        else if(strcmp(op,"arm")==0) {
            if(wifi_transition)error="wifi_transition";
            else if(!usb_link_ready())error="hid_unavailable";
            else {disarm();armed=true;armed_until=now_ms()+60000;}
        } else if(!armed||now_ms()>=armed_until) error="not_armed";
        else if(!usb_link_ready())error="hid_unavailable";
        else if(job.active)error="busy";
        else {
            int a=0,b=0,c=0,kind=0;
            if(strcmp(op,"move")==0&&integer(o,"dx",-127,127,&a)&&integer(o,"dy",-127,127,&b))kind=1;
            else if(strcmp(op,"click")==0&&integer(o,"button",1,4,&a)&&(a==1||a==2||a==4))kind=2;
            else if(strcmp(op,"key")==0&&integer(o,"usage",4,101,&a)&&integer(o,"modifiers",0,255,&b))kind=3;
            else error="invalid_action";
            if(!error){job.active=true;job.sent=false;job.kind=kind;job.a=a;job.b=b;job.c=c;job.expires=now_ms()+1000;}
        }
    }
    esp_err_t result=reply(error,out,outlen);
    xSemaphoreGive(lock);
    // cJSON stores decoded secrets separately. Clear strings before freeing them.
    for(cJSON *v=o->child;v;v=v->next)if(cJSON_IsString(v)&&v->valuestring)mbedtls_platform_zeroize(v->valuestring,strlen(v->valuestring));
    cJSON_Delete(o);return result;
}
// Validate protobuf oneof shape before IDF5.5.2 Security2 dereferences sc0/sc1.
static bool valid_handshake(const uint8_t *body,size_t length) {
    SessionData *m=session_data__unpack(NULL,length,body);bool valid=false;
    if(m && m->sec_ver==SEC_SCHEME_VERSION__SecScheme2 &&
       m->proto_case==SESSION_DATA__PROTO_SEC2 && m->sec2){
        Sec2Payload *p=m->sec2;
        if(p->msg==SEC2_MSG_TYPE__S2Session_Command0 && p->payload_case==SEC2_PAYLOAD__PAYLOAD_SC0 && p->sc0)
            valid=p->sc0->client_username.len==10 && p->sc0->client_username.data &&
                memcmp(p->sc0->client_username.data,"sightlatch",10)==0 &&
                p->sc0->client_pubkey.len==384 && p->sc0->client_pubkey.data;
        else if(p->msg==SEC2_MSG_TYPE__S2Session_Command1 && p->payload_case==SEC2_PAYLOAD__PAYLOAD_SC1 && p->sc1)
            valid=p->sc1->client_proof.len==64 && p->sc1->client_proof.data;
    }
    if(m)session_data__free_unpacked(m,NULL);
    return valid;
}
static esp_err_t usb_socket_open(httpd_handle_t handle,int fd) {
    (void)handle;
    struct ifreq interface={0};
    esp_netif_t *netif=esp_netif_get_handle_from_ifkey("USB_NCM");
    if(!netif || esp_netif_get_netif_impl_name(netif,interface.ifr_name)!=ESP_OK)return ESP_FAIL;
    // Bind accepted TCP PCB before reading any request. Local IP check below is
    // extra defense, not an interface authenticator (lwIP is otherwise weak-host).
    return setsockopt(fd,SOL_SOCKET,SO_BINDTODEVICE,&interface,sizeof(interface))==0?ESP_OK:ESP_FAIL;
}
static esp_err_t http_request(httpd_req_t *req) {
    // esp_http_server listens on all interfaces. Never accept this API via STA:
    // inspect the LOCAL socket address (not attacker-supplied Host headers).
    struct sockaddr_in local={0};socklen_t address_len=sizeof(local);
    if(getsockname(httpd_req_to_sockfd(req),(struct sockaddr *)&local,&address_len)!=0 ||
       local.sin_family!=AF_INET || local.sin_addr.s_addr!=inet_addr("192.168.7.1")){
        httpd_resp_send_err(req,HTTPD_403_FORBIDDEN,"USB interface required");return ESP_FAIL;
    }
    // Exactly one Security2 logical session per physical window, independent of
    // HTTP TCP reconnects. No cookies or security0 fallback. AES-GCM counters
    // authenticate and order all post-handshake bodies via official protocomm.
    bool handshake=strcmp(req->uri,"/prov-session")==0;
    xSemaphoreTake(lock,portMAX_DELAY);
    bool allowed=now_ms()<session_until&&(!handshake||pairing_open());
    xSemaphoreGive(lock);
    if(!allowed){httpd_resp_send_err(req,HTTPD_403_FORBIDDEN,"physical window or session closed");return ESP_OK;}
    if(req->content_len<(handshake?1:18)||req->content_len>2048){httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"body size");return ESP_FAIL;}
    uint8_t *body=malloc(req->content_len);if(!body)return ESP_ERR_NO_MEM;
    size_t have=0;int64_t read_deadline=now_ms()+3000;
    while(have<req->content_len){
        if(now_ms()>=read_deadline){free(body);return ESP_FAIL;}
        int n=httpd_req_recv(req,(char *)body+have,req->content_len-have);
        if(n<=0){free(body);return ESP_FAIL;}have+=(size_t)n;
    }
    xSemaphoreTake(lock,portMAX_DELAY);
    allowed=now_ms()<session_until&&(!handshake||pairing_open());
    xSemaphoreGive(lock);
    if(!allowed){free(body);return ESP_FAIL;}
    uint8_t *out=NULL;ssize_t outlen=0;
    if(handshake && !valid_handshake(body,have)){free(body);httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"invalid handshake");return ESP_FAIL;}
    // With RF disabled, enable S3 internal entropy while Security2 creates SRP
    // secrets and the GCM session ID. No application ADC/RF users in this target.
    if(handshake){
        xSemaphoreTake(lock,portMAX_DELAY);
        if(!pairing_open()){xSemaphoreGive(lock);free(body);return ESP_FAIL;}
        handshake_in_progress=true;
        xSemaphoreGive(lock);
        bootloader_random_enable();
    }
    esp_err_t e=protocomm_req_handle(pc,handshake?"prov-session":"usb-command",1,body,have,&out,&outlen);
    if(handshake){
        bootloader_random_disable();
        xSemaphoreTake(lock,portMAX_DELAY);handshake_in_progress=false;xSemaphoreGive(lock);
    }
    mbedtls_platform_zeroize(body,have);free(body);
    httpd_resp_set_hdr(req,"Cache-Control","no-store");
    httpd_resp_set_type(req,"application/octet-stream");
    if(e==ESP_OK)e=httpd_resp_send(req,(const char *)out,outlen);
    else {httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"secure session rejected");e=ESP_FAIL;}
    free(out);return e;
}
static void open_pairing(void) {
    // Main task only. Stop old HTTP task before replacing security material.
    if(server){httpd_stop(server);server=NULL;}
    // Pause STA before using the S3 internal ADC entropy source. Do not start
    // authentication if RF shutdown failed. Restore STA after the window closes.
    if(wifi_link_pause()!=ESP_OK){
        xSemaphoreTake(lock,portMAX_DELAY);disarm();pair_until=0;session_until=0;xSemaphoreGive(lock);
        return;
    }
    wifi_apply_pending=configured;
    if(pc){protocomm_close_session(pc,1);protocomm_delete(pc);pc=NULL;}
    xSemaphoreTake(lock,portMAX_DELAY);disarm();pair_until=0;session_until=0;xSemaphoreGive(lock);
    usb_link_release();
    nvs_handle_t factory;size_t ns=sizeof(salt),nv=sizeof(verifier);bool labeled=false;
    if(nvs_flash_init_partition("sl_factory")==ESP_OK &&
       nvs_open_from_partition("sl_factory","sl_usb_factory",NVS_READONLY,&factory)==ESP_OK){
        labeled=nvs_get_blob(factory,"salt",salt,&ns)==ESP_OK&&ns==sizeof(salt)&&
                nvs_get_blob(factory,"verifier",verifier,&nv)==ESP_OK&&nv==sizeof(verifier);nvs_close(factory);
    }
    #if !CONFIG_SIGHTLATCH_ALLOW_UART_PAIRING
    if(!labeled){
        puts("SightLatch: trusted device label not provisioned; USB pairing remains closed.");
        return;
    }
    #endif
    char pop[33]={0};
    if(!labeled){
        uint8_t random[16];bootloader_random_enable();esp_fill_random(random,sizeof(random));esp_fill_random(salt,sizeof(salt));bootloader_random_disable();
        for(unsigned i=0;i<sizeof(random);i++)snprintf(pop+2*i,3,"%02x",random[i]);
        mbedtls_platform_zeroize(random,sizeof(random));
        if(pairing_verifier(pop,salt,verifier)!=ESP_OK){mbedtls_platform_zeroize(pop,sizeof(pop));return;}
    }
    pc=protocomm_new();if(!pc)abort();
    ESP_ERROR_CHECK(protocomm_set_security(pc,"prov-session",&protocomm_security2,&sec));
    ESP_ERROR_CHECK(protocomm_add_endpoint(pc,"usb-command",command,NULL));
    ESP_ERROR_CHECK(protocomm_open_session(pc,1));
    httpd_config_t cfg=HTTPD_DEFAULT_CONFIG();cfg.stack_size=12288;cfg.max_open_sockets=2;cfg.recv_wait_timeout=3;cfg.send_wait_timeout=3;cfg.open_fn=usb_socket_open;
    ESP_ERROR_CHECK(httpd_start(&server,&cfg));
    const httpd_uri_t session_uri={.uri="/prov-session",.method=HTTP_POST,.handler=http_request};
    const httpd_uri_t command_uri={.uri="/usb-command",.method=HTTP_POST,.handler=http_request};
    ESP_ERROR_CHECK(httpd_register_uri_handler(server,&session_uri));ESP_ERROR_CHECK(httpd_register_uri_handler(server,&command_uri));
    xSemaphoreTake(lock,portMAX_DELAY);pair_until=now_ms()+60000;session_until=now_ms()+300000;next_sequence=1;provisioned_in_window=false;xSemaphoreGive(lock);
    // Deliberate local-only out-of-band code display, never a Wi-Fi/control token.
    // Production labeled units need no UART; development units need a second device.
    if(!labeled)printf("SightLatch temporary pairing code (60s; do not record): %s\n",pop);
    else puts("SightLatch: enter the device label code in the iPhone app within 60s.");
    mbedtls_platform_zeroize(pop,sizeof(pop));
}
void app_main(void) {
    // Do not erase NVS automatically on errors: preserving existing credentials matters.
    ESP_ERROR_CHECK(nvs_flash_init());ESP_ERROR_CHECK(nvs_open("sightlatch",NVS_READWRITE,&store));
    size_t size=0;if(nvs_get_str(store,"config",NULL,&size)==ESP_OK&&size>0&&size<=1024){
        char *s=malloc(size);if(s&&nvs_get_str(store,"config",s,&size)==ESP_OK){cJSON *r=cJSON_Parse(s);const char *t=str(r,"token"),*ssid=str(r,"ssid"),*password=str(r,"password");if(ascii(t,32,128)&&ssid&&strlen(ssid)>0&&strlen(ssid)<=32&&password&&(password[0]==0||ascii(password,8,63))){strlcpy(control_token,t,sizeof(control_token));strlcpy(wifi_ssid,ssid,sizeof(wifi_ssid));strlcpy(wifi_password,password,sizeof(wifi_password));configured=true;wifi_apply_pending=true;}if(r){for(cJSON *v=r->child;v;v=v->next)if(cJSON_IsString(v))mbedtls_platform_zeroize(v->valuestring,strlen(v->valuestring));cJSON_Delete(r);}mbedtls_platform_zeroize(s,size);}free(s);
    }
    lock=xSemaphoreCreateMutex();assert(lock);
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    ESP_ERROR_CHECK(usb_link_init());
    ESP_ERROR_CHECK(wifi_link_init());
    gpio_config_t io={.pin_bit_mask=1ULL<<CONFIG_SIGHTLATCH_PAIR_GPIO,.mode=GPIO_MODE_INPUT,.pull_up_en=GPIO_PULLUP_ENABLE};ESP_ERROR_CHECK(gpio_config(&io));
    puts("SightLatch USB experimental: hold physical button 3s to pair; any press stops HID.");
    int64_t pressed=0;bool opened=false,was_ready=false;
    for(;;){
        int64_t now=now_ms();bool down=gpio_get_level(CONFIG_SIGHTLATCH_PAIR_GPIO)==0;
        xSemaphoreTake(lock,portMAX_DELAY);
        bool ready=usb_link_ready();
        if(ready&&!was_ready)release_requested=true;
        was_ready=ready;
        if((down||!ready||now>=armed_until||now>=session_until)&&(armed||job.active))disarm();
        if(release_requested)release_requested=!usb_link_release();
        if(job.active&&!release_requested){
            if(now>=job.expires){disarm();release_requested=!usb_link_release();}
            else if(!job.sent){
                bool sent=job.kind==3?usb_link_keyboard(job.a,job.b):usb_link_mouse(job.kind==2?job.a:0,job.kind==1?job.a:0,job.kind==1?job.b:0,0);
                if(sent){job.sent=true;job.release_at=now+40;if(job.kind==1)job.active=false;}
            } else if(now>=job.release_at){release_requested=!usb_link_release();job.active=false;}
        }
        bool apply_wifi=wifi_apply_pending&&!pairing_open()&&!handshake_in_progress&&!armed&&!job.active&&!release_requested;
        char apply_ssid[33]={0},apply_password[64]={0};
        if(apply_wifi){wifi_transition=true;strlcpy(apply_ssid,wifi_ssid,sizeof(apply_ssid));strlcpy(apply_password,wifi_password,sizeof(apply_password));wifi_apply_pending=false;}
        xSemaphoreGive(lock);
        if(apply_wifi){
            // Only one attempt per boot/configuration/window, never an unbounded retry loop.
            (void)wifi_link_apply(apply_ssid,apply_password);
            xSemaphoreTake(lock,portMAX_DELAY);wifi_transition=false;xSemaphoreGive(lock);
            mbedtls_platform_zeroize(apply_password,sizeof(apply_password));
            mbedtls_platform_zeroize(apply_ssid,sizeof(apply_ssid));
        }
        if(down){if(!pressed)pressed=now;if(!opened&&now-pressed>=3000){opened=true;open_pairing();}}
        else {pressed=0;opened=false;}
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
