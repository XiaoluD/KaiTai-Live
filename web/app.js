'use strict';

const $ = (id) => document.getElementById(id);

const state = {
  sources: [],
  activeSource: null,
  channels: [],
  groups: [],
  current: null,
  hls: null,
  timer: null
};

/* ---------- 外部播放器（只有 macOS app 里有这个原生桥） ---------- */

// 浏览器版本（部署在 ECS 上访问）没有这个桥，按钮自动隐藏
const nativeBridge =
  (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.iptv) || null;

let externalPlayers = [];
// 内嵌版（VARIANT=embedded）原生桥会回 embedded:true，表示本机自带 libmpv 内核，
// 不需要装任何第三方播放器也能播 FLV / 组播。
let hasEmbeddedPlayer = false;

async function probeNative() {
  if (!nativeBridge) return { players: [], embedded: false };
  try {
    const r = await nativeBridge.postMessage({ action: 'probe' });
    return { players: (r && r.players) || [], embedded: !!(r && r.embedded) };
  } catch (e) {
    return { players: [], embedded: false };
  }
}

async function probePlayers() {
  const r = await probeNative();
  hasEmbeddedPlayer = r.embedded;
  return r.players;
}

async function openInExternal(url) {
  if (!nativeBridge || !url) return null;
  try {
    const r = await nativeBridge.postMessage({ action: 'open', url });
    return (r && r.player) || null;
  } catch (e) {
    return null;
  }
}

/* ---------- 内嵌播放内核（libmpv，仅内嵌版有） ----------
 *
 * 分工：原生拿一块视图盖在 #screen 上，mpv 负责解码和渲染；
 * 网页只做三件事——告诉它播什么、告诉它视图该在哪、以及接管失败提示。
 * 视图位置走 getBoundingClientRect：WKWebView 的可视区就是它的 frame，
 * 所以在网页里量到的坐标可以一比一还原成原生坐标。
 */

let mpvOn = false;
let mpvRectTimer = null;
let mpvObserver = null;

function mpvCall(op, extra) {
  if (!nativeBridge) return Promise.resolve(null);
  return nativeBridge
    .postMessage(Object.assign({ action: 'mpv', op }, extra || {}))
    .catch(() => null);
}

function syncMpvRect() {
  if (!mpvOn) return;
  const el = $('screen');
  if (!el) return;
  const r = el.getBoundingClientRect();
  if (r.width < 8 || r.height < 8) return;
  mpvCall('rect', { x: r.x, y: r.y, w: r.width, h: r.height });
}

function startMpvRectWatch() {
  stopMpvRectWatch();
  mpvObserver = new ResizeObserver(syncMpvRect);
  mpvObserver.observe($('screen'));
  window.addEventListener('resize', syncMpvRect);
  window.addEventListener('scroll', syncMpvRect, true);
  // 滚动 / 布局变化基本都会触发上面几个事件，这里再兜一层，代价可以忽略
  mpvRectTimer = setInterval(syncMpvRect, 500);
}

function stopMpvRectWatch() {
  if (mpvObserver) {
    try { mpvObserver.disconnect(); } catch (e) {}
    mpvObserver = null;
  }
  window.removeEventListener('resize', syncMpvRect);
  window.removeEventListener('scroll', syncMpvRect, true);
  if (mpvRectTimer) {
    clearInterval(mpvRectTimer);
    mpvRectTimer = null;
  }
}

async function mpvPlay(url) {
  mpvOn = true;
  mpvPaused = false;
  syncMpvRect();
  startMpvRectWatch();
  await mpvCall('play', { url });
  // mpv 内核的音量跟随全局设置（新内核默认 100，得推一次）
  applyVolume(curVol(), false);
}

async function mpvStop() {
  mpvOn = false;
  mpvPaused = false;
  stopMpvRectWatch();
  await mpvCall('stop');
}

// 原生 → 网页 的回调入口（main.swift 用 evaluateJavaScript 调它）
window.__mpv = function (kind, text) {
  if (kind === 'firstframe') {
    setOverlay(null);
    return;
  }
  if (kind === 'fail') {
    mpvOn = false;
    stopMpvRectWatch();
    $('pause').disabled = true;
    failPlayback('内嵌播放器解码失败：' + (text || '未知原因') + '。');
    return;
  }
  if (kind === 'ended') {
    mpvOn = false;
    stopMpvRectWatch();
    $('pause').disabled = true;
    setOverlay('播放已结束', '这个台没有新数据了，换一个试试。', false);
  }
};

/* ---------- 暂停 / 音量（两条播放路径共用） ---------- */

let mpvPaused = false;
const VOL_KEY = 'kaitai-vol';

function curVol() {
  const v = parseInt(localStorage.getItem(VOL_KEY) ?? '100', 10);
  return Number.isFinite(v) ? Math.min(100, Math.max(0, v)) : 100;
}

function applyVolume(v, persist) {
  if (persist) {
    try { localStorage.setItem(VOL_KEY, String(v)); } catch (e) {}
  }
  $('volico').textContent = v > 0 ? '🔊' : '🔇';
  if (mpvOn) mpvCall('volume', { value: v });
  const video = $('video');
  video.muted = v === 0;
  video.volume = v / 100;
}

function setPauseUI(paused) {
  $('pause').textContent = paused ? '▶ 播放' : '⏸ 暂停';
}

function enablePause(on) {
  $('pause').disabled = !on;
  setPauseUI(mpvPaused);
}

/* ---------- 启动 ---------- */

async function boot() {
  try {
    const res = await fetch('./sources.json', { cache: 'no-store' });
    if (!res.ok) throw new Error('sources.json ' + res.status);
    const cfg = await res.json();
    // 留档条目（removed:true）和没有 file 的半成品都不渲染成按钮
    state.sources = (Array.isArray(cfg.sources) ? cfg.sources : []).filter(
      (s) => s && !s.removed && s.file
    );
  } catch (err) {
    $('count').textContent = '配置读取失败';
    setOverlay('缺少 sources.json', '请确认 web/sources.json 已随站点一起部署。', true);
    return;
  }

  renderSourceButtons();
  // 先探一次原生能力，后面的播放分支要靠 hasEmbeddedPlayer
  await setupExternalButton();
  setupUpdateButton();
  setupAppUpdate();

  // 「检查更新」只在 App 内出现（网页版没有原生桥）
  if (nativeBridge) $('checkupd').hidden = false;

  const want = new URLSearchParams(location.search).get('src');
  const first = state.sources.find((s) => s.id === want) || state.sources[0];
  if (first) selectSource(first);
}

/* 应用自更新：检查 GitHub Releases → 可升级时按钮变成「升级到 vX.Y.Z」 */
function setupAppUpdate() {
  const btn = $('checkupd');
  if (!nativeBridge) return;
  let pending = null;
  btn.addEventListener('click', async () => {
    if (pending) {
      btn.disabled = true;
      btn.textContent = '更新中，即将重启…';
      await nativeBridge.postMessage({
        action: 'appupdate', op: 'install', tag: pending.tag, url: pending.zipURL,
      });
      return; // App 会自行退出并换包重启
    }
    btn.disabled = true;
    btn.textContent = '检查中…';
    try {
      const r = await nativeBridge.postMessage({ action: 'appupdate', op: 'check' });
      if (r && r.hasUpdate && r.zipURL) {
        pending = r;
        btn.textContent = '升级到 ' + r.tag;
        btn.classList.add('ok');
        btn.disabled = false;
      } else {
        btn.textContent = '已是最新';
        setTimeout(() => {
          btn.textContent = '检查更新';
          btn.disabled = false;
        }, 2500);
      }
    } catch (e) {
      btn.textContent = '检查失败';
      setTimeout(() => {
        btn.textContent = '检查更新';
        btn.disabled = false;
      }, 2500);
    }
  });
}

/* 一键更新源：只有 app 内、且至少一个源带远程地址时才出现
 *
 * 分工：原生负责下载列表 + 写文件；探活放在这里用 <video> 实测。
 * 原因：App 自己发的 http:// 请求会被 ATS 拦（-1022），而 WebKit 加载 http 媒体流是放行的；
 * 且 video 反映的是真实解码能力，比 HTTP 探活准（FLV 能返回 200 但播不了）。
 */
function setupUpdateButton() {
  const btn = $('update');
  const st = $('updStatus');
  const remote = state.sources.filter((s) => s.url && !s.local);
  if (!nativeBridge || !remote.length) {
    btn.hidden = true;
    return;
  }
  btn.hidden = false;

  btn.addEventListener('click', async () => {
    btn.disabled = true;
    const started = Date.now();
    try {
      await runUpdate(remote, st);
      st.textContent += ' · 用时 ' + Math.round((Date.now() - started) / 1000) + ' 秒';
      if (state.activeSource) selectSource(state.activeSource);
    } catch (e) {
      st.textContent = '更新失败：' + ((e && e.message) || e);
    }
    btn.disabled = false;
  });
}

async function runUpdate(remote, st) {
  st.textContent = '下载列表…';
  const dl = await nativeBridge.postMessage({
    action: 'download',
    urls: remote.map((s) => s.url)
  });
  const texts = (dl && dl.texts) || {};
  const errs = (dl && dl.errors) || {};

  const parts = [];
  for (const src of remote) {
    const raw = texts[src.url];
    if (!raw) {
      parts.push(src.name + ' 失败：' + (errs[src.url] || '没有内容'));
      continue;
    }
    const channels = parseM3U(raw);
    if (!channels.length) {
      parts.push(src.name + ' 失败：解析不出频道');
      continue;
    }

    const kept = await probeChannels(channels, (done, total) => {
      st.textContent =
        '正在实测 ' + src.name + '：' + done + '/' + total + '（点开就能播的才留下）';
    });

    const m3u = buildM3U(kept, src.name);
    await nativeBridge.postMessage({ action: 'save', file: src.file, content: m3u });
    parts.push(src.name + ' ' + channels.length + ' → ' + kept.length + ' 条');
  }
  st.textContent = parts.join('｜');
}

/* 在真实播放器里逐个试播，返回能出画面的频道 */
function probeChannels(channels, onProgress) {
  const CONC = 8;
  const TMO = 7000;
  return new Promise((resolve) => {
    const kept = [];
    let next = 0;
    let live = 0;
    let done = 0;

    const pump = () => {
      while (live < CONC && next < channels.length) {
        const ch = channels[next++];
        live += 1;
        probeOne(ch, TMO).then((ok) => {
          if (ok) kept.push(ch);
          live -= 1;
          done += 1;
          if (onProgress) onProgress(done, channels.length);
          if (done === channels.length) resolve(kept);
          else pump();
        });
      }
    };
    pump();
  });
}

function probeOne(ch, timeout) {
  return new Promise((resolve) => {
    const v = document.createElement('video');
    v.muted = true;
    v.playsInline = true;
    v.preload = 'auto';
    let fin = false;
    const finish = (ok) => {
      if (fin) return;
      fin = true;
      try {
        v.pause();
        v.removeAttribute('src');
        v.load();
      } catch (e) {}
      resolve(ok);
    };
    v.addEventListener('playing', () => finish(v.videoWidth > 0));
    v.addEventListener('loadeddata', () => {
      if (v.videoWidth > 0) finish(true);
    });
    v.addEventListener('error', () => finish(false));
    setTimeout(() => finish(v.videoWidth > 0), timeout);
    v.src = ch.url;
    v.load();
    v.play().catch(() => {});
  });
}

/* 把频道数组还原成 m3u，保留台标和分组 */
function buildM3U(channels, sourceName) {
  const seen = new Set();
  const lines = ['#EXTM3U'];
  const stamp = new Date().toISOString().slice(0, 16).replace('T', ' ');
  lines.push('# updated ' + stamp + ' · ' + sourceName + ' · 实测可播 ' + channels.length + ' 条');
  for (const c of channels) {
    if (seen.has(c.url)) continue;
    seen.add(c.url);
    const attrs = ['tvg-name="' + (c.name || '') + '"'];
    if (c.logo) attrs.push('tvg-logo="' + c.logo + '"');
    if (c.group) attrs.push('group-title="' + c.group + '"');
    lines.push('#EXTINF:-1 ' + attrs.join(' ') + ',' + (c.name || ''));
    lines.push(c.url);
  }
  return lines.join('\n') + '\n';
}

/* 探测本机装了哪个外部播放器，有才显示按钮，并把名字写进文案 */
async function setupExternalButton() {
  const btn = $('player');
  externalPlayers = await probePlayers();
  if (!externalPlayers.length) {
    btn.hidden = true;
    return;
  }
  btn.hidden = false;
  btn.disabled = true;
  btn.textContent = '用 ' + externalPlayers[0] + ' 打开';
  btn.title =
    '检测到：' + externalPlayers.join(' / ') + '。点一下把这个直链交给它播放，流量走你本机。';

  btn.addEventListener('click', async () => {
    const ch = state.current;
    if (!ch) return;
    btn.disabled = true;
    const used = await openInExternal(ch.url);
    btn.disabled = false;
    if (used) {
      setOverlay('已交给 ' + used, '播放器已在新窗口起播，本窗口可以留着或关掉。', false);
    } else {
      setOverlay(
        '没有可用的外部播放器',
        '装一个 IINA 或 VLC（brew install --cask iina），装好后重开本 app 即可。',
        true
      );
    }
  });
}

function renderSourceButtons() {
  const box = $('sources');
  box.innerHTML = '';
  state.sources.forEach((s) => {
    const btn = document.createElement('button');
    btn.className = 'src';
    btn.dataset.id = s.id;
    btn.innerHTML =
      escapeHtml(s.name) +
      '<span class="kind">' + (s.type === 'self' ? '自建' : '公共') + '</span>';
    btn.title = s.note || s.file;
    btn.addEventListener('click', () => selectSource(s));
    box.appendChild(btn);
  });
}

/* ---------- 载入播放列表 ---------- */

async function selectSource(src) {
  state.activeSource = src;
  document.querySelectorAll('.src').forEach((b) => {
    b.classList.toggle('on', b.dataset.id === src.id);
  });

  $('count').textContent = '读取列表…';
  $('list').innerHTML = '';

  let text = '';
  try {
    const res = await fetch('./' + src.file, { cache: 'no-store' });
    if (!res.ok) throw new Error(String(res.status));
    text = await res.text();
  } catch (err) {
    $('count').textContent = '列表不可用';
    setOverlay(
      '这个源还没同步到服务器',
      '缺少文件 ' + src.file + '（或返回 ' + err.message + '）。按 02-自建Fork/README.md 里的同步步骤拉一次即可。',
      true
    );
    return;
  }

  state.channels = parseM3U(text);
  if (!state.channels.length) {
    $('count').textContent = '0 个频道';
    setOverlay('列表为空', '文件解析不到有效频道，检查 ' + src.file + ' 的格式。', true);
    return;
  }

  state.groups = [...new Set(state.channels.map((c) => c.group))];
  renderGroups();
  renderList();
}

function renderGroups() {
  const sel = $('group');
  sel.innerHTML = '<option value="">全部分组（' + state.channels.length + '）</option>';
  state.groups.forEach((g) => {
    const n = state.channels.filter((c) => c.group === g).length;
    const o = document.createElement('option');
    o.value = g;
    o.textContent = g + '（' + n + '）';
    sel.appendChild(o);
  });
}

function renderList() {
  const q = $('q').value.trim().toLowerCase();
  const g = $('group').value;
  const rows = state.channels.filter((c) => {
    if (g && c.group !== g) return false;
    if (q && !c.name.toLowerCase().includes(q)) return false;
    return true;
  });

  $('count').textContent =
    '显示 ' + rows.length + ' / ' + state.channels.length + ' 个频道';

  const box = $('list');
  const frag = document.createDocumentFragment();

  // 同一频道可能有多个备用源（同名多条），加序号区分，避免看起来像重复 bug
  const nameCount = {};
  rows.forEach((c) => { nameCount[c.name] = (nameCount[c.name] || 0) + 1; });
  const seen = {};

  rows.forEach((c) => {
    const isDup = nameCount[c.name] > 1;
    const idx = (seen[c.name] = (seen[c.name] || 0) + 1);
    const el = document.createElement('div');
    el.className = 'ch' + (state.current && state.current.url === c.url ? ' on' : '');
    el.dataset.url = c.url;

    const img = document.createElement('img');
    img.alt = '';
    img.loading = 'lazy';
    img.referrerPolicy = 'no-referrer';
    img.style.visibility = 'hidden';
    img.addEventListener('load', () => { img.style.visibility = 'visible'; });
    img.addEventListener('error', () => { img.style.visibility = 'hidden'; });
    if (c.logo) img.src = c.logo;

    const nm = document.createElement('div');
    nm.className = 'nm';
    nm.textContent = isDup ? c.name + ' ·' + idx : c.name;

    const gp = document.createElement('div');
    gp.className = 'gp';
    gp.textContent = c.group;

    el.append(img, nm, gp);
    el.addEventListener('click', () => playChannel(c));
    frag.appendChild(el);
  });

  box.innerHTML = '';
  box.appendChild(frag);
}

/* ---------- 播放 ---------- */

function playChannel(ch) {
  state.current = ch;
  document.querySelectorAll('.ch').forEach((el) => {
    el.classList.toggle('on', el.dataset.url === ch.url);
  });

  $('now').textContent = ch.name + (ch.group ? ' · ' + ch.group : '');
  $('url').textContent = ch.url;
  $('url').title = ch.url;
  $('ext').href = ch.url;
  const pb = $('player');
  if (pb && !pb.hidden) pb.disabled = false;
  setOverlay('正在连接…', ch.url, false);

  resetPlayer();

  // 换台时解除暂停态，暂停/音量控件立即可用
  mpvPaused = false;
  enablePause(true);
  applyVolume(curVol(), false);

  // 内嵌版优先：libmpv 能吃 FLV / 组播转单播 / HEVC，可播率比 <video> 高一截
  if (hasEmbeddedPlayer) {
    mpvPlay(ch.url);
  } else {
    startBrowserPlay(ch.url);
  }
}

function startBrowserPlay(url) {
  const video = $('video');
  const isHls = /m3u8/i.test(url);
  // Safari / WKWebView 原生支持 HLS，且媒体元素请求不受 CORS 约束——
  // 这种情况下优先用原生，可播率远高于 MSE；Chrome 走 hls.js。
  const nativeHls =
    document.createElement('video').canPlayType('application/vnd.apple.mpegurl') !== '';

  if (isHls && !nativeHls && window.Hls && window.Hls.isSupported()) {
    const hls = new window.Hls({
      manifestLoadingMaxRetry: 1,
      levelLoadingMaxRetry: 1,
      fragLoadingMaxRetry: 1,
      manifestLoadingTimeOut: 8000
    });
    state.hls = hls;
    let done = false;

    hls.on(window.Hls.Events.MANIFEST_PARSED, () => {
      if (done) return;
      setOverlay(null);
      video.play().catch(() => {});
    });

    hls.on(window.Hls.Events.ERROR, (_evt, data) => {
      if (!data.fatal || done) return;
      done = true;
      destroyHls();
      nativeFallback(url, data.details || data.type);
    });

    hls.on(window.Hls.Events.FRAG_LOADED, () => {
      if (done) return;
      setOverlay(null);
    });

    hls.loadSource(url);
    hls.attachMedia(video);
    armTimeout();
    return;
  }

  nativeFallback(url);
}

// 用 no-cors + Range 的探测区分「服务器有应答但内容不对」和「根本连不上服务器」。
// 只声明取 2 字节、拿到响应头就 abort，几乎不耗流量。
async function classifySrc(url) {
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), 6000);
  try {
    await fetch(url, {
      mode: 'no-cors',
      cache: 'no-store',
      headers: { Range: 'bytes=0-1' },
      signal: ac.signal
    });
    return '服务器有应答，但返回的格式 Safari 解不了——最常见的是 FLV 直播流；也可能是 404/502 错误页或地址已换。';
  } catch (e) {
    return '连不上这个服务器（' + ((e && e.name) || '失败') + '），域名可能已失效。';
  } finally {
    clearTimeout(t);
    ac.abort();
  }
}

function nativeFallback(url, hlsDetail) {
  const video = $('video');
  destroyHls();
  video.src = url;

  const onErr = async () => {
    video.removeEventListener('error', onErr);
    const e = video.error;
    const code = e ? e.code : 0;
    let detail = MEDIA_ERR[code] || ('未知错误 code=' + code);
    // 只有「网络失败 / 内容不是流」这两种才值得再探一次，其余是解码问题
    if ((code === 2 || code === 4) && !urlHint(url)) {
      detail += ' ' + (await classifySrc(url));
    }
    if (hlsDetail) detail += ' MSE 阶段报错：' + hlsDetail + '。';
    failPlayback(detail);
  };
  video.addEventListener('error', onErr);

  video.load();
  video.play().then(() => setOverlay(null)).catch(() => {});
  armTimeout();
}

function armTimeout() {
  clearTimeout(state.timer);
  state.timer = setTimeout(() => {
    const video = $('video');
    if (video.readyState < 2) {
      const e = video.error;
      const code = e ? e.code : 0;
      failPlayback(
        '等了 9 秒还没出画面（readyState=' + video.readyState + '，error.code=' + code + '）。' +
          '源站可能已下线、限速，或是运营商内网专网源。'
      );
    }
  }, 9000);
}

// HTMLMediaElement.error.code 的标准含义
const MEDIA_ERR = {
  1: '播放被中断（MEDIA_ERR_ABORTED）',
  2: '网络层失败，连不上源站（MEDIA_ERR_NETWORK）',
  3: '解码失败，编码格式不支持（MEDIA_ERR_DECODE）',
  4: '地址不是可播放的 HLS 流，或已失效、被源站限制访问（MEDIA_ERR_SRC_NOT_SUPPORTED）'
};

/* 先天的「地址级」限制：这类源在任何浏览器里都注定播不了，和 CORS 无关 */
function urlHint(url) {
  const u = String(url || '');
  const m = /^(rtp|rtsp|udp|igmp):\/\//i.exec(u);
  if (m) {
    return (
      '这是 ' + m[1].toLowerCase() + ':// 组播/专网地址，浏览器没法直连，' +
      '必须先用 udpxy / msd_lite 转成 http 单播。'
    );
  }
  if (/\.flv(\?|$)/i.test(u)) {
    return '这是 FLV 直连流，Safari 内核不支持 FLV 封装（换 Chrome 或 PotPlayer / FongMi 可以播）。';
  }
  let host = '';
  try { host = new URL(u).hostname; } catch (e) {}
  if (
    /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(host) ||
    /\.local$/i.test(host) ||
    /^(localhost)$/i.test(host)
  ) {
    return '这个地址指向内网（' + host + '），只有当地运营商的宽带用户能访问，你这里连不进去。';
  }
  return '';
}

function failPlayback(detail) {
  clearTimeout(state.timer);
  const hint = state.current ? urlHint(state.current.url) : '';
  const body = [hint, detail || '未知原因'].filter(Boolean).join(' ');
  const tail = externalPlayers.length
    ? '点上方「用 ' + externalPlayers[0] + ' 打开」交给原生播放器，或复制直链用别的播放器。'
    : '可点「复制直链」换一个播放器再试。';
  setOverlay('这个源播不了', body + ' ' + tail, true);
}

function resetPlayer() {
  clearTimeout(state.timer);
  destroyHls();
  const video = $('video');
  video.pause();
  video.removeAttribute('src');
  video.load();
  if (mpvOn) mpvStop();
  mpvPaused = false;
  $('pause').disabled = true;
}

function destroyHls() {
  if (state.hls) {
    try { state.hls.destroy(); } catch (e) {}
    state.hls = null;
  }
}

/* ---------- 覆盖层 ---------- */

function setOverlay(title, sub, bad) {
  const ov = $('overlay');
  if (!title) {
    ov.classList.add('hide');
    return;
  }
  ov.classList.remove('hide');
  ov.classList.toggle('bad', !!bad);
  ov.innerHTML = '';

  const t = document.createElement('div');
  t.className = 'ov-title';
  t.textContent = title;

  const s = document.createElement('div');
  s.className = 'ov-sub';
  s.textContent = sub || '';

  ov.append(t, s);
}

/* ---------- m3u 解析 ---------- */

function parseM3U(text) {
  const out = [];
  const lines = text.split(/\r?\n/);
  let pending = null;

  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;

    if (line.startsWith('#EXTINF')) {
      pending = parseInfo(line);
      continue;
    }
    if (line.startsWith('#EXTGRP')) {
      if (pending) {
        const g = line.slice(line.indexOf(':') + 1).trim();
        if (g) pending.group = g;
      }
      continue;
    }
    if (line.startsWith('#')) continue;

    if (pending && /^[a-z][a-z0-9+.-]*:\/\//i.test(line)) {
      pending.url = line;
      out.push(pending);
      pending = null;
    }
  }
  return out;
}

function parseInfo(line) {
  const info = { name: '', logo: '', group: '', url: '' };

  const logo = /tvg-logo="([^"]*)"/i.exec(line);
  if (logo) info.logo = logo[1];

  const grp = /group-title="([^"]*)"/i.exec(line);
  if (grp) info.group = grp[1];

  const nm = /tvg-name="([^"]*)"/i.exec(line);
  if (nm) info.name = nm[1];

  const comma = line.lastIndexOf(',');
  if (comma > -1) {
    const disp = line.slice(comma + 1).trim();
    if (disp) info.name = disp;
  }

  if (!info.group) info.group = '未分组';
  if (!info.name) info.name = '未命名频道';
  return info;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (m) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[m]));
}

/* ---------- 交互绑定 ---------- */

$('q').addEventListener('input', renderList);
$('group').addEventListener('change', renderList);

$('retry').addEventListener('click', () => {
  if (!state.current) return;
  setOverlay('正在重试…', state.current.url, false);
  resetPlayer();
  enablePause(true);
  if (hasEmbeddedPlayer) mpvPlay(state.current.url);
  else startBrowserPlay(state.current.url);
});

/* 暂停：内嵌走 mpv，网页版走 <video>，同一个按钮 */
$('pause').addEventListener('click', () => {
  if ($('pause').disabled) return;
  if (mpvOn) {
    mpvPaused = !mpvPaused;
    mpvCall('pause', { paused: mpvPaused });
    setPauseUI(mpvPaused);
    return;
  }
  const video = $('video');
  if (video.paused) video.play().catch(() => {});
  else video.pause();
});
$('video').addEventListener('pause', () => setPauseUI(true));
$('video').addEventListener('play', () => setPauseUI(false));

/* 音量：内嵌走 mpv，网页版走 <video>；设置持久化 */
$('vol').addEventListener('input', (e) => applyVolume(+e.target.value || 0, true));
$('vol').value = curVol();

$('copy').addEventListener('click', async () => {
  if (!state.current) return;
  const btn = $('copy');
  const url = state.current.url;
  try {
    await navigator.clipboard.writeText(url);
  } catch (e) {
    const ta = document.createElement('textarea');
    ta.value = url;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    ta.remove();
  }
  btn.textContent = '已复制';
  btn.classList.add('ok');
  setTimeout(() => {
    btn.textContent = '复制直链';
    btn.classList.remove('ok');
  }, 1600);
});

boot();
