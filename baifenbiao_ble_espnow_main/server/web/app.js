const MAX_METERS = 20;
const histories = new Map();
const meters = new Map();
let socket;
let lastPacketCount = 0;
let lastRateTime = Date.now();
let totalPackets = 0;
let meterConfig = null;
let serialPorts = [];

const grid = document.querySelector('#meterGrid');
const pad = n => String(n).padStart(2, '0');
const escapeHtml = value => String(value ?? '').replace(/[&<>'"]/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[char]));

for (let id = 1; id <= MAX_METERS; id++) {
  const card = document.createElement('article');
  card.className = 'meter-card';
  card.id = `meter-${id}`;
  card.innerHTML = `<div class="card-head"><div class="meter-name"><span class="meter-index">${pad(id)}</span>百分表 ${pad(id)}</div><div class="state"><i></i><span>待机</span></div></div><div class="reading"><strong>--.----</strong><small>mm</small><span class="protocol-note"></span></div><canvas class="spark"></canvas><div class="card-foot"><span>NODE <b class="node">--</b></span><span>RSSI <b class="signal">--</b></span><span>SEQ <b class="seq">--</b></span></div>`;
  grid.appendChild(card);
  histories.set(id, []);
}

function signalClass(rssi) { return rssi >= -65 ? 'good' : rssi >= -82 ? 'weak' : ''; }

function drawSpark(id) {
  const card = document.querySelector(`#meter-${id}`);
  const canvas = card.querySelector('canvas');
  const values = histories.get(id);
  const dpr = devicePixelRatio || 1;
  const w = canvas.clientWidth;
  const h = canvas.clientHeight;
  canvas.width = w * dpr;
  canvas.height = h * dpr;
  const ctx = canvas.getContext('2d');
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, w, h);
  ctx.strokeStyle = 'rgba(120,150,141,.13)';
  ctx.beginPath(); ctx.moveTo(0, h - 1); ctx.lineTo(w, h - 1); ctx.stroke();
  if (values.length < 2) return;
  let min = Math.min(...values), max = Math.max(...values);
  if (max - min < .002) { max += .001; min -= .001; }
  const grad = ctx.createLinearGradient(0, 0, w, 0);
  grad.addColorStop(0, 'rgba(11,157,107,.25)'); grad.addColorStop(1, '#0b9d6b');
  ctx.strokeStyle = grad; ctx.lineWidth = 1.5; ctx.beginPath();
  values.forEach((v, i) => {
    const x = i / (values.length - 1) * w;
    const y = h - 5 - (v - min) / (max - min) * (h - 10);
    i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
  });
  ctx.stroke();
}

function renderMeter(data) {
  const id = Number(data.meter_id);
  if (id < 1 || id > MAX_METERS) return;
  meters.set(id, data);
  const card = document.querySelector(`#meter-${id}`);
  const online = Date.now() - data.timestamp_ms < 3000;
  card.classList.toggle('online', online);
  card.querySelector('.state span').textContent = online ? '在线' : '离线';
  card.querySelector('.node').textContent = pad(data.node_id || 0);
  card.querySelector('.seq').textContent = data.sequence ?? '--';
  const signal = card.querySelector('.signal');
  signal.textContent = data.ble_rssi ? `${data.ble_rssi} dBm` : '--';
  signal.className = `signal ${signalClass(data.ble_rssi)}`;
  card.querySelector('.reading small').textContent = data.unit || 'mm';
  const note = card.querySelector('.protocol-note');
  if (data.valid) {
    card.querySelector('.reading strong').textContent = Number(data.value_mm).toFixed(4);
    note.textContent = '';
    const list = histories.get(id);
    list.push(Number(data.value_mm));
    if (list.length > 50) list.shift();
    drawSpark(id);
  } else {
    card.querySelector('.reading strong').textContent = '--.----';
    note.textContent = data.raw_hex ? '已收到原始数据 · 待解析协议' : '等待有效读数';
  }
  card.classList.remove('pulse');
  requestAnimationFrame(() => card.classList.add('pulse'));
}

function refreshOnline() {
  let online = 0;
  for (const [id, data] of meters) {
    const isOnline = Date.now() - data.timestamp_ms < 3000;
    const card = document.querySelector(`#meter-${id}`);
    card.classList.toggle('online', isOnline);
    card.querySelector('.state span').textContent = isOnline ? '在线' : '离线';
    if (isOnline) online++;
  }
  document.querySelector('#onlineCount').textContent = online;
}

function setGateway(ok, text) {
  document.querySelector('#gatewayDot').classList.toggle('online', ok);
  document.querySelector('#gatewayText').textContent = text;
  document.querySelector('#footerStatus').textContent = text;
}

function connect() {
  socket = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`);
  socket.onopen = () => setGateway(true, '服务已连接');
  socket.onmessage = event => {
    const msg = JSON.parse(event.data);
    if (msg.type === 'snapshot') {
      (msg.meters || []).forEach(renderMeter);
      totalPackets = msg.status?.total_packets || 0;
      if (msg.status?.simulate) setGateway(true, '演示数据');
      else if (msg.status?.serial_connected) setGateway(true, `主站串口 ${msg.status.serial_port}`);
    } else if (msg.type === 'measurement') {
      renderMeter(msg.data); totalPackets++;
    }
    document.querySelector('#packetCount').textContent = totalPackets.toLocaleString();
  };
  socket.onclose = () => { setGateway(false, '连接中断 · 重试中'); setTimeout(connect, 1800); };
  socket.onerror = () => socket.close();
}

async function api(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: {'Content-Type': 'application/json', ...(options.headers || {})},
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.detail || `请求失败 (${response.status})`);
  return data;
}

function showStatus(elementId, text, kind = '') {
  const element = document.querySelector(`#${elementId}`);
  element.textContent = text;
  element.className = `soft-status ${kind}`;
}

function appendLog(lines) {
  const log = document.querySelector('#operationLog');
  const text = Array.isArray(lines) ? lines.join('\n') : String(lines);
  log.textContent = log.textContent === '等待操作……' ? text : `${log.textContent}\n${text}`;
  log.scrollTop = log.scrollHeight;
}

function collectConfig() {
  const nodes = [...document.querySelectorAll('.node-config')].map(card => ({
    node_id: Number(card.dataset.nodeId),
    port: card.querySelector('.port-select').value,
    meters: [...card.querySelectorAll('.slot-row')].map(row => ({
      slot: Number(row.dataset.slot),
      meter_id: Number(row.querySelector('.meter-id-input').value),
      mac: row.querySelector('.mac-input').value.trim().toUpperCase().replaceAll('-', ':'),
      name: row.querySelector('.device-name-input').value.trim(),
    })),
  }));
  return {version: 1, nodes};
}

function portOptions(selected) {
  const samePort = (left, right) => /^COM\d+$/i.test(String(left)) && /^COM\d+$/i.test(String(right))
    ? String(left).toUpperCase() === String(right).toUpperCase()
    : String(left) === String(right);
  const options = ['<option value="">选择从站串口</option>'];
  for (const port of serialPorts) {
    options.push(`<option value="${escapeHtml(port.device)}" ${samePort(port.device, selected) ? 'selected' : ''}>${escapeHtml(port.device)} · ${escapeHtml(port.description)}</option>`);
  }
  if (selected && !serialPorts.some(port => samePort(port.device, selected))) {
    options.push(`<option value="${escapeHtml(selected)}" selected>${escapeHtml(selected)} · 当前未连接</option>`);
  }
  return options.join('');
}

function renderNodeGrid() {
  const nodeGrid = document.querySelector('#nodeGrid');
  nodeGrid.innerHTML = meterConfig.nodes.map(node => `
    <article class="node-config panel" data-node-id="${node.node_id}">
      <div class="node-title">
        <div class="node-badge">N${pad(node.node_id)}</div>
        <div><span>SLAVE NODE</span><h3>从站 ${node.node_id}</h3></div>
        <span class="slot-count">${node.meters.filter(m => m.mac).length} / 5 已分配</span>
      </div>
      <div class="port-line"><label>配置串口</label><select class="port-select">${portOptions(node.port)}</select></div>
      <div class="slot-list">
        ${node.meters.map(meter => `
          <div class="slot-row" data-slot="${meter.slot}">
            <span class="slot-label">槽位 ${meter.slot}</span>
            <label>表号<input class="meter-id-input" type="number" min="1" max="20" value="${meter.meter_id}"></label>
            <label>设备名<input class="device-name-input" value="${escapeHtml(meter.name)}" placeholder="扫描后自动填入"></label>
            <label class="mac-field">MAC 地址<input class="mac-input" value="${escapeHtml(meter.mac)}" placeholder="AA:BB:CC:DD:EE:FF"></label>
            <button class="clear-slot" title="清除此槽位" aria-label="清除从站${node.node_id}槽位${meter.slot}">×</button>
          </div>`).join('')}
      </div>
      <button class="write-node primary-button" data-node-id="${node.node_id}">保存并写入从站 ${node.node_id}</button>
    </article>`).join('');

  document.querySelectorAll('.clear-slot').forEach(button => button.addEventListener('click', () => {
    const row = button.closest('.slot-row');
    row.querySelector('.mac-input').value = '';
    row.querySelector('.device-name-input').value = '';
    refreshSlotCounts();
  }));
  document.querySelectorAll('.mac-input').forEach(input => input.addEventListener('input', refreshSlotCounts));
  document.querySelectorAll('.write-node').forEach(button => button.addEventListener('click', () => writeNode(Number(button.dataset.nodeId), button)));
}

function refreshSlotCounts() {
  document.querySelectorAll('.node-config').forEach(card => {
    const count = [...card.querySelectorAll('.mac-input')].filter(input => input.value.trim()).length;
    card.querySelector('.slot-count').textContent = `${count} / 5 已分配`;
  });
}

function assignDevice(address, name, selectValue) {
  if (!selectValue) return;
  const [nodeId, slot] = selectValue.split('-').map(Number);
  document.querySelectorAll('.mac-input').forEach(input => {
    if (input.value.trim().toUpperCase() === address.toUpperCase()) {
      input.value = '';
      input.closest('.slot-row').querySelector('.device-name-input').value = '';
    }
  });
  const row = document.querySelector(`.node-config[data-node-id="${nodeId}"] .slot-row[data-slot="${slot}"]`);
  row.querySelector('.mac-input').value = address;
  row.querySelector('.device-name-input').value = name === '未命名设备' ? '' : name;
  refreshSlotCounts();
  showStatus('configStatus', `${name} 已分配到从站 ${nodeId} / 槽位 ${slot}`, 'success');
}

function assignmentOptions() {
  const options = ['<option value="">选择从站与槽位</option>'];
  for (let node = 1; node <= 4; node++) {
    for (let slot = 1; slot <= 5; slot++) {
      options.push(`<option value="${node}-${slot}">从站 ${node} · 槽位 ${slot} · 表 ${((node - 1) * 5 + slot)}</option>`);
    }
  }
  return options.join('');
}

function renderScanResults(devices) {
  const target = document.querySelector('#scanResults');
  if (!devices.length) {
    target.className = 'scan-results empty-state';
    target.textContent = '没有发现 BLE 设备。请确认电脑蓝牙已开启，并让百分表处于未连接状态。';
    return;
  }
  target.className = 'scan-results';
  target.innerHTML = `<div class="scan-table-head"><span>设备</span><span>MAC 地址</span><span>信号</span><span>分配位置</span></div>` + devices.map((device, index) => `
    <div class="scan-row ${device.likely_meter ? 'likely' : ''}">
      <div class="scan-device"><i></i><div><strong>${escapeHtml(device.name)}</strong><small>${device.likely_meter ? '疑似百分表' : '普通 BLE 设备'}${device.configured ? ' · 已配置' : ''}</small></div></div>
      <code>${escapeHtml(device.address)}</code>
      <span class="rssi ${signalClass(device.rssi)}">${device.rssi} dBm</span>
      <div class="assign-control"><select data-scan-index="${index}">${assignmentOptions()}</select><button data-assign-index="${index}" class="mini-button">分配</button></div>
    </div>`).join('');
  target.querySelectorAll('[data-assign-index]').forEach(button => button.addEventListener('click', () => {
    const index = Number(button.dataset.assignIndex);
    const select = target.querySelector(`select[data-scan-index="${index}"]`);
    if (!select.value) { showStatus('configStatus', '请先选择从站与槽位', 'error'); return; }
    assignDevice(devices[index].address, devices[index].name, select.value);
  }));
}

async function scanBle() {
  const button = document.querySelector('#scanButton');
  button.disabled = true;
  button.textContent = '正在扫描 8 秒…';
  showStatus('scanStatus', '电脑蓝牙正在搜索', 'working');
  try {
    const data = await api('/api/ble/scan', {method: 'POST', body: JSON.stringify({duration: 8})});
    renderScanResults(data.devices);
    const candidates = data.devices.filter(device => device.likely_meter).length;
    showStatus('scanStatus', `发现 ${data.devices.length} 个设备，其中 ${candidates} 个疑似百分表`, 'success');
  } catch (error) {
    showStatus('scanStatus', error.message, 'error');
    appendLog(`[蓝牙扫描] ${error.message}`);
  } finally {
    button.disabled = false;
    button.textContent = '重新扫描附近百分表';
  }
}

async function saveConfig() {
  const button = document.querySelector('#saveButton');
  button.disabled = true;
  try {
    const result = await api('/api/config', {method: 'PUT', body: JSON.stringify(collectConfig())});
    meterConfig = result.config;
    showStatus('configStatus', '全部映射已保存', 'success');
    appendLog(`[配置] ${new Date().toLocaleTimeString('zh-CN')} 全部映射已保存`);
    return true;
  } catch (error) {
    showStatus('configStatus', error.message, 'error');
    appendLog(`[配置失败] ${error.message}`);
    return false;
  } finally { button.disabled = false; }
}

async function writeNode(nodeId, button) {
  const saved = await saveConfig();
  if (!saved) return;
  const card = document.querySelector(`.node-config[data-node-id="${nodeId}"]`);
  const port = card.querySelector('.port-select').value;
  if (!port) { showStatus('configStatus', `请为从站 ${nodeId} 选择串口`, 'error'); return; }
  button.disabled = true;
  button.textContent = `正在写入 ${port}…`;
  appendLog(`\n[从站 ${nodeId}] 开始通过 ${port} 写入配置`);
  try {
    const result = await api(`/api/configure-slave/${nodeId}`, {method: 'POST', body: JSON.stringify({port})});
    appendLog(result.logs);
    showStatus('configStatus', `从站 ${nodeId} 写入完成并已重启`, 'success');
  } catch (error) {
    appendLog(`[写入失败] ${error.message}`);
    showStatus('configStatus', error.message, 'error');
  } finally {
    button.disabled = false;
    button.textContent = `保存并写入从站 ${nodeId}`;
  }
}

async function loadConfiguration() {
  try {
    const [config, ports] = await Promise.all([api('/api/config'), api('/api/serial/ports')]);
    meterConfig = config;
    serialPorts = ports.ports || [];
    renderNodeGrid();
    showStatus('configStatus', `配置已载入 · 检测到 ${serialPorts.length} 个串口`, 'success');
  } catch (error) {
    showStatus('configStatus', error.message, 'error');
    appendLog(`[初始化失败] ${error.message}`);
  }
}

document.querySelectorAll('.view-tab').forEach(button => button.addEventListener('click', () => {
  document.querySelectorAll('.view-tab').forEach(tab => tab.classList.toggle('active', tab === button));
  document.querySelectorAll('.view').forEach(view => view.classList.remove('active'));
  document.querySelector(`#${button.dataset.view}View`).classList.add('active');
}));
document.querySelector('#scanButton').addEventListener('click', scanBle);
document.querySelector('#saveButton').addEventListener('click', saveConfig);
document.querySelector('#clearLog').addEventListener('click', () => { document.querySelector('#operationLog').textContent = '等待操作……'; });

setInterval(() => {
  const now = Date.now();
  const dt = (now - lastRateTime) / 1000;
  const rate = (totalPackets - lastPacketCount) / dt;
  document.querySelector('#packetRate').textContent = Math.max(0, rate).toFixed(1);
  lastPacketCount = totalPackets; lastRateTime = now;
  refreshOnline();
  document.querySelector('#clock').textContent = new Date().toLocaleTimeString('zh-CN', {hour12: false});
}, 1000);

window.addEventListener('resize', () => histories.forEach((_, id) => drawSpark(id)));
connect();
loadConfiguration();
