'use strict';

const $ = (id) => document.getElementById(id);

const state = {
  sources: [],
  activeSource: null,
  channels: [],
  groups: [],
  activeGroup: '',
  // 频道视图：跨源聚合 + 五大类
  aggregated: [],
  activeCat: '央视频道', // 进入程序默认打开央视频道
  current: null,
  hls: null,
  timer: null
};

let aggLoaded = false;

const CATS = ['央视频道', '卫视频道', '港澳台', '其他'];

/* 卫视热度榜：收视率与覆盖综合排序，榜内靠前；未上榜的走自然序兜底 */
const HOT_SATV = ['湖南', '东方', '浙江', '江苏', '北京', '广东', '深圳', '山东',
  '安徽', '天津', '湖北', '四川', '重庆', '东南', '辽宁', '黑龙江',
  '贵州', '江西', '河南', '河北', '云南', '广西', '山西', '吉林',
  '甘肃', '宁夏', '青海', '新疆', '内蒙古', '海南', '西藏', '兵团', '三沙'];

function satvRank(name) {
  const n = String(name || '');
  const i = HOT_SATV.findIndex((k) => n.includes(k) && n.includes('卫视'));
  return i === -1 ? 999 : i;
}

/* 频道视图的分类规则（按频道名判断，与源自带的 group-title 无关）。
 * 「电影频道」分类已按需求移除：CCTV-6 归入央视，电影/影院/CHC 等落入其他 */
function classifyChannel(name) {
  const n = String(name || '').toUpperCase();
  if (/港澳|台湾|香港|澳门|凤凰|TVB|翡翠|明珠|本港|国际台|TVBS|三立|民视|中天|中视|华视|台视|东森|八大|RTHK|HOY|澳视|莲花|ASTRO|八大|纬来|龙华|靖天|龙祥|寰宇|AXN|HBO ASIA/.test(n)) return '港澳台';
  if (/卫视/.test(n)) return '卫视频道';
  if (/CCTV|CGTN|央视频道|央视|中央教育|CETV/.test(n)) return '央视频道';
  return '其他';
}

/* 显示层剥离清晰度标注：CCTV-3（720p）→ CCTV-3；CCTV-17 HD (1080p) → CCTV-17 */
function stripQual(name) {
  let n = String(name || '');
  // 括号内是清晰度标记的整段删除（其他括号内容保留）
  n = n.replace(/[（(【\[][^）)】\]]*[）)】\]]/g, (m) =>
    /(\d{3,4}p|4k|8k|fhd|uhd|hd|超清|高清|标清|蓝光)/i.test(m) ? '' : m);
  // 裸尾缀只剥 HD/超清/高清/标清/蓝光/分辨率数字；4K/8K 是频道身份（CCTV-8K），不动
  n = n.replace(/\s*(超清|高清|标清|蓝光|fhd|uhd|hd|\d{3,4}p)\s*$/i, '');
  return n.replace(/\s{2,}/g, ' ').trim();
}

/* 从频道名里提取清晰度标记（720p / 4K / 高清…），用于源切换按钮和明细行的区分文案 */
function qualTag(name) {
  const m = /(\d{3,4}p|4k|8k|fhd|uhd|超清|高清|标清|蓝光)/i.exec(String(name || ''));
  return m ? m[1].toLowerCase() : '';
}

/* 频道名归一化：同一台在不同源里写法略有差异（CCTV-1 / CCTV1(720p) / CCTV1高清） */
function normName(name) {
  return String(name || '')
    .toLowerCase()
    .replace(/[\s_]/g, '')
    .replace(/[（(【\[][^）)】\]]*[）)】\]]/g, '') // 去括号内容（清晰度等），CCTV-1（720p）并进 CCTV-1
    .replace(/[-_·]/g, '')
    .replace(/(超清|高清|标清|蓝光|fhd|uhd|hd|4k|8k|50fps|60fps)$/i, '');
}

/* 把所有源的 m3u 一次性拉下来聚合成频道列表（频道视图数据底座） */
async function loadAllSources() {
  if (aggLoaded) return;
  $('count').textContent = '聚合所有源…';
  const results = await Promise.all(state.sources.map(async (s) => {
    try {
      // 网页/PWA 的「更新源」结果存本地：优先用本机最新实测列表，覆盖服务器文件
      const override = readPlaylistOverrides()[s.id];
      if (override) return { src: s, channels: parseM3U(override) };
      const res = await fetch('./' + s.file, { cache: 'no-store' });
      if (!res.ok) return { src: s, channels: [] };
      return { src: s, channels: parseM3U(await res.text()) };
    } catch (e) {
      return { src: s, channels: [] };
    }
  }));

  const map = new Map();
  for (const { src, channels } of results) {
    for (const ch of channels) {
      const key = normName(ch.name);
      if (!key) continue;
      if (!map.has(key)) {
        map.set(key, {
          name: stripQual(ch.name), logo: '', fallbackLogo: '',
          cat: classifyChannel(ch.name), items: []
        });
      }
      const agg = map.get(key);
      if (!agg.logo && ch.logo) agg.logo = ch.logo;
      agg.items.push({ src, ch });
    }
  }
  state.aggregated = [...map.values()];

  // CCTV 系列统一换成高清台标（fanmingming/live 图床，640×360 透明底）；失败回退源 logo
  for (const a of state.aggregated) {
    const hi = premiumLogo(a.name);
    if (hi) {
      a.fallbackLogo = a.logo;
      a.logo = hi;
    }
  }

  // 排序：分类分块 → 央视里 CCTV 数字序在前 → 卫视按热度榜 → 其余自然序
  state.aggregated.sort((a, b) => {
    const ca = CATS.indexOf(a.cat), cb = CATS.indexOf(b.cat);
    if (ca !== cb) return ca - cb;
    if (a.cat === '央视频道') {
      const pa = /^CCTV/i.test(a.name) ? 0 : 1;
      const pb = /^CCTV/i.test(b.name) ? 0 : 1;
      if (pa !== pb) return pa - pb;
    }
    if (a.cat === '卫视频道') {
      const ra = satvRank(a.name), rb = satvRank(b.name);
      if (ra !== rb) return ra - rb;
    }
    return naturalCmp(a.name, b.name);
  });
  aggLoaded = true;
}

/* 高清台标映射：CCTV-1..17 / CCTV5+ / CGTN 系列 */
function premiumLogo(name) {
  const n = String(name || '').toUpperCase().replace(/[\s-]/g, '');
  const m = /^CCTV(\d{1,2})(\+?)($|[^0-9])/.exec(n);
  if (m) return 'https://live.fanmingming.com/tv/CCTV' + m[1] + m[2] + '.png';
  if (/^CGTN/.test(n)) {
    if (/^CGTNDOC/.test(n)) return 'https://live.fanmingming.com/tv/CGTNDOC.png';
    return 'https://live.fanmingming.com/tv/CGTN.png';
  }
  return '';
}

/* 自然排序：数字段按数值比较，避免 CCTV-10 排在 CCTV-2 前面；
 * 比较前抹掉连字符/下划线，让 CCTV-1 和 CCTV1 落在同一排序基线 */
function naturalCmp(x, y) {
  const sa = String(x).replace(/[-_]/g, '').split(/(\d+)/);
  const sb = String(y).replace(/[-_]/g, '').split(/(\d+)/);
  for (let i = 0; i < Math.max(sa.length, sb.length); i++) {
    const a = sa[i], b = sb[i];
    if (a === undefined) return -1;
    if (b === undefined) return 1;
    if (/^\d+$/.test(a) && /^\d+$/.test(b)) {
      const d = +a - +b;
      if (d) return d;
    } else if (a !== b) {
      return a < b ? -1 : 1;
    }
  }
  return 0;
}

/* 聚合频道默认线路：优先「默认」源，其次按 sources.json 顺序取第一个 */
function pickDefaultItem(agg) {
  const def = agg.items.find((it) => it.src.name === '默认' || it.src.id === 'self-iptv-api');
  return def || agg.items[0];
}

/* ---------- 外部播放器（只有 macOS app 里有这个原生桥） ---------- */

// 浏览器版本（部署在 ECS 上访问）没有这个桥，按钮自动隐藏
const nativeBridge =
  (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.iptv) || null;

let externalPlayers = [];
// 内嵌版（VARIANT=embedded）原生桥会回 embedded:true，表示本机自带 libmpv 内核，
// 不需要装任何第三方播放器也能播 FLV / 组播。
let hasEmbeddedPlayer = false;

/* ---------- 平台检测：iOS / iPadOS PWA 与 macOS App 的差异化处理 ---------- */
const IS_TOUCH = ('ontouchstart' in window) || navigator.maxTouchPoints > 0;
// iPadOS 13+ UA 伪装成 Mac（'Macintosh' + 多点触摸）——用触摸点数识别
const IS_IOS = /iPad|iPhone|iPod/.test(navigator.userAgent)
  || (navigator.maxTouchPoints > 1 && /Macintosh/i.test(navigator.userAgent));
const IS_MAC = /Macintosh/i.test(navigator.userAgent) && navigator.maxTouchPoints === 0;
if (IS_MAC) document.body.classList.add('mac');
if (IS_TOUCH) document.body.classList.add('touch');
if (IS_IOS) document.body.classList.add('ios');

async function probeNative() {
  if (!nativeBridge) { window.__diag = 'no-bridge'; return { players: [], embedded: false }; }
  try {
    window.__diag = 'probe-sent';
    const r = await nativeBridge.postMessage({ action: 'probe' });
    window.__diag = 'probe-replied:' + JSON.stringify(r).slice(0, 100);
    return { players: (r && r.players) || [], embedded: !!(r && r.embedded) };
  } catch (e) {
    window.__diag = 'probe-error:' + e;
    return { players: [], embedded: false };
  }
}

async function probePlayers() {
  const r = await probeNative();
  hasEmbeddedPlayer = r.embedded;
  if (r.version) window.__appVersion = r.version;
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
  await mpvCall('setopt', { key: 'hwdec', value: settings.hwdec ? 'videotoolbox' : 'no' });
  await mpvCall('overlay', { hidden: false }); // 确保画面层可见（暂停时会被隐藏）
  // mpv 内核的音量跟随全局设置（新内核默认 100，得推一次）
  applyVolume(curVol(), false);
}

async function mpvStop() {
  mpvOn = false;
  mpvPaused = false;
  stopMpvRectWatch();
  await mpvCall('stop');
}

// 原生菜单栏 → 网页 的入口（main.swift 用 evaluateJavaScript 调它）
window.__kaitaiMenu = function (action) {
  switch (action) {
    case 'pause': $('pause').click(); break;
    case 'retry': $('retry').click(); break;
    case 'copy':
      if (state.current) navigator.clipboard.writeText(state.current.url);
      break;
    case 'settings': $('settingsBtn').click(); break;
    case 'checkupd': { const b = $('checkupd'); if (!b.hidden) b.click(); break; }
    case 'update': { const b = $('update'); if (!b.hidden) b.click(); break; }
    case 'view-sources': saveSettings({ view: 'sources' }); break;
    case 'view-channels': saveSettings({ view: 'channels' }); break;
  }
};

// 原生「在浏览器打开」先取当前直链，再交给 NSWorkspace
window.__kaitaiCurrentURL = function () {
  return state.current ? state.current.url : '';
};

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

/* 平面风格的音量图标（线性 SVG，跟随文字色，替代 emoji） */
const VOL_ON =
  '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07"/></svg>';
const VOL_OFF =
  '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><line x1="23" y1="9" x2="17" y2="15"/><line x1="17" y1="9" x2="23" y2="15"/></svg>';

function applyVolume(v, persist) {
  if (persist) {
    try { localStorage.setItem(VOL_KEY, String(v)); } catch (e) {}
  }
  $('vol').value = v;
  $('volico').innerHTML = v > 0 ? VOL_ON : VOL_OFF;
  if (mpvOn) mpvCall('volume', { value: v });
  const video = $('video');
  video.muted = v === 0;
  video.volume = v / 100;
}

/* 暂停/播放状态图标：暂停时常驻，恢复播放后短暂显示再淡出 */
const STATE_PAUSE =
  '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4" width="4.5" height="16" rx="1.5"/><rect x="13.5" y="4" width="4.5" height="16" rx="1.5"/></svg>';
const STATE_PLAY =
  '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 4.8c0-1.2 1.3-1.9 2.3-1.3l11 6.9c1 .6 1 2 0 2.6l-11 6.9c-1 .6-2.3-.1-2.3-1.3V4.8z"/></svg>';

let playStateTimer = null;

function showPlayState(paused) {
  const el = $('playState');
  // 连接中/失败等覆盖层显示时不抢镜
  if (!$('overlay').classList.contains('hide')) {
    el.classList.remove('show');
    return;
  }
  $('playStateBadge').innerHTML = paused ? STATE_PAUSE : STATE_PLAY;
  el.classList.add('show');
  clearTimeout(playStateTimer);
  if (!paused) {
    playStateTimer = setTimeout(() => el.classList.remove('show'), 700);
  }
}

function setPauseUI(paused) {
  $('pause').textContent = paused ? '▶ 播放' : '⏸ 暂停';
  showPlayState(paused);
}

function enablePause(on) {
  $('pause').disabled = !on;
  setPauseUI(mpvPaused);
}

/* ---------- iPhone/iPad（PWA）：抽屉与锁屏控制 ---------- */

function openRail() {
  document.body.classList.add('rail-open');
  const s = $('railScrim');
  s.hidden = false;
  requestAnimationFrame(() => s.classList.add('show'));
}

function closeRail() {
  document.body.classList.remove('rail-open');
  const s = $('railScrim');
  s.classList.remove('show');
  setTimeout(() => { if (!document.body.classList.contains('rail-open')) s.hidden = true; }, 260);
}

function isNarrow() { return window.matchMedia('(max-width: 640px)').matches; }

function closeRailOnNarrow() { if (isNarrow()) closeRail(); }

function setupMobileUI() {
  if (!IS_TOUCH) return;
  $('railToggle').addEventListener('click', () => {
    document.body.classList.contains('rail-open') ? closeRail() : openRail();
  });
  $('railScrim').addEventListener('click', closeRail);
  // 旋转/调窗口时从窄屏转宽屏，抽屉态复位
  window.addEventListener('resize', () => { if (!isNarrow()) closeRail(); });
}

/* iOS 锁屏/灵动岛：显示正在播的频道，提供播放/暂停控制 */
function updateNowPlaying(ch) {
  if (!IS_IOS || !('mediaSession' in navigator)) return;
  try {
    const logo = premiumLogo(ch.name);
    navigator.mediaSession.metadata = new window.MediaMetadata({
      title: stripQual(ch.name),
      artist: ch.group || 'IPTV 直播',
      artwork: logo ? [{ src: logo, sizes: '512x512', type: 'image/png' }] : [],
    });
    navigator.mediaSession.setActionHandler('play', () => { $('pause').click(); });
    navigator.mediaSession.setActionHandler('pause', () => { $('pause').click(); });
  } catch (e) { /* MediaSession 失败不影响播放 */ }
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
  setupMobileUI();
  // 先探一次原生能力，后面的播放分支要靠 hasEmbeddedPlayer
  await setupExternalButton();
  setupUpdateButton();
  setupAppUpdate();

  // 「检查更新」只在 App 内出现（网页版没有原生桥）
  if (nativeBridge) {
    $('checkupd').hidden = false;
    bindSettingsUI();
    applySettings();
    if (settings.autoCheck) {
      setTimeout(() => { const b=$('checkupd'); if (b._check) b._check({ silent: true }); }, 8000);
    }
  }

  const want = new URLSearchParams(location.search).get('src');
  const first = state.sources.find((s) => s.id === want) || state.sources[0];
  // 支持 ?view=channels|sources 直连某个视图（分享链接/自动化截图用）
  const vp = new URLSearchParams(location.search).get('view');
  if (vp === 'channels' || vp === 'sources') settings.view = vp;
  renderView();
  const restored = await restoreLastChannel();
  if (!restored && settings.view !== 'channels' && first) selectSource(first);
}

/* 按设置里的视图渲染侧边栏（播放源视图 / 频道视图） */
function renderView() {
  const channels = settings.view === 'channels';
  $('sources').style.display = channels ? 'none' : '';
  $('srcTitle').style.display = channels ? 'none' : '';
  $('catTitle').textContent = channels ? '分类' : '分组';
  if (channels) {
    loadAllSources().then(() => { renderGroups(); renderList(); });
  } else {
    renderGroups();
    renderList();
  }
}

/* 应用自更新：检查 GitHub Releases → 可升级时按钮变成「升级到 vX.Y.Z」 */
function setupAppUpdate() {
  const btn = $('checkupd');
  if (!nativeBridge) return;
  let pending = null;

  const reset = (text) => {
    btn.textContent = text;
    setTimeout(() => {
      btn.textContent = pending ? '升级到 ' + pending.tag : '检查更新';
      if (!pending) btn.disabled = false;
    }, 2500);
  };

  /** silent=true：启动静默检查，命中后按设置自动安装或只标亮按钮 */
  btn._check = async function ({ silent } = {}) {
    try {
      const r = await nativeBridge.postMessage({ action: 'appupdate', op: 'check' });
      if (r && r.current && $('aboutVersionDetail').textContent === '—') {
        $('aboutVersionDetail').textContent = 'v' + r.current + ' · 与 GitHub Releases 同步';
      }
      if (!r || !r.hasUpdate || !r.zipURL) {
        if (!silent) reset('已是最新');
        return null;
      }
      pending = r;
      btn.textContent = '升级到 ' + r.tag;
      btn.classList.add('ok');
      btn.disabled = false;
      if (settings.autoInstall) {
        btn.disabled = true;
        btn.textContent = '自动更新中，即将重启…';
        await nativeBridge.postMessage({
          action: 'appupdate', op: 'install', tag: r.tag, url: r.zipURL,
        });
      }
      return r;
    } catch (e) {
      if (!silent) reset('检查失败');
      return null;
    }
  };

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
    btn._check();
  });
}

/* ---------- 设置（localStorage 持久化） ---------- */

const SET_KEY = 'kaitai-settings';
const settings = Object.assign(
  { theme: 'light', view: 'channels', density: 'normal', resume: true, hwdec: true,
    hotkeys: true, autoCheck: true, autoInstall: true },
  JSON.parse(localStorage.getItem(SET_KEY) || '{}')
);

function saveSettings(patch) {
  const viewChanged = 'view' in patch && patch.view !== settings.view;
  Object.assign(settings, patch);
  try { localStorage.setItem(SET_KEY, JSON.stringify(settings)); } catch (e) {}
  applySettings();
  if (viewChanged) renderView();
}

const sysDark = window.matchMedia('(prefers-color-scheme: dark)');
function applySettings() {
  const t = settings.theme === 'system'
    ? (sysDark.matches ? 'dark' : 'light')
    : settings.theme;
  document.documentElement.dataset.theme = t;
  document.body.classList.toggle('compact', settings.density === 'compact');
  if (mpvOn) mpvCall('setopt', { key: 'hwdec', value: settings.hwdec ? 'videotoolbox' : 'no' });
}
sysDark.addEventListener('change', () => { if (settings.theme === 'system') applySettings(); });

function bindSettingsUI() {
  window.__bindDone = true; // 自检标记：绑定流程是否跑过
  $('settingsBtn').addEventListener('click', () => { $('settingsScrim').hidden = false; });
  $('settingsClose').addEventListener('click', () => { $('settingsScrim').hidden = true; });
  $('settingsScrim').addEventListener('click', (e) => {
    if (e.target === $('settingsScrim')) $('settingsScrim').hidden = true;
  });

  const seg = (id, key) => {
    const box = $(id);
    const sync = () => box.querySelectorAll('button').forEach((b) =>
      b.classList.toggle('on', b.dataset.v === settings[key]));
    box.addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (!b) return;
      saveSettings({ [key]: b.dataset.v });
      sync();
    });
    sync();
  };
  seg('setTheme', 'theme');
  seg('setView', 'view');
  seg('setDensity', 'density');

  const sw = (id, key) => {
    const el = $(id);
    const sync = () => el.setAttribute('aria-checked', String(!!settings[key]));
    el.addEventListener('click', () => {
      saveSettings({ [key]: !settings[key] });
      sync();
    });
    sync();
  };
  sw('setResume', 'resume');
  sw('setHwdec', 'hwdec');
  sw('setHotkeys', 'hotkeys');
  sw('setAutoCheck', 'autoCheck');
  sw('setAutoInstall', 'autoInstall');

  // 设置面板里的「更新播放源」：关面板后在侧边栏底部状态区看进度
  $('setUpdateSources').addEventListener('click', () => {
    const b = $('update');
    $('settingsScrim').hidden = true;
    if (!b.hidden) b.click();
  });

  // 关于里的「检查更新」：不关面板，直接把结果写进版本详情
  $('setCheckUpdate').addEventListener('click', () => { $('checkupd').click(); });

  // 当前版本详情（原生桥启动时注入 window.__appVersion）
  if (window.__appVersion) {
    $('aboutVersionDetail').textContent = 'v' + window.__appVersion + ' · 与 GitHub Releases 同步';
  }

  // 无内嵌内核时隐藏播放设置（网页版不涉及 mpv）
  if (!hasEmbeddedPlayer) $('setPlaySection').hidden = true;
}

/* 恢复上次频道：记住 源 + 频道URL，启动后静默重放 */
function rememberChannel() {
  if (!state.current || !state.activeSource) return;
  try {
    localStorage.setItem('kaitai-last', JSON.stringify({
      src: state.activeSource.id, url: state.current.url,
    }));
  } catch (e) {}
}

async function restoreLastChannel() {
  if (!settings.resume) return false;
  let last = null;
  try { last = JSON.parse(localStorage.getItem('kaitai-last') || 'null'); } catch (e) {}
  if (!last || !last.url) return false;

  // 频道视图：直接在聚合表里找这条直链，播放
  if (settings.view === 'channels') {
    if (!aggLoaded) await loadAllSources();
    for (const a of state.aggregated) {
      const it = a.items.find((x) => x.ch.url === last.url);
      if (it) {
        playChannel(it.ch, it.src);
        return true;
      }
    }
    return false;
  }

  const src = state.sources.find((s) => s.id === last.src);
  if (!src) return false;
  await selectSource(src);
  const ch = [...document.querySelectorAll('.chan')].find((e) => e.dataset.url === last.url);
  if (!ch) return false;
  ch.click();
  return true;
}

/* 一键更新源：只有 app 内、且至少一个源带远程地址时才出现
 *
 * 分工：原生负责下载列表 + 写文件；探活放在这里用 <video> 实测。
 * 原因：App 自己发的 http:// 请求会被 ATS 拦（-1022），而 WebKit 加载 http 媒体流是放行的；
 * 且 video 反映的是真实解码能力，比 HTTP 探活准（FLV 能返回 200 但播不了）。
 */
function setupUpdateButton() {
  const st = $('updStatus');
  const remote = state.sources.filter((s) => s.url && !s.local);

  const run = async (ev) => {
    const btnEl = ev && ev.currentTarget;
    if (btnEl) btnEl.disabled = true;
    if (!remote.length) { st.textContent = '没有可更新的远程源'; if (btnEl) btnEl.disabled = false; return; }
    const started = Date.now();
    try {
      await (nativeBridge ? runUpdate(remote, st) : runUpdateWeb(remote, st));
      st.textContent += ' · 用时 ' + Math.round((Date.now() - started) / 1000) + ' 秒';
      if (state.activeSource) selectSource(state.activeSource);
      else if (settings.view === 'channels') { aggLoaded = false; loadAllSources().then(() => { renderGroups(); renderList(); }); }
    } catch (e) {
      st.textContent = '更新失败：' + ((e && e.message) || e);
    }
    if (btnEl) btnEl.disabled = false;
  };

  // macOS App：设置面板触发用的隐藏按钮（原生桥 download/save 链路）
  const btn = $('update');
  if (nativeBridge && remote.length) btn.addEventListener('click', run);

  // 三端可见按钮（侧边栏底部，齿轮旁）：App 走原生桥，网页/PWA 走前端管线
  $('updSourcesBtn').addEventListener('click', run);
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

/* ---------- 网页/PWA 的更新源：无原生桥，fetch + <video> 实测 + 存 localStorage ---------- */
/* 保存的列表按设备隔离（本机浏览器专用），加载时覆盖服务器上的 playlists 文件 */

const PLAYLIST_OVERRIDES_KEY = 'kaitai-playlist-overrides';

function readPlaylistOverrides() {
  try { return JSON.parse(localStorage.getItem(PLAYLIST_OVERRIDES_KEY) || '{}'); }
  catch (e) { return {}; }
}

async function runUpdateWeb(remote, st) {
  const overrides = readPlaylistOverrides();
  const parts = [];
  for (const src of remote) {
    st.textContent = '下载 ' + src.name + '…';
    let raw = '';
    try {
      const res = await fetch(src.url, { cache: 'no-store' });
      raw = res.ok ? await res.text() : '';
      if (!raw) parts.push(src.name + ' 失败：HTTP ' + res.status);
    } catch (e) {
      parts.push(src.name + ' 失败：下载被拒（跨域/网络）');
    }
    if (!raw) continue;

    const channels = parseM3U(raw);
    if (!channels.length) {
      parts.push(src.name + ' 失败：解析不出频道');
      continue;
    }

    const kept = await probeChannels(channels, (done, total) => {
      st.textContent =
        '正在实测 ' + src.name + '：' + done + '/' + total + '（点开就能播的才留下）';
    });

    overrides[src.id] = buildM3U(kept, src.name);
    try {
      localStorage.setItem(PLAYLIST_OVERRIDES_KEY, JSON.stringify(overrides));
    } catch (e) {
      throw new Error('本地存储空间不足，无法保存更新结果');
    }
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
  state.activeGroup = '';
  renderGroups();
  renderList();
}

/* 侧边栏第二区：播放源视图渲染分组行，频道视图渲染五大类 */
function renderGroups() {
  const box = $('groups');
  box.innerHTML = '';

  const mk = (label, val, n) => {
    const b = document.createElement('button');
    b.className = 'gitem' + ((settings.view === 'channels' ? state.activeCat : state.activeGroup) === val ? ' on' : '');
    b.innerHTML =
      '<span class="gname">' + escapeHtml(label) + '</span>' +
      '<span class="gn">' + n + '</span>';
    b.addEventListener('click', () => {
      if (settings.view === 'channels') state.activeCat = val;
      else state.activeGroup = val;
      box.querySelectorAll('.gitem').forEach((x) => x.classList.toggle('on', x === b));
      renderList();
    });
    box.appendChild(b);
  };

  if (settings.view === 'channels') {
    mk('央视频道', '央视频道', state.aggregated.filter((a) => a.cat === '央视频道').length);
    mk('卫视频道', '卫视频道', state.aggregated.filter((a) => a.cat === '卫视频道').length);
    mk('港澳台', '港澳台', state.aggregated.filter((a) => a.cat === '港澳台').length);
    mk('其他', '其他', state.aggregated.filter((a) => a.cat === '其他').length);
    mk('全部频道', '', state.aggregated.length);
    return;
  }

  mk('全部频道', '', state.channels.length);
  state.groups.forEach((g) => {
    mk(g, g, state.channels.filter((c) => c.group === g).length);
  });
}

function renderList() {
  if (settings.view === 'channels') return renderChannelList();
  if (!state.channels.length) return; // 启动早期列表还没载入，保持「加载中…」

  const q = $('q').value.trim().toLowerCase();
  const g = state.activeGroup;
  const rows = state.channels.filter((c) => {
    if (g && c.group !== g) return false;
    if (q && !c.name.toLowerCase().includes(q)) return false;
    return true;
  });

  $('count').textContent =
    '显示 ' + rows.length + ' / ' + state.channels.length + ' 个频道';

  const box = $('list');
  const frag = document.createDocumentFragment();
  state.visibleRows = [];

  // 同一频道可能有多个备用源（同名多条），加序号区分，避免看起来像重复 bug
  const nameCount = {};
  rows.forEach((c) => { nameCount[c.name] = (nameCount[c.name] || 0) + 1; });
  const seen = {};

  rows.forEach((c) => {
    state.visibleRows.push({ ch: c, src: state.activeSource });
    const isDup = nameCount[c.name] > 1;
    const idx = (seen[c.name] = (seen[c.name] || 0) + 1);
    const el = document.createElement('button');
    el.className = 'chan' + (state.current && state.current.url === c.url ? ' on' : '');
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
    nm.textContent = isDup ? stripQual(c.name) + ' ·' + idx : stripQual(c.name);

    const gp = document.createElement('div');
    gp.className = 'gp';
    gp.textContent = c.group;

    el.append(img, nm, gp);
    el.addEventListener('click', () => playChannel(c));
    frag.appendChild(el);
  });

  box.innerHTML = '';
  box.appendChild(frag);

  // 当前频道在列表里的位置保持可见（换台/恢复后不丢）
  const cur = box.querySelector('.chan.on');
  if (cur) cur.scrollIntoView({ block: 'nearest' });
}

/* 频道视图：跨源聚合列表。点行直接播（默认源优先），换源走信息条上的线路按钮 */
function renderChannelList() {
  const q = $('q').value.trim().toLowerCase();
  const cat = state.activeCat;
  const rows = state.aggregated.filter((a) => {
    if (cat && a.cat !== cat) return false;
    if (q && !a.name.toLowerCase().includes(q)) return false;
    return true;
  });

  $('count').textContent =
    '显示 ' + rows.length + ' / ' + state.aggregated.length + ' 个频道';

  const box = $('list');
  const frag = document.createDocumentFragment();
  state.visibleRows = [];

  rows.forEach((a) => {
    const pick = pickDefaultItem(a);
    state.visibleRows.push({ ch: pick.ch, src: pick.src });
    const playing = state.current && a.items.some((it) => it.ch.url === state.current.url);

    const btn = document.createElement('button');
    btn.className = 'chan' + (playing ? ' on' : '');

    const img = document.createElement('img');
    img.alt = '';
    img.loading = 'lazy';
    img.referrerPolicy = 'no-referrer';
    img.style.visibility = 'hidden';
    img.addEventListener('load', () => { img.style.visibility = 'visible'; });
    // 高清台标加载失败时回退到源里带的 logo
    img.addEventListener('error', () => {
      if (a.fallbackLogo && img.dataset.stage !== 'fb') {
        img.dataset.stage = 'fb';
        img.src = a.fallbackLogo;
      } else {
        img.style.visibility = 'hidden';
      }
    });
    if (a.logo) img.src = a.logo;

    const col = document.createElement('div');
    col.className = 'col';
    const nm = document.createElement('div');
    nm.className = 'nm';
    nm.textContent = a.name;
    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = a.items.length + ' 个源 · ' + a.cat;
    col.append(nm, meta);

    btn.append(img, col);
    btn.addEventListener('click', () => playChannel(pick.ch, pick.src));
    frag.appendChild(btn);
  });

  box.innerHTML = '';
  box.appendChild(frag);

  const cur = box.querySelector('.chan.on');
  if (cur) cur.scrollIntoView({ block: 'nearest' });
}

/* ---------- 播放 ---------- */

/* 播放信息条上的源切换：当前频道有多个源时显示，点一下换源接着播 */
function renderSrcSwitch() {
  const box = $('srcSwitch');
  box.innerHTML = '';
  if (!state.current) return;
  const agg = state.aggregated.find((a) =>
    a.items.some((it) => it.ch.url === state.current.url));
  if (!agg || agg.items.length < 2) return;

  const labelCount = {};
  agg.items.forEach((it) => {
    let label = it.src.name;
    if (it.ch.name !== agg.name) {
      const q = qualTag(it.ch.name);
      label += ' · ' + (q || it.ch.name);
    }
    if (labelCount[label]) {
      labelCount[label] += 1;
      label += ' ' + labelCount[label];
    } else {
      labelCount[label] = 1;
    }

    const b = document.createElement('button');
    b.className = 'ss-btn' + (state.current.url === it.ch.url ? ' on' : '');
    b.textContent = label;
    b.title = '切换到 ' + it.src.name + ' 的线路：' + it.ch.url;
    b.addEventListener('click', () => playChannel(it.ch, it.src));
    box.appendChild(b);
  });
}

function playChannel(ch, src) {
  // 频道视图播放时带上了所属源：同步高亮 + 修复「上次频道」记录
  if (src) {
    state.activeSource = src;
    document.querySelectorAll('.src').forEach((b) => {
      b.classList.toggle('on', b.dataset.id === src.id);
    });
  }
  state.current = ch;
  rememberChannel();
  document.querySelectorAll('.chan').forEach((el) => {
    el.classList.toggle('on', el.dataset.url === ch.url);
  });

  $('now').textContent = stripQual(ch.name) + (ch.group ? ' · ' + ch.group : '');
  renderSrcSwitch();
  updateNowPlaying(ch);       // iPhone/iPad 锁屏与灵动岛显示正在播的频道
  closeRailOnNarrow();        // 手机窄屏：选完频道自动收起抽屉
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

/* ---------- 键盘快捷键（播放器相关） ---------- */

// 在当前可见频道列表里向上/向下换台
function stepChannel(dir) {
  const rows = state.visibleRows || [];
  if (!rows.length) return;
  let idx = rows.findIndex((r) => r.ch.url === state.current?.url);
  idx = idx < 0 ? 0 : (idx + dir + rows.length) % rows.length;
  playChannel(rows[idx].ch, rows[idx].src);
}

function toggleMute() {
  if (curVol() > 0) {
    state.prevVol = curVol();
    applyVolume(0, true);
  } else {
    applyVolume(state.prevVol || 50, true);
  }
}

/* ---------- 播放器全屏：隐藏侧边栏/顶栏，画面铺满整个屏幕 ---------- */
let fsIdleTimer = null;

function isFsMode() { return document.body.classList.contains('fs-mode'); }

function fsWake() {
  document.body.classList.remove('fs-idle');
  clearTimeout(fsIdleTimer);
  fsIdleTimer = setTimeout(() => document.body.classList.add('fs-idle'), 2600);
}

function enterFsMode() {
  document.body.classList.add('fs-mode');
  fsWake();
  if (mpvOn) {
    mpvCall('fullscreen');   // 系统全屏 + UI 隐藏后 #screen 铺满窗口 → 画面真全屏
  } else if (IS_IOS && $('video').webkitEnterFullscreen) {
    // iOS Safari/PWA 只支持 video 元素的原生全屏（自带旋转与系统控制条）
    $('video').webkitEnterFullscreen();
    document.body.classList.remove('fs-mode', 'fs-idle');
  } else {
    $('screen').requestFullscreen?.().catch(() => {});
  }
}

function exitFsMode() {
  document.body.classList.remove('fs-mode', 'fs-idle');
  clearTimeout(fsIdleTimer);
  if (mpvOn) {
    mpvCall('fullscreen');
  } else if (IS_IOS && $('video').webkitExitFullscreen) {
    $('video').webkitExitFullscreen();
  } else if (document.fullscreenElement) {
    document.exitFullscreen();
  }
}

function toggleFullscreen() {
  if (isFsMode()) exitFsMode();
  else enterFsMode();
}

// 全屏按钮：toggle（内嵌版走 mpv 原生全屏 + UI 隐藏，网页版走 Fullscreen API）
$('fullscreen').addEventListener('click', toggleFullscreen);

// 网页版：浏览器 Esc 退出全屏时同步移除 UI 隐藏态
document.addEventListener('fullscreenchange', () => {
  if (!document.fullscreenElement && !mpvOn) {
    document.body.classList.remove('fs-mode', 'fs-idle');
    clearTimeout(fsIdleTimer);
  }
});

// 全屏中鼠标动一下 → 控制条浮现，2.6s 无操作自动隐藏
document.addEventListener('mousemove', () => { if (isFsMode()) fsWake(); });

// Esc：任何时候都可退出播放器全屏（不受快捷键开关限制）
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && isFsMode()) exitFsMode();
});

document.addEventListener('keydown', (e) => {
  if (!settings.hotkeys) return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const tag = (e.target.tagName || '').toLowerCase();
  if (tag === 'input' || tag === 'textarea' || tag === 'select') return;

  switch (e.key) {
    case ' ': e.preventDefault(); $('pause').click(); break;
    case 'ArrowUp': e.preventDefault(); stepChannel(-1); break;
    case 'ArrowDown': e.preventDefault(); stepChannel(1); break;
    case 'ArrowLeft': e.preventDefault(); applyVolume(Math.max(0, curVol() - 5), true); break;
    case 'ArrowRight': e.preventDefault(); applyVolume(Math.min(100, curVol() + 5), true); break;
    case 'm': case 'M': toggleMute(); break;
    case 'f': case 'F': toggleFullscreen(); break;
    case 'r': case 'R': $('retry').click(); break;
  }
});

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
    // 暂停时隐藏 mpv 画面层，让网页的暂停图标露出来；恢复播放时再显示画面
    mpvCall('overlay', { hidden: mpvPaused });
    setPauseUI(mpvPaused);
    return;
  }
  const video = $('video');
  if (video.paused) video.play().catch(() => {});
  else video.pause();
});

/* 点画面切换暂停/播放（连接中或出错时不响应） */
$('screen').addEventListener('click', () => {
  if ($('pause').disabled) return;
  if (!$('overlay').classList.contains('hide')) return;
  $('pause').click();
});
$('video').addEventListener('pause', () => setPauseUI(true));
$('video').addEventListener('play', () => setPauseUI(false));

/* 音量：内嵌走 mpv，网页版走 <video>；设置持久化 */
$('vol').addEventListener('input', (e) => applyVolume(+e.target.value || 0, true));
$('vol').value = curVol();
applyVolume(curVol(), false); // 启动即渲染音量图标与初始状态

boot();
