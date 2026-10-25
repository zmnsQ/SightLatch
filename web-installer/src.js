import {ESPLoader,Transport} from 'esptool-js';
import SparkMD5 from 'spark-md5';
import {families,validateDevice,validateImage,validateManifest,validateUpdateManifest,validateApplication} from './validation.js';
import {deviceDiagnostics} from './validation.js';
import './style.css';
const $=id=>document.getElementById(id);
let loader,transport,manifest,busy=false;
const supported=isSecureContext&&("serial" in navigator);
const log=s=>{$('log').textContent=($('log').textContent+'\n'+s).slice(-14000);};
function releaseLabels(){if(!manifest)return;try{const b=validateManifest(manifest,$('serialMode').value,$('chipFamily').value),v=b.version||manifest.version,latest=v==='0.3.3-c3-web';$('version').textContent='所选版本 '+v+' · '+b.chipFamily+' / '+b.variant+' · '+(latest?'公开C3测试版，尚无实板回归；Wi-Fi/LAN掉线问题未解决':'历史版本，未升级为0.3.3');$('upgrade').textContent='保留配置升级到 '+v;$('updateTitle').textContent=latest?'已有C3安装？保留配置升级':'已安装0.2.2？历史保配置升级';$('updateDescription').textContent=latest?'仅更新应用；保留Wi-Fi和控制令牌。会先核对bootloader与分区，布局不符则拒绝。公开版使用每芯片稳定蓝牙身份，升级后可能需要忘记旧蓝牙记录、重新配对并校准。':'仅适用于此前安装本页0.2.2的兼容布局；只读核对bootloader和分区，仅更新应用。';}catch(e){$('version').textContent=message(e);}}
function state(){releaseLabels();for(const id of ['connect','configure','readStatus','serialMode','chipFamily','updateConsent'])$(id).disabled=busy||!supported; $('disconnect').disabled=busy||!transport;$('flash').disabled=busy||!supported||!loader||!manifest||!$('consent').checked;let updateAvailable=false;try{validateUpdateManifest(manifest,$('serialMode').value,$('chipFamily').value);updateAvailable=true;}catch{}$('upgrade').disabled=busy||!supported||!updateAvailable||!$('updateConsent').checked;}
async function disconnect(){loader=null;if(transport){try{await transport.disconnect();}finally{transport=null;}}state();}
function message(e){return e?.name==='NotFoundError'?'已取消选择设备。':String(e?.message||e);}
async function run(task,target='status'){if(busy)return;busy=true;state();try{await task();}catch(e){$(target).textContent=message(e);log(message(e));try{await disconnect();}catch{} }finally{busy=false;state();}}
$('consent').onchange=state;
$('updateConsent').onchange=state;
$('chipFamily').onchange=()=>run(async()=>{await disconnect();$('consent').checked=false;$('updateConsent').checked=false;const classic=$('chipFamily').value==='ESP32';$('serialMode').querySelector('[value=usb]').disabled=classic;if(classic)$('serialMode').value='uart';$('device').textContent='芯片选择已更改，请重新识别。';});
$('serialMode').onchange=()=>{$('consent').checked=false;$('updateConsent').checked=false;state();};
$('disconnect').onclick=()=>run(async()=>{await disconnect();$('device').textContent='已断开。若停在下载模式，请按 RESET。';});
$('connect').onclick=()=>run(async()=>{
  await disconnect();const port=await navigator.serial.requestPort();transport=new Transport(port,false);
  loader=new ESPLoader({transport,baudrate:115200,romBaudrate:115200,terminal:{clean(){},write:log,writeLine:log},debugLogging:false});
  $('status').textContent='正在识别芯片（会重启板子）…';await loader.main();
  const kb=await loader.getFlashSize();validateDevice(loader.chip.CHIP_NAME,kb,$('chipFamily').value);
  $('device').textContent=`${loader.chip.CHIP_NAME} · ${kb/1024}MB Flash · DIO / ${families[loader.chip.CHIP_NAME].frequency} / 4MB布局`;
  $('status').textContent='识别通过。请核对串口接口类型、勾选擦除确认后安装。';
});
$('flash').onclick=()=>run(async()=>{
  if(!loader||!$('consent').checked)throw Error('请先识别设备并确认擦除。');
  validateDevice(loader.chip.CHIP_NAME,await loader.getFlashSize(),$('chipFamily').value);
  const build=validateManifest(manifest,$('serialMode').value,loader.chip.CHIP_NAME),part=build.parts[0];
  if(!window.confirm(`安装 ${build.version||manifest.version}（${build.variant}）会永久清空这块 ${build.chipFamily} 的全部 Flash。确定继续？`))return;
  const res=await fetch(new URL(part.path,document.baseURI),{cache:'no-store'});if(!res.ok)throw Error('镜像下载失败');
  const bytes=new Uint8Array(await res.arrayBuffer());validateImage(bytes,build.chipFamily);
  const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),x=>x.toString(16).padStart(2,'0')).join('');
  if(hash!==part.sha256)throw Error('SHA-256不匹配，未擦写。');
  let binary='';for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));
  $('status').textContent='镜像校验通过，正在擦除和写入。请勿拔线。';
  await loader.writeFlash({fileArray:[{data:binary,address:0}],flashSize:'4MB',flashMode:'dio',flashFreq:families[build.chipFamily].frequency,eraseAll:true,compress:true,calculateMD5Hash:data=>SparkMD5.hashBinary(data),reportProgress:(_,n,total)=>{$('progress').value=n/total*100;}});
  await loader.after('hard_reset');await disconnect();$('consent').checked=false;
  $('status').textContent='写入及MD5校验完成。请复位或重新插USB，然后设置Wi-Fi。BLE/iPhone功能仍待真机验证。';
});
const sha256=async bytes=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),x=>x.toString(16).padStart(2,'0')).join('');
$('upgrade').onclick=()=>run(async()=>{
  if(!$('updateConsent').checked)throw Error('请先确认已有兼容布局，并选对芯片和USB接口。');
  const update=validateUpdateManifest(manifest,$('serialMode').value,$('chipFamily').value),app=update.application;
  $('upgradeStatus').textContent='正在校验应用镜像；尚未写入设备…';
  const response=await fetch(new URL(app.path,document.baseURI),{cache:'no-store'});
  if(!response.ok)throw Error('应用镜像下载失败，未写入。');
  const bytes=new Uint8Array(await response.arrayBuffer());validateApplication(bytes,update.chipFamily,app.size);
  if(await sha256(bytes)!==app.sha256)throw Error('应用SHA-256不匹配，未写入。');
  if(!loader){
    const port=await navigator.serial.requestPort();transport=new Transport(port,false);
    loader=new ESPLoader({transport,baudrate:115200,romBaudrate:115200,terminal:{clean(){},write:log,writeLine:log},debugLogging:false});
    await loader.main();
  }
  validateDevice(loader.chip.CHIP_NAME,await loader.getFlashSize(),update.chipFamily);
  $('upgradeStatus').textContent='正在只读核对bootloader和分区表；不读取Wi-Fi或令牌配置…';
  for(const range of [update.compatibility.bootloader,update.compatibility.partitions]){
    const current=await loader.readFlash(range.offset,range.size);
    if(current.length!==range.size||await sha256(current)!==range.sha256)throw Error('设备布局与此升级镜像不匹配，已停止，未擦写。请查看下方全新安装入口；不会自动清空配置。');
  }
  if(!window.confirm(`保留配置升级到${update.version}（${update.chipFamily} / ${update.variant}）？仅写入应用区，保留Wi-Fi、控制令牌和配对数据。下载模式无法检测旧固件版本；需要兼容本页核对的bootloader和分区；蓝牙身份变化时可能需要重新配对与校准。`)){
    await loader.after('hard_reset');await disconnect();$('upgradeStatus').textContent='已取消升级，未擦写。';return;
  }
  let binary='';for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));
  $('upgradeStatus').textContent='兼容检查通过，正在升级应用。请勿拔线…';
  await loader.writeFlash({fileArray:[{data:binary,address:0x10000}],flashSize:'4MB',flashMode:'dio',flashFreq:families[update.chipFamily].frequency,eraseAll:false,compress:true,calculateMD5Hash:data=>SparkMD5.hashBinary(data),reportProgress:(_,n,total)=>{$('progress').value=n/total*100;}});
  await loader.after('hard_reset');await disconnect();$('updateConsent').checked=false;
  $('upgradeStatus').textContent='应用写入及MD5校验完成，原配置区域未擦写。重新启动后读取状态核实所选版本；C3公开测试版可能需重新配对与校准，升级不等于真机功能已验收。';
},'upgradeStatus');
$('generate').onclick=()=>{$('token').value=Array.from(crypto.getRandomValues(new Uint8Array(32)),x=>x.toString(16).padStart(2,'0')).join('');};
$('show').onclick=()=>{$('token').type=$('token').type==='password'?'text':'password';};
async function serialCommand(command){
  await disconnect();const port=await navigator.serial.requestPort();let reader,writer;
  try{
    await port.open({baudRate:115200});writer=port.writable.getWriter();reader=port.readable.getReader();
    await writer.write(new TextEncoder().encode(JSON.stringify(command)+'\n'));writer.releaseLock();writer=null;
    let buffer='',finished=false;
    const timeout=setTimeout(()=>{if(!finished)reader.cancel().catch(()=>{});},10000);
    try{while(true){const {value,done}=await reader.read();if(done)throw Error('未收到确认。确认板子已正常启动，USB接口类型选择正确，然后读状态核实。');buffer+=new TextDecoder().decode(value,{stream:true});if(buffer.length>4096)buffer=buffer.slice(-4096);
      let i;while((i=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,i).trim();buffer=buffer.slice(i+1);let response;try{response=JSON.parse(line);}catch{continue;}
        if(response.ok===false)throw Error(`板子拒绝配置：${response.error}`);
        if(response.ok===true)return response;
      }
    }}finally{finished=true;clearTimeout(timeout);}
  }finally{if(writer)writer.releaseLock();if(reader){try{await reader.cancel();}catch{}reader.releaseLock();}try{await port.close();}catch{}}
}
$('config').onsubmit=e=>{e.preventDefault();run(async()=>{
  const ssid=$('ssid').value,password=$('password').value,token=$('token').value;
  if(new TextEncoder().encode(ssid).length>32||!/^[\x21-\x7e]{32,128}$/.test(token)||new TextEncoder().encode(password).length>63)throw Error('Wi-Fi名称最多32字节、密码最多63字节，令牌须32–128个可见ASCII字符。');
  if(!window.confirm('将当前Wi-Fi密码和控制令牌经USB保存到所选板子的未加密NVS，并重启。继续？'))return;
  $('configStatus').textContent='等待板子确认…';const r=await serialCommand({command:'configure',ssid,password,token});
  $('password').value='';$('configStatus').textContent=r.configured?'配置已保存，板子正在重启。等待连接Wi-Fi后，点读取IP。请把令牌填入App。':'请读取状态核实。';
},'configStatus');};
$('readStatus').onclick=()=>run(async()=>{const r=await serialCommand({command:'status'});$('configStatus').textContent=`固件 ${r.firmware_version} · 已配置：${r.configured?'是':'否'} · IP：${r.ip}（0.0.0.0表示尚未连上Wi-Fi）`;$('deviceDiagnostics').textContent=deviceDiagnostics(r);},'configStatus');
if(!isSecureContext||!('serial' in navigator)){for(const b of document.querySelectorAll('button'))b.disabled=true;$('status').textContent='需要电脑Chrome/Edge和HTTPS或localhost。iPhone Safari不支持本页串口烧录。';}
fetch(new URL('firmware/manifest.json',document.baseURI),{cache:'no-store'}).then(r=>{if(!r.ok)throw Error('manifest下载失败');return r.json();}).then(m=>{validateManifest(m,'usb');validateManifest(m,'uart');manifest=m;state();}).catch(e=>{$('version').textContent=message(e);$('flash').disabled=true;});
window.addEventListener('pagehide',()=>{$('password').value='';$('token').value='';});
