export function validateDevice(chip, flashKB) {
  if(chip !== 'ESP32-C3') throw Error('芯片不匹配：仅支持 ESP32-C3。');
  if(!Number.isFinite(flashKB) || flashKB < 4096) throw Error('Flash 容量未知或小于 4MB，已阻止烧录。');
}
export function validateManifest(m,mode) {
  if(m.version!=='0.2.0-c3'||!Array.isArray(m.builds))throw Error('无效 manifest');
  const b=m.builds.find(b=>b.variant===mode);
  if(!b||b.chipFamily!=='ESP32-C3'||b.parts.length!==1||b.parts[0].offset!==0||!/^[a-f0-9]{64}$/.test(b.parts[0].sha256))throw Error('镜像元数据不匹配');
  if(!/^firmware\/[a-z0-9.-]+\.bin$/.test(b.parts[0].path))throw Error('镜像路径不安全');
  return b;
}
export function validateImage(bytes) {
  if(bytes.length<65560||bytes.length>4*1024*1024||bytes[0]!==0xe9||bytes[12]!==5||bytes[13]!==0||bytes[65536]!==0xe9||bytes[65548]!==5||bytes[65549]!==0||bytes[2]!==2||bytes[3]!==0x20||bytes[0x8000]!==0xaa||bytes[0x8001]!==0x50)throw Error('镜像不是有效的 C3 合并镜像');
}
