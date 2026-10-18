export const families = {'ESP32-C3':{chip:5,boot:0,frequency:'40m',header:0x20,modes:['usb','uart']},'ESP32':{chip:0,boot:0x1000,frequency:'40m',header:0x20,modes:['uart']},'ESP32-S3':{chip:9,boot:0,frequency:'80m',header:0x2f,modes:['usb','uart']}};
export function validateDevice(chip, flashKB, selected=chip) {
  if(!Object.hasOwn(families,chip)||chip!==selected) throw Error('芯片不匹配：仅支持所选 ESP32 / C3 / S3，S2 无 BLE。');
  if(!Number.isFinite(flashKB) || flashKB < 4096) throw Error('Flash 容量未知或小于 4MB，已阻止烧录。');
}
export function validateManifest(m,mode,family='ESP32-C3') {
  if(m.version!=='0.2.1'||!Array.isArray(m.builds))throw Error('无效 manifest');
  const spec=families[family];
  const matches=m.builds.filter(b=>b.variant===mode&&b.chipFamily===family),b=matches[0];
  if(!spec||!spec.modes.includes(mode)||matches.length!==1||!Array.isArray(b.parts)||b.parts.length!==1||b.parts[0].offset!==0||!/^[a-f0-9]{64}$/.test(b.parts[0].sha256))throw Error('镜像元数据不匹配');
  if(b.flashFrequency!==undefined&&b.flashFrequency!==spec.frequency)throw Error('Flash 频率不匹配');
  if(!/^firmware\/[a-z0-9.-]+\.bin$/.test(b.parts[0].path))throw Error('镜像路径不安全');
  return b;
}
export function validateImage(bytes,family='ESP32-C3') {
  const spec=families[family];
  if(!spec||bytes.length<65560||bytes.length>4194304)throw Error('镜像大小或芯片无效');
  for(const offset of [spec.boot,0x10000])if(bytes[offset]!==0xe9||bytes[offset+12]!==spec.chip||bytes[offset+13]!==0)throw Error('镜像芯片与目标不匹配');
  if(bytes[spec.boot+2]!==2||bytes[spec.boot+3]!==spec.header||bytes[0x8000]!==0xaa||bytes[0x8001]!==0x50)throw Error('镜像 Flash 参数或分区表不匹配');
}

// Only non-secret diagnostic scalars are presented; never dump configuration JSON.
export function deviceDiagnostics(status) {
  const out={};
  if(typeof status.boot_id==='string'&&/^[a-f0-9]{32}$/i.test(status.boot_id))out.boot_id=status.boot_id;
  for(const key of ['uptime_ms','reset_reason','auth_events','auth_rejects','disconnect_events','last_disconnect_reason','last_encryption_status','notify_events','notify_errors','last_notify_code','free_heap_bytes','min_free_heap_bytes','safety_stack_free_bytes'])
    if(typeof status[key]==='number'&&Number.isFinite(status[key]))out[key]=status[key];
  for(const key of ['ble_connected','hid_connected'])if(typeof status[key]==='boolean')out[key]=status[key];
  return JSON.stringify(out,null,2);
}
