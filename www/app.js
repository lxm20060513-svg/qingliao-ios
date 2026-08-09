// ===== V1.8.4 通用型架构：服务器地址配置 + 登录鉴权（面向 IPA 打包）=====
function getApiBase() {
  return (localStorage.getItem('qingliao_server') || '').replace(/\/+$/, '');
}
function getToken() {
  return sessionStorage.getItem('qingliao_token') || localStorage.getItem('qingliao_token') || '';
}
function setToken(tok, remember) {
  if (remember) { localStorage.setItem('qingliao_token', tok); sessionStorage.removeItem('qingliao_token'); }
  else { sessionStorage.setItem('qingliao_token', tok); localStorage.removeItem('qingliao_token'); }
}
function clearToken() {
  localStorage.removeItem('qingliao_token');
  sessionStorage.removeItem('qingliao_token');
}
let __loginShown = false;
let __suppress401 = 0;
const __origFetch = window.fetch.bind(window);
window.fetch = function (url, opts) {
  opts = opts || {};
  let u = String(url);
  if (u.startsWith('/') && !u.startsWith('//')) u = getApiBase() + u;
  const h = new Headers(opts.headers || {});
  const tok = getToken();
  if (tok && u.indexOf('/api/auth/login') === -1) h.set('X-Auth-Token', tok);
  opts.headers = h;
  return __origFetch(u, opts).then(r => {
    if (r.status === 401 && u.indexOf('/api/auth/login') === -1 && getToken() && !__suppress401) {
      if (!__loginShown) { __loginShown = true; clearToken(); setTimeout(showLogin, 80); }
    }
    return r;
  });
};
function showLogin() {
  const ov = document.getElementById('loginOverlay');
  if (!ov) return;
  const si = document.getElementById('loginServer');
  // V1.8.4 IPA 适配：capacitor:// 下 location.origin 是壳地址不可用——不预填，提示用户必填服务器地址
  const inAppShell = location.protocol === 'capacitor:';
  if (si && !si.value && !inAppShell) si.value = getApiBase() || location.origin;
  ov.style.display = 'flex';
  __loginShown = true;
  setTimeout(() => { const f = document.getElementById('loginUser'); if (f) f.focus(); }, 120);
}
function hideLogin() {
  const ov = document.getElementById('loginOverlay');
  if (ov) ov.style.display = 'none';
  __loginShown = false;
}
async function doLogin() {
  let server = (document.getElementById('loginServer').value || '').trim().replace(/\/+$/, '');
  if (server && !/^https?:\/\//i.test(server)) server = 'http://' + server;
  const username = (document.getElementById('loginUser').value || '').trim();
  const password = document.getElementById('loginPass').value || '';
  const remember = document.getElementById('loginRemember').checked;
  const errEl = document.getElementById('loginError');
  const btn = document.getElementById('loginBtn');
  if (!server || !username || !password) { if (errEl) errEl.textContent = '请填写服务器地址、用户名和密码'; return; }
  if (errEl) errEl.textContent = '';
  if (btn) btn.disabled = true;
  try {
    const res = await __origFetch(server + '/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password, remember })
    });
    const data = await res.json();
    if (res.ok && data.token) {
      if (server !== getApiBase()) localStorage.setItem('qingliao_server', server);  // V1.8.4.1 review：登录成功才保存地址
      setToken(data.token, remember);
      hideLogin();
      location.reload();
    } else if (errEl) {
      errEl.textContent = data.error || '登录失败（' + res.status + '）';
    }
  } catch (e) {
    if (errEl) errEl.textContent = '无法连接服务器：' + (e.message || e);
  } finally {
    if (btn) btn.disabled = false;
  }
}
function doLogout() {
  const tok = getToken();
  if (tok) fetch('/api/auth/logout', { method: 'POST' }).catch(() => {});
  clearToken();
  showLogin();
}
async function changePassword() {
  const oldP = document.getElementById('oldPass').value || '';
  const newP = document.getElementById('newPass').value || '';
  const newP2 = document.getElementById('newPass2').value || '';
  const msg = document.getElementById('pwMsg');
  if (!oldP || !newP) { if (msg) msg.textContent = '请填写旧密码和新密码'; return; }
  if (newP !== newP2) { if (msg) msg.textContent = '两次新密码不一致'; return; }
  if (newP.length < 6) { if (msg) msg.textContent = '新密码至少 6 位'; return; }
  try {
    const res = await fetch('/api/auth/change-password', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ old: oldP, new: newP })
    });
    const data = await res.json();
    if (res.ok) {
      if (msg) { msg.textContent = '✅ 密码已修改，请重新登录'; msg.style.color = '#34c759'; }
      setTimeout(doLogout, 1200);
    } else if (msg) { msg.textContent = data.error || '修改失败'; }
  } catch (e) { if (msg) msg.textContent = '修改失败：' + (e.message || e); }
}
async function testServerConn() {
  const si = document.getElementById('serverInput');
  const msg = document.getElementById('serverMsg');
  if (!si || !msg) return;
  let server = (si.value || '').trim().replace(/\/+$/, '');
  if (server && !/^https?:\/\//i.test(server)) server = 'http://' + server;
  if (!server) { msg.textContent = '请填写服务器地址'; return; }
  msg.textContent = '测试中…';
  try {
    __suppress401++;
    const res = await fetch(server + '/api/auth/status', { method: 'GET' });
    const data = await res.json();
    if (res.ok) { msg.textContent = '✅ 连接正常（' + (data.username || '') + ' 已登录）'; msg.style.color = '#34c759'; }
    else if (res.status === 401) { msg.textContent = '✅ 服务器可达（需登录）'; msg.style.color = '#34c759'; }
    else { msg.textContent = '⚠️ 服务器返回 ' + res.status; msg.style.color = '#ff9500'; }
  } catch (e) { msg.textContent = '❌ 无法连接：' + (e.message || e); msg.style.color = '#ff3b30'; }
  finally { if (__suppress401 > 0) __suppress401--; }
}
function saveServerAddr() {
  const si = document.getElementById('serverInput');
  const msg = document.getElementById('serverMsg');
  if (!si || !msg) return;
  let v = (si.value || '').trim().replace(/\/+$/, '');
  if (v && !/^https?:\/\//i.test(v)) v = 'http://' + v;
  if (!v) { msg.textContent = '地址不能为空'; return; }
  localStorage.setItem('qingliao_server', v);
  msg.textContent = '✅ 已保存，正在重新加载…'; msg.style.color = '#34c759';
  setTimeout(() => location.reload(), 800);
}


    const navItems = document.querySelectorAll('.nav-item');
    const pages = document.querySelectorAll('.page');
    const pageTitle = document.getElementById('pageTitle');
    const menuBtn = document.getElementById('menuBtn');
    const sidebar = document.getElementById('sidebar');
    const sidebarCollapse = document.getElementById('sidebarCollapse');
    const chat = document.getElementById('chat');
    const input = document.getElementById('input');
    const sendBtn = document.getElementById('sendBtn');
    const themeBtn = document.getElementById('themeBtn');
    const themeBtn3 = document.getElementById('themeBtn3');
    let busy = false;
    // 流式输出全局状态（退出会话后重新进入时恢复流式 UI）
    let activeStream = null;
    let streamSaveTimer = null;
    const pageTitles = {
      chat: 'Chat', jobs: '定时任务', kanban: '智能家居',
      logs: '日志', files: '文件管理', settings: '设置', history: '历史会话', about: '关于轻聊'
    };

        // 设置页：模型/状态展示（updateSettingsInfo 在脚本后部 CURRENT_MODEL 定义后调用）
        function updateSettingsInfo() {
          const sm = document.getElementById('settingsModel');
          if (sm) sm.textContent = CURRENT_MODEL || '--';
          const ss = document.getElementById('settingsStatus');
          if (ss) {
            const statusEl = document.getElementById('headerStatus');
            const offline = statusEl && statusEl.querySelector('.status-dot.offline');
            const online = !offline;
            ss.textContent = online ? '🟢 已连接' : '🔴 连接失败';
            ss.style.color = online ? '#22c55e' : 'var(--danger)';
          }
        }
        // 进入设置页时刷新状态展示
        const settingsPage = document.getElementById('page-settings');
        if (settingsPage && window.MutationObserver) {
          const obs = new MutationObserver(() => {
            if (settingsPage.classList.contains('active')) updateSettingsInfo();
          });
          obs.observe(settingsPage, { attributes: true, attributeFilter: ['class'] });
        }
function showPage(name) {
      pages.forEach(p => p.classList.remove('active'));
      const target = document.getElementById('page-' + name);
      if (target) target.classList.add('active');
      navItems.forEach(item => item.classList.toggle('active', item.dataset.page === name));
      if (pageTitle && pageTitles[name]) pageTitle.textContent = pageTitles[name];
      if (window.innerWidth <= 768) closeSidebar();
      if (name === 'history') renderHistory();
      if (name === 'jobs') loadJobs();
      if (name === 'kanban') loadHaDevices();
      if (name === 'nas') loadNasStatus();
      if (name === 'logs') { renderOpLogs(); if (sysLogTabActive) loadSysLogs(); }
      if (name === 'files') {
        // 已解锁才加载列表，否则保持密码层
        loadFileList(fileCwd);  // V1.8.4.1：登录即解锁
      }
    }

    // ==================== NAS 面板（V1.7.2） ====================
    let nasTimer = null;
    function fmtSize(n) {
      if (!n && n !== 0) return '-';
      const u = ['B', 'KB', 'MB', 'GB', 'TB'];
      let i = 0;
      while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
      return n.toFixed(1) + u[i];
    }
    async function loadNasStatus() {
      const statusText = document.getElementById('nasStatusText');
      if (!statusText) return;
      try {
        const r = await fetch('/api/nas/status', { headers: { } });
        if (!r.ok) throw new Error('HTTP ' + r.status);
        const j = await r.json();
        if (!j.ok) throw new Error(j.error || 'failed');
        document.getElementById('nasHostname').textContent = j.hostname || '-';
        document.getElementById('nasUptime').textContent = j.uptime || '-';
        document.getElementById('nasOvUptime').textContent = j.uptime || '-';
        // CPU（概览）
        const cpu = j.cpu || 0;
        const cpuOv = document.getElementById('nasOvCpu');
        cpuOv.textContent = cpu + '%';
        cpuOv.className = 'ov-value' + (cpu > 85 ? ' warn' : '');
        // 内存（概览 + 进度条）
        const mem = j.mem || {};
        const memPct = mem.total ? Math.round(100 * mem.used / mem.total) : 0;
        const memOv = document.getElementById('nasOvMem');
        memOv.textContent = memPct + '%';
        memOv.className = 'ov-value' + (memPct > 85 ? ' warn' : '');
        const memBar = document.getElementById('nasMemBar');
        if (memBar) {
          memBar.style.width = memPct + '%';
          memBar.className = 'nas-bar' + (memPct > 85 ? ' crit' : memPct > 60 ? ' warn' : '');
        }
        const memText = document.getElementById('nasMemText');
        if (memText) memText.textContent = fmtSize(mem.used) + ' / ' + fmtSize(mem.total) + ' (' + memPct + '%)';
        // 磁盘（概览取最大使用率 + 列表）
        const disks = j.disks || [];
        const maxDisk = disks.reduce((mx, d) => Math.max(mx, parseInt(d.pct, 10) || 0), 0);
        const diskOv = document.getElementById('nasOvDisk');
        diskOv.textContent = maxDisk + '%';
        diskOv.className = 'ov-value' + (maxDisk > 90 ? ' warn' : maxDisk > 75 ? ' ok' : ' ok');
        const disksBox = document.getElementById('nasDisks');
        const NAS_MOUNT_NOTES = { '/volume1': '固态硬盘' };   // V1.7.5：挂载点备注
        disksBox.innerHTML = disks.map(d => {
          const pct = parseInt(d.pct, 10) || 0;
          const cls = pct > 90 ? ' crit' : pct > 75 ? ' warn' : '';
          const note = NAS_MOUNT_NOTES[d.mnt] ? '<span class="nas-note">· ' + escapeHtml(NAS_MOUNT_NOTES[d.mnt]) + '</span>' : '';
          return '<div class="nas-disk"><div class="nas-disk-row"><span>' + escapeHtml(d.mnt) + note + '</span><b>' + pct + '%</b></div>'
            + '<div class="nas-meter"><div class="nas-bar' + cls + '" style="width:' + pct + '%"></div></div>'
            + '<div class="nas-meter-text">' + fmtSize(d.used) + ' / ' + fmtSize(d.total) + '</div></div>';
        }).join('');
        // 服务（HomeKit 卡片 + 内存）
        const svc = j.services || {};
        document.getElementById('nasServices').innerHTML = [
          { k: 'qingliao', name: '轻聊后端', icon: '💬', memK: 'qingliao_mem' },
          { k: 'hermes', name: 'Hermes 网关', icon: '🤖', memK: 'hermes_mem' }
        ].map(s => {
          const st = svc[s.k];
          const cls = st === true ? 'ok' : st === false ? 'fail' : 'wait';
          const txt = st === true ? '运行中' : st === false ? '异常' : '未知';
          const mem = svc[s.memK] ? fmtSize(svc[s.memK]) : '';
          const dotCls = st === true ? 'ok' : st === false ? 'fail' : 'wait';
          const memBadge = mem ? '<span class="nas-mem">' + mem + '</span>' : '';
          return '<div class="ha-device' + (st === true ? ' on' : '') + '">'
            + '<div class="ha-icon">' + s.icon + '</div>'
            + '<div class="ha-name">' + s.name + '</div>'
            + '<div class="ha-state-row"><span class="ha-state"><span class="nas-svc-dot ' + dotCls + '"></span>' + txt + '</span>' + memBadge + '</div>'
            + '</div>';
        }).join('');
        statusText.textContent = '更新于 ' + new Date().toLocaleTimeString();
      } catch (e) {
        statusText.textContent = '加载失败: ' + e.message;
      }
    }
    function startNasAutoRefresh() {
      if (nasTimer) return;
      nasTimer = setInterval(() => { loadNasStatus(); }, 10000);
    }

    // ==================== 日志模块 ====================
    let sysLogTabActive = false;

    // 系统日志：通过 NAS 代理读取
    function loadSysLogs() {
      const list = document.getElementById('sysLogsList');
      if (!list) return;
      list.innerHTML = '<div class="log-empty">加载中...</div>';
      const level = (document.getElementById('sysLogLevel') || {}).value || 'all';
      const q = ((document.getElementById('sysLogSearch') || {}).value || '').trim();
      fetch('/api/logs/sys?level=' + encodeURIComponent(level) + '&q=' + encodeURIComponent(q) + '&limit=200', { headers: { } })
        .then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
        .then(data => {
          const logs = data.logs || [];
          if (!logs.length) { list.innerHTML = '<div class="log-empty">暂无系统日志</div>'; return; }
          list.innerHTML = logs.map(l => {
            const lvl = (l.level || 'INFO').toUpperCase();
            const cls = lvl === 'ERROR' ? 'error' : (lvl === 'WARNING' || lvl === 'WARN' ? 'warn' : '');
            const src = l.source || 'hermes';
            const srcLabel = src === 'cron' ? '定时' : (src === 'haproxy' ? '智能家居' : '系统');
            return '<div class="log-item"><span class="log-source ' + escapeHtml(src) + '">' + escapeHtml(srcLabel) + '</span><span class="log-time">' + escapeHtml(l.time || '') + '</span><span class="log-msg' + (cls ? ' ' + cls : '') + '">[' + escapeHtml(lvl) + '] ' + escapeHtml(l.msg || '') + '</span></div>';
          }).join('');
        })
        .catch(e => {
          list.innerHTML = '<div class="log-empty">⚠️ 系统日志不可用（' + escapeHtml(e.message) + '）</div>';
        });
    }

    // 日志页标签切换
    document.querySelectorAll('.log-tab').forEach(tab => {
      tab.addEventListener('click', () => {
        document.querySelectorAll('.log-tab').forEach(t => t.classList.remove('active'));
        tab.classList.add('active');
        const isSys = tab.dataset.logTab === 'sys';
        sysLogTabActive = isSys;
        document.getElementById('opLogsList').style.display = isSys ? 'none' : 'block';
        document.getElementById('sysLogsList').style.display = isSys ? 'block' : 'none';
        document.getElementById('logFilterRow').style.display = isSys ? 'flex' : 'none';
        document.getElementById('logClearBtn').style.display = isSys ? 'none' : 'inline-block';
        document.getElementById('logExportBtn').textContent = isSys ? '📤 导出' : '📤 导出';
        if (isSys) loadSysLogs(); else renderOpLogs();
      });
    });

    // 导出按钮：操作日志导出 JSON，系统日志导出 TXT
    const logExportBtn = document.getElementById('logExportBtn');
    if (logExportBtn) {
      logExportBtn.onclick = () => {
        if (sysLogTabActive) {
          // 系统日志导出：带当前筛选条件，下载 txt
          const level = (document.getElementById('sysLogLevel') || {}).value || 'all';
          const q = ((document.getElementById('sysLogSearch') || {}).value || '').trim();
          const url = '/api/logs/export?level=' + encodeURIComponent(level) + '&q=' + encodeURIComponent(q) + '&limit=2000';
          fetch(url, { headers: { } })
            .then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.blob(); })
            .then(blob => {
              const a = document.createElement('a');
              a.href = URL.createObjectURL(blob);
              a.download = 'qingliao_syslog.txt';
              a.click();
              URL.revokeObjectURL(a.href);
            })
            .catch(err => alert('导出失败: ' + err.message));
          return;
        }
        const logs = getOpLogs();
        const blob = new Blob([JSON.stringify(logs, null, 2)], { type: 'application/json' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = 'qingliao_logs_' + new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-') + '.json';
        a.click();
        URL.revokeObjectURL(url);
      };
    }

    // 清空操作日志
    const logClearBtn = document.getElementById('logClearBtn');
    if (logClearBtn) {
      logClearBtn.onclick = () => {
        if (!confirm('确定清空所有操作日志吗？')) return;
        clearOpLogs();
        renderOpLogs();
      };
    }

    // 系统日志筛选
    const sysLogLevel = document.getElementById('sysLogLevel');
    if (sysLogLevel) sysLogLevel.onchange = () => { if (sysLogTabActive) loadSysLogs(); };
    const sysLogSearch = document.getElementById('sysLogSearch');
    if (sysLogSearch) sysLogSearch.addEventListener('input', () => { if (sysLogTabActive) loadSysLogs(); });
    const sysLogRefresh = document.getElementById('sysLogRefresh');
    if (sysLogRefresh) sysLogRefresh.onclick = () => { if (sysLogTabActive) loadSysLogs(); };

    // 清除系统日志（仅清本地日志文件，docker 日志保留）
    const sysLogClear = document.getElementById('sysLogClear');
    if (sysLogClear) {
      sysLogClear.onclick = () => {
        if (!sysLogTabActive) return;
        if (!confirm('确定清除本地系统日志吗？\n（将清空定时任务/智能家居代理日志，Hermes 主日志不受影响）')) return;
        fetch('/api/logs/clear', { method: 'POST', headers: { } })
          .then(r => r.json())
          .then(() => { loadSysLogs(); logEvent('system', '清除系统日志'); })
          .catch(e => console.error('Clear logs failed:', e));
      };
    }

    // ==================== 文件管理 ====================
    const FILES_API = '/api/files';
    let fileCwd = '';       // 当前 NAS 目录相对路径

    function filesHeaders() {
      return {};  // V1.8.4.1：登录 token 由全局 fetch 注入，文件页不再独立密码
    }

    function filesFetch(path, opts) {
      opts = opts || {};
      opts.headers = Object.assign({}, filesHeaders(), opts.headers || {});
      return fetch(FILES_API + path, opts);
    }

    const FILE_ICON = {
      dir: '📁',
      image: '🖼️', text: '📄', code: '📝', pdf: '📕',
      audio: '🎵', video: '🎬', archive: '📦', json: '📊', other: '📄'
    };

    function fileIconFor(name, isDir) {
      if (isDir) return FILE_ICON.dir;
      const ext = name.split('.').pop().toLowerCase();
      if (['png','jpg','jpeg','gif','webp','bmp','svg','ico'].includes(ext)) return FILE_ICON.image;
      if (['mp3','wav','flac','aac','m4a'].includes(ext)) return FILE_ICON.audio;
      if (['mp4','mkv','avi','mov','webm'].includes(ext)) return FILE_ICON.video;
      if (['zip','rar','7z','tar','gz','bz2'].includes(ext)) return FILE_ICON.archive;
      if (['pdf'].includes(ext)) return FILE_ICON.pdf;
      if (['json'].includes(ext)) return FILE_ICON.json;
      if (['txt','md','log','csv','xml'].includes(ext)) return FILE_ICON.text;
      if (['html','htm','css','js','py','yml','yaml','conf','ini','sh'].includes(ext)) return FILE_ICON.code;
      return FILE_ICON.other;
    }

    function fileSizeHuman(n) {
      if (n < 1024) return n + ' B';
      const units = ['KB','MB','GB','TB'];
      let i = -1;
      do { n /= 1024; i++; } while (n >= 1024 && i < units.length - 1);
      return n.toFixed(1) + ' ' + units[i];
    }

    function fileTimeHuman(ts) {
      const d = new Date(ts * 1000);
      const pad = x => x.toString().padStart(2, '0');
      return d.getFullYear() + '-' + pad(d.getMonth()+1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
    }

    function renderBreadcrumb(cwd) {
      const el = document.getElementById('fileBreadcrumb');
      if (!el) return;
      const parts = cwd ? cwd.split('/') : [];
      let html = '<span class="file-crumb" data-path="">根目录</span>';
      let acc = '';
      for (const p of parts) {
        acc = acc ? acc + '/' + p : p;
        html += '<span class="file-crumb-sep">/</span><span class="file-crumb" data-path="' + escapeHtml(acc) + '">' + escapeHtml(p) + '</span>';
      }
      el.innerHTML = html;
    }

    function loadFileList(path) {
      const list = document.getElementById('fileList');
      if (!list) return;
      list.innerHTML = '<div class="log-empty">加载中...</div>';
      filesFetch('/list?path=' + encodeURIComponent(path || ''))
        .then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
        .then(data => {
          if (data.error) { list.innerHTML = '<div class="log-empty">⚠️ ' + escapeHtml(data.error) + '</div>'; return; }
          fileCwd = data.cwd || '';
          renderBreadcrumb(fileCwd);
          document.getElementById('fileCount').textContent = data.dir_count + ' 个目录 / ' + data.file_count + ' 个文件';
          if (!data.entries.length) { list.innerHTML = '<div class="log-empty">空目录</div>'; return; }
          list.innerHTML = data.entries.map(e => {
            const icon = fileIconFor(e.name, e.is_dir);
            const rel = (fileCwd ? fileCwd + '/' : '') + e.name;
            const meta = e.is_dir ? '目录' : fileSizeHuman(e.size) + ' · ' + fileTimeHuman(e.mtime);
            return '<div class="file-item" data-path="' + escapeHtml(rel) + '" data-dir="' + e.is_dir + '">'
              + '<span class="file-icon">' + icon + '</span>'
              + '<div class="file-info">'
              + '<div class="file-name">' + escapeHtml(e.name) + '</div>'
              + '<div class="file-meta">' + escapeHtml(meta) + '</div>'
              + '</div>'
              + '<div class="file-actions">'
              + (e.is_dir ? '' : '<button class="file-action-btn download" data-act="download">⬇ 下载</button><button class="file-action-btn" data-act="preview">👁 预览</button>')
              + '</div>'
              + '</div>';
          }).join('');
        })
        .catch(e => {
          list.innerHTML = '<div class="log-empty">⚠️ 无法加载文件列表（' + escapeHtml(e.message) + '）</div>';
        });
    }

    // 文件列表点击（委托）：目录进入 / 文件操作
    document.addEventListener('click', (e) => {
      const actionBtn = e.target.closest('.file-action-btn');
      if (actionBtn) {
        e.stopPropagation();
        const item = actionBtn.closest('.file-item');
        if (!item) return;
        const path = item.dataset.path;
        const act = actionBtn.dataset.act;
        if (act === 'download') {
          // 下载需带密码 header，用 blob 方式
          filesFetch('/download?path=' + encodeURIComponent(path))
            .then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.blob(); })
            .then(blob => {
              const url = URL.createObjectURL(blob);
              const a = document.createElement('a');
              a.href = url;
              a.download = path.split('/').pop();
              a.click();
              setTimeout(() => URL.revokeObjectURL(url), 5000);
            })
            .catch(e => console.error('Download failed:', e));
        } else if (act === 'preview') {
          openFilePreview(path);
        }
        return;
      }
      const item = e.target.closest('.file-item[data-dir="true"]');
      if (item) {
        loadFileList(item.dataset.path);
      }
    });

    // 面包屑点击
    document.addEventListener('click', (e) => {
      const crumb = e.target.closest('.file-crumb');
      if (crumb) loadFileList(crumb.dataset.path);
    });

    // 文件预览
    function openFilePreview(path) {
      const overlay = document.getElementById('filePreviewOverlay');
      const title = document.getElementById('filePreviewTitle');
      const body = document.getElementById('filePreviewBody');
      if (!overlay) return;
      title.textContent = path.split('/').pop();
      body.innerHTML = '<div class="log-empty">加载中...</div>';
      overlay.classList.add('show');
      const ext = path.split('.').pop().toLowerCase();
      const imgExts = ['png','jpg','jpeg','gif','webp','bmp','svg','ico'];
      if (imgExts.includes(ext)) {
        // 图片用 blob 加载（需要带密码 header，不能直接 img src）
        filesFetch('/preview?path=' + encodeURIComponent(path))
          .then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.blob(); })
          .then(blob => {
            const url = URL.createObjectURL(blob);
            body.innerHTML = '<img src="' + url + '" alt="' + escapeHtml(path) + '">';
          })
          .catch(e => { body.innerHTML = '<div class="log-empty">⚠️ ' + escapeHtml(e.message) + '</div>'; });
      } else {
        filesFetch('/preview?path=' + encodeURIComponent(path))
          .then(r => {
            if (r.status === 415) { body.innerHTML = '<div class="log-empty">该文件类型不支持预览，请下载查看</div>'; throw new Error('unsupported'); }
            if (!r.ok) throw new Error('HTTP ' + r.status);
            return r.json();
          })
          .then(data => {
            if (data.error) { body.innerHTML = '<div class="log-empty">⚠️ ' + escapeHtml(data.error) + '</div>'; return; }
            body.innerHTML = '<pre>' + escapeHtml(data.text) + '</pre>' + (data.truncated ? '<div class="file-meta" style="padding:8px 0 0;color:var(--text-muted);font-size:11px;">⚠️ 文件较大，仅显示前 200KB</div>' : '');
          })
          .catch(e => { if (e.message !== 'unsupported') body.innerHTML = '<div class="log-empty">⚠️ ' + escapeHtml(e.message) + '</div>'; });
      }
    }

    // 关闭预览
    const filePreviewClose = document.getElementById('filePreviewClose');
    if (filePreviewClose) {
      filePreviewClose.onclick = () => document.getElementById('filePreviewOverlay').classList.remove('show');
    }
    const filePreviewOverlay = document.getElementById('filePreviewOverlay');
    if (filePreviewOverlay) {
      filePreviewOverlay.addEventListener('click', (e) => {
        if (e.target === filePreviewOverlay) filePreviewOverlay.classList.remove('show');
      });
    }

    // 刷新按钮
    const fileRefreshBtn = document.getElementById('fileRefreshBtn');
    if (fileRefreshBtn) fileRefreshBtn.onclick = () => loadFileList(fileCwd);

    // 上传按钮：选择文件后上传到微信文件目录
    const fileUploadBtn = document.getElementById('fileUploadBtn');
    const fileUploadInput = document.getElementById('fileUploadInput');
    if (fileUploadBtn && fileUploadInput) {
      fileUploadBtn.onclick = () => fileUploadInput.click();
      fileUploadInput.addEventListener('change', () => {
        const files = Array.from(fileUploadInput.files || []);
        if (!files.length) return;
        uploadFiles(files);
      });
    }

    function uploadFiles(files) {
      const list = document.getElementById('fileList');
      const btn = document.getElementById('fileUploadBtn');
      if (btn) { btn.disabled = true; btn.textContent = '⬆ 上传中 ' + files.length + ' 个...'; }
      let done = 0, okCount = 0, failCount = 0;
      const next = () => {
        if (done >= files.length) {
          if (btn) { btn.disabled = false; btn.textContent = '⬆ 上传到微信文件'; }
          fileUploadInput.value = '';
          loadFileList(fileCwd);
          if (list) list.innerHTML = '<div class="log-empty">✅ 上传完成：成功 ' + okCount + ' 个' + (failCount ? '，失败 ' + failCount + ' 个' : '') + '</div>';
          setTimeout(() => loadFileList(fileCwd), 800);
          return;
        }
        const file = files[done++];
        const formData = new FormData();
        formData.append('file', file);
        filesFetch('/upload', { method: 'POST', body: formData })
          .then(r => r.json())
          .then(data => {
            if (data.ok) {
              okCount++;
              logEvent('file', '上传文件: ' + data.saved);
            } else {
              failCount++;
              console.error('Upload failed:', data.error);
            }
            next();
          })
          .catch(e => {
            failCount++;
            console.error('Upload error:', e);
            next();
          });
      };
      next();
    }

    // 聊天本地文件：localStorage 里可导出的数据（会话、日志）
    function renderChatFiles() {
      const list = document.getElementById('chatFileList');
      if (!list) return;
      const items = [];
      const sessions = getSessions();
      items.push({
        name: '会话备份 (' + sessions.length + ' 个会话)',
        desc: '全部聊天记录 JSON',
        action: 'exportAllSessions'
      });
      const logs = getOpLogs();
      items.push({
        name: '操作日志 (' + logs.length + ' 条)',
        desc: '聊天/设备/会话操作记录 JSON',
        action: 'exportOpLogs'
      });
      if (!items.length) { list.innerHTML = '<div class="log-empty">暂无聊天文件</div>'; return; }
      list.innerHTML = items.map((it, idx) =>
        '<div class="file-item">'
        + '<span class="file-icon">📊</span>'
        + '<div class="file-info">'
        + '<div class="file-name">' + escapeHtml(it.name) + '</div>'
        + '<div class="file-meta">' + escapeHtml(it.desc) + '</div>'
        + '</div>'
        + '<div class="file-actions"><button class="file-action-btn download" data-chat-export="' + idx + '">⬇ 导出</button></div>'
        + '</div>'
      ).join('');
      // 绑定导出
      list.querySelectorAll('[data-chat-export]').forEach(btn => {
        btn.onclick = () => {
          const it = items[parseInt(btn.dataset.chatExport)];
          if (it.action === 'exportAllSessions') {
            exportAllSessions();
          } else if (it.action === 'exportOpLogs') {
            const logs = getOpLogs();
            const blob = new Blob([JSON.stringify(logs, null, 2)], { type: 'application/json' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = 'qingliao_oplogs_' + new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-') + '.json';
            a.click();
            URL.revokeObjectURL(url);
          }
        };
      });
    }

    // 文件页标签切换
    document.querySelectorAll('.file-tab').forEach(tab => {
      tab.addEventListener('click', () => {
        document.querySelectorAll('.file-tab').forEach(t => t.classList.remove('active'));
        tab.classList.add('active');
        const isNas = tab.dataset.fileTab === 'nas';
        document.getElementById('nasFilePanel').style.display = isNas ? 'block' : 'none';
        document.getElementById('chatFilePanel').style.display = isNas ? 'none' : 'block';
        if (isNas) loadFileList(fileCwd); else renderChatFiles();
      });
    });

    // V1.8：技能模块已移除

    // ==================== 智能家居 ====================
    const HA_PROXY = '/api/ha';
    let haStates = [];
    let haCurrentTab = 'lights';
    let haTimer = null;

    // 常用传感器关键字（挑常用的显示）
    const SENSOR_KEYWORDS = ['温度', '湿度', 'pm2.5', 'pm25', '空气质量', '用电', '功率', '电量', '电压', '电流', '水浸', '门磁', '人体', '光照', 'lux', 'co2', 'tvoc'];

    function haApi(path, method, body) {
      const opts = { method: method || 'GET', headers: { } };
      if (body) {
        opts.headers['Content-Type'] = 'application/json';
        opts.body = JSON.stringify(body);
      }
      return fetch(HA_PROXY + path, opts).then(r => {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      });
    }

    function haSetStatus(msg, isError) {
      const el = document.getElementById('haStatus');
      if (!el) return;
      el.textContent = msg || '';
      el.className = 'ha-status' + (isError ? ' error' : '');
    }

    function haIconFor(domain, state) {
      const on = state === 'on';
      switch (domain) {
        case 'light': return on ? '💡' : '🔅';
        case 'climate': return state === 'off' ? '❄️' : '🌡️';
        case 'switch': return on ? '🔛' : '🔕';
        case 'sensor':
          const n = state ? state.toLowerCase() : '';
          if (n.includes('温度') || n.includes('temp')) return '🌡️';
          if (n.includes('湿度') || n.includes('humid')) return '💧';
          if (n.includes('pm') || n.includes('空气')) return '🌫️';
          if (n.includes('电') || n.includes('power') || n.includes('energy')) return '⚡';
          return '📊';
        default: return '📟';
      }
    }

    function haCleanName(entityId, friendlyName) {
      // 去除名字中的重复词（如"厨房灯  厨房灯 开关"）
      if (!friendlyName) return entityId;
      const parts = friendlyName.split(/\s+/).filter(Boolean);
      const seen = new Set();
      const unique = parts.filter(p => {
        if (seen.has(p)) return false;
        seen.add(p);
        return true;
      });
      return unique.join(' ');
    }

    function haIsCommonSensor(s) {
      const attrs = s.attributes || {};
      const name = (attrs.friendly_name || s.entity_id).toLowerCase();
      const unit = attrs.unit_of_measurement || '';
      // 有单位但常见类型的传感器
      return SENSOR_KEYWORDS.some(k => name.includes(k.toLowerCase()));
    }

    function haFilterByTab() {
      const list = [];
      for (const s of haStates) {
        // 过滤离线/不可用实体
        if (s.state === 'unavailable' || s.state === 'offline' || s.state === 'unknown') continue;
        const domain = s.entity_id.split('.')[0];
        if (haCurrentTab === 'lights' && domain === 'light') list.push(s);
        else if (haCurrentTab === 'climate' && domain === 'climate') list.push(s);
        else if (haCurrentTab === 'switches' && domain === 'switch') list.push(s);
        else if (haCurrentTab === 'sensors' && (domain === 'sensor' || domain === 'binary_sensor')) {
          if (haIsCommonSensor(s)) list.push(s);
        }
      }
      // 可用的在前（已过滤离线，这里按更新时间排序可选）
      return list;
    }

    function haRender() {
      const grid = document.getElementById('haDeviceGrid');
      if (!grid) return;
      const list = haFilterByTab();
      if (!list.length) {
        grid.innerHTML = '<div class="ha-empty">该分类暂无设备</div>';
        return;
      }
      grid.innerHTML = '';
      list.forEach(s => {
        const card = haBuildCard(s);
        if (card) grid.appendChild(card);
      });
    }

    function haBuildCard(s) {
      const domain = s.entity_id.split('.')[0];
      const attrs = s.attributes || {};
      const name = haCleanName(s.entity_id, attrs.friendly_name);
      const state = s.state;
      const div = document.createElement('div');
      // climate 的 state 是 auto/cool 等，需根据 isOn 映射为 on/off 类
      let stateClass = state;
      if (domain === 'climate') {
        stateClass = (state !== 'off' && state !== 'unavailable' && state !== 'unknown') ? 'on' : 'off';
      }
      div.className = 'ha-device ' + stateClass + (domain === 'climate' ? ' climate-card' : '');
      div.dataset.entity = s.entity_id;
      div.dataset.domain = domain;

      if (domain === 'climate') {
        const temp = attrs.temperature;
        const isOn = state !== 'off' && state !== 'unavailable' && state !== 'unknown';
        const hvac = isOn ? state : 'off';
        const hvacLabels = { off: '关', heat: '制热', cool: '制冷', auto: '自动', dry: '除湿', fan_only: '送风' };
        div.innerHTML = ''
          + '<div class="ha-climate-top">'
          + '<div class="ha-climate-left">'
          + '<div class="ha-icon">' + (isOn ? '🌡️' : '❄️') + '</div>'
          + '<div class="ha-temp">' + (temp ? temp : '--') + '<span>°C</span></div>'
          + '</div>'
          + '<div class="ha-climate-info">'
          + '<div class="ha-name">' + escapeHtml(name) + '</div>'
          + '<div class="ha-state">' + (isOn ? '运行中' : '已关闭') + '</div>'
          + '</div>'
          + '<button class="ha-climate-power" data-cmd="power" title="' + (isOn ? '关闭' : '开启') + '">' + (isOn ? '⏻' : '⏻') + '</button>'
          + '</div>'
          + '<div class="ha-climate-controls-row">'
          + '<span class="ha-controls-label">模式</span>'
          + '<div class="ha-climate-controls">'
          + Object.keys(hvacLabels).map(m => '<button data-cmd="hvac" data-mode="' + m + '" class="' + (hvac === m ? 'active' : '') + '">' + hvacLabels[m] + '</button>').join('')
          + '</div>'
          + '<span class="ha-controls-label">温度</span>'
          + '<div class="ha-climate-controls">'
          + '<button class="temp-btn" data-cmd="temp-down">−</button>'
          + '<button class="temp-btn" data-cmd="temp-up">+</button>'
          + '</div>'
          + '</div>';
      } else {
        const isOn = state === 'on';
        const icon = haIconFor(domain, state);
        let stateText = state === 'on' ? '已开启' : (state === 'off' ? '已关闭' : state);
        const isToggleable = domain === 'light' || domain === 'switch';
        // 传感器显示值
        if (domain === 'sensor' || domain === 'binary_sensor') {
          const unit = attrs.unit_of_measurement || '';
          stateText = s.state + (unit ? ' ' + unit : '');
        }
        // 状态行：状态文字 + 内联小开关（与传感器排版一致）
        const stateRow = isToggleable
          ? '<div class="ha-state-row"><span class="ha-state">' + escapeHtml(stateText) + '</span><button class="ha-toggle" title="' + (isOn ? '关闭' : '开启') + '">' + (isOn ? '⏻' : '⏻') + '</button></div>'
          : '<div class="ha-state">' + escapeHtml(stateText) + '</div>';
        div.innerHTML = ''
          + '<div class="ha-icon">' + icon + '</div>'
          + '<div class="ha-name">' + escapeHtml(name) + '</div>'
          + stateRow;
      }
      return div;
    }

    function haToggleEntity(entityId, domain) {
      const card = document.querySelector('.ha-device[data-entity="' + entityId + '"]');
      if (card) card.classList.add('busy');
      haApi('/services/' + domain + '/toggle', 'POST', { entity_id: entityId })
        .then(() => {
          logEvent('device', '切换 ' + domain + ': ' + entityId);
          haSetStatus('已发送指令，刷新状态...');
          return loadHaDevices();
        })
        .catch(e => {
          haSetStatus('控制失败: ' + e.message, true);
          if (card) card.classList.remove('busy');
        });
    }

    function haSetClimate(entityId, cmd, mode) {
      const card = document.querySelector('.ha-device[data-entity="' + entityId + '"]');
      if (card) card.classList.add('busy');
      let service = 'climate/set_hvac_mode';
      let data = { entity_id: entityId };
      if (cmd === 'power') {
        // 电源：off -> 恢复上次模式(auto)，on -> off
        const isOn = card && card.classList.contains('on');
        service = 'climate/set_hvac_mode';
        data.hvac_mode = isOn ? 'off' : 'auto';
      }
      if (cmd === 'temp-up') { service = 'climate/set_temperature'; data.temperature = (parseFloat(document.querySelector('.ha-device[data-entity="' + entityId + '"] .ha-temp').textContent) || 26) + 1; }
      if (cmd === 'temp-down') { service = 'climate/set_temperature'; data.temperature = (parseFloat(document.querySelector('.ha-device[data-entity="' + entityId + '"] .ha-temp').textContent) || 26) - 1; }
      if (cmd === 'hvac') { data.hvac_mode = mode; }
      haApi('/services/' + service, 'POST', data)
        .then(() => {
          const desc = cmd === 'power' ? '电源开关' : (cmd === 'temp-up' ? '温度+' : (cmd === 'temp-down' ? '温度-' : '模式→' + (mode || '')));
          logEvent('device', '空调 ' + desc + ': ' + entityId);
          return loadHaDevices();
        })
        .catch(e => {
          haSetStatus('控制失败: ' + e.message, true);
          if (card) card.classList.remove('busy');
        });
    }

    // 顶栏总览统计
    function haUpdateOverview(states) {
      const set = (id, val, cls) => {
        const el = document.getElementById(id);
        if (el) { el.textContent = val; el.className = 'ov-value' + (cls ? ' ' + cls : ''); }
      };
      // 灯开启数量
      const lights = states.filter(s => s.entity_id.startsWith('light.'));
      const onLights = lights.filter(s => s.state === 'on').length;
      set('ovLights', onLights + ' / ' + lights.filter(s => s.state !== 'unavailable' && s.state !== 'unknown').length + ' 盏', onLights > 0 ? 'ok' : '');
      // 空调运行数量（state 非 off 且在线）
      const clims = states.filter(s => s.entity_id.startsWith('climate.') && s.state !== 'unavailable' && s.state !== 'offline' && s.state !== 'unknown');
      const onClims = clims.filter(s => s.state !== 'off').length;
      set('ovClimate', onClims + ' / ' + clims.length + ' 台', onClims > 0 ? 'ok' : '');
      // 门锁电量
      const lockBattery = states.find(s => s.entity_id.includes('bacn01') && s.entity_id.includes('battery_level'));
      if (lockBattery && lockBattery.state !== 'unavailable') {
        const v = parseFloat(lockBattery.state);
        set('ovLockBattery', Math.round(v) + '%', v <= 20 ? 'warn' : 'ok');
      } else {
        set('ovLockBattery', '--');
      }
      // 猫眼电量
      const doorbellBattery = states.find(s => s.entity_id.includes('chuangmi') && s.entity_id.includes('battery_level'));
      if (doorbellBattery && doorbellBattery.state !== 'unavailable') {
        const v = parseFloat(doorbellBattery.state);
        set('ovDoorbellBattery', Math.round(v) + '%', v <= 20 ? 'warn' : 'ok');
      } else {
        set('ovDoorbellBattery', '--');
      }
      // 安防状态
      const alarm = states.find(s => s.entity_id.includes('alarmstatus'));
      if (alarm && alarm.state !== 'unavailable') {
        const st = alarm.state;
        const isArmed = st === '布防' || st === 'armed' || st === 'armed_home' || st === 'armed_away' || st === 'on';
        set('ovAlarm', st, isArmed ? 'ok' : 'warn');
      } else {
        set('ovAlarm', '--');
      }
    }

    function loadHaDevices() {
      haSetStatus('加载中...');
      return haApi('/states')
        .then(states => {
          haStates = states;
          haRender();
          haUpdateOverview(states);
          const total = haFilterByTab().length;
          const online = states.filter(s => s.state !== 'unavailable' && s.state !== 'offline' && s.state !== 'unknown').length;
          haSetStatus('共 ' + online + ' 个在线实体，当前显示 ' + total + ' 个');
        })
        .catch(e => {
          haSetStatus('无法连接智能家居: ' + e.message, true);
          const grid = document.getElementById('haDeviceGrid');
          if (grid) grid.innerHTML = '<div class="ha-empty">⚠️ 无法连接 Home Assistant（' + escapeHtml(e.message || '未知错误') + '）</div>';
        });
    }

    // 事件绑定
    document.querySelectorAll('.ha-tab').forEach(tab => {
      tab.addEventListener('click', () => {
        document.querySelectorAll('.ha-tab').forEach(t => t.classList.remove('active'));
        tab.classList.add('active');
        haCurrentTab = tab.dataset.haTab;
        haRender();
      });
    });

    const haRefreshBtn = document.getElementById('haRefreshBtn');
    if (haRefreshBtn) {
      haRefreshBtn.onclick = () => {
        haRefreshBtn.classList.add('spinning');
        const p = loadHaDevices();
        if (p && p.finally) {
          p.finally(() => setTimeout(() => haRefreshBtn.classList.remove('spinning'), 600));
        } else {
          setTimeout(() => haRefreshBtn.classList.remove('spinning'), 1200);
        }
      };
    }

    const haAutoRefresh = document.getElementById('haAutoRefresh');
    if (haAutoRefresh) {
      haAutoRefresh.addEventListener('change', () => {
        if (haTimer) { clearInterval(haTimer); haTimer = null; }
        if (haAutoRefresh.checked) {
          haTimer = setInterval(() => loadHaDevices(), 10000);
        }
      });
      // 默认开启自动刷新（仅当页面激活时轮询）
      haTimer = setInterval(() => {
        if (document.getElementById('page-kanban').classList.contains('active')) loadHaDevices();
      }, 10000);
    }

    // 设备网格点击事件（委托）
    document.addEventListener('click', (e) => {
      const toggleBtn = e.target.closest('.ha-toggle');
      if (toggleBtn) {
        e.stopPropagation();
        const card = toggleBtn.closest('.ha-device');
        if (card) haToggleEntity(card.dataset.entity, card.dataset.domain);
        return;
      }
      const climateBtn = e.target.closest('.ha-climate-controls button, .ha-climate-power');
      if (climateBtn) {
        e.stopPropagation();
        const card = climateBtn.closest('.ha-device');
        if (!card) return;
        const entityId = card.dataset.entity;
        const cmd = climateBtn.dataset.cmd || 'power';
        haSetClimate(entityId, cmd, climateBtn.dataset.mode);
        return;
      }
      // 点击卡片本身（灯/开关切换）
      const card = e.target.closest('.ha-device');
      if (card && (card.dataset.domain === 'light' || card.dataset.domain === 'switch')) {
        haToggleEntity(card.dataset.entity, card.dataset.domain);
      }
    });

    // Jobs
    async function loadJobs() {
      const jobsList = document.getElementById('jobsList');
      jobsList.innerHTML = '<div style="text-align:center;color:var(--text-muted);padding:40px 0;">加载中...</div>';

      try {
        const res = await fetch('/api/cron/tasks', { headers: { } });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const tasks = await res.json();
        renderJobs(tasks);
      } catch (e) {
        jobsList.innerHTML = '<div style="text-align:center;color:var(--danger);padding:40px 0;">加载失败: ' + escapeHtml(e.message) + '</div>';
      }
    }
        const refreshJobsBtn = document.getElementById('refreshJobsBtn');
        if (refreshJobsBtn) refreshJobsBtn.onclick = loadJobs;

    // 任务操作状态
    let editingJobId = null;

    function renderJobs(tasks) {
      const jobsList = document.getElementById('jobsList');
      if (!tasks || tasks.length === 0) {
        jobsList.innerHTML = '<div style="text-align:center;color:var(--text-muted);padding:40px 0;">暂无任务，点击右上角「新增任务」创建</div>';
        return;
      }

      jobsList.innerHTML = tasks.map(task => {
        const enabled = task.enabled;
        const statusBadge = enabled
          ? '<span class="job-card-status on">● 启用</span>'
          : '<span class="job-card-status off">○ 停用</span>';
        const lastRun = task.last_run_at ? new Date(task.last_run_at).toLocaleString('zh-CN') : '从未';
        const nextRun = task.next_run_at ? new Date(task.next_run_at).toLocaleString('zh-CN') : '--';
        const deliver = task.deliver === 'weixin' ? '微信' : task.deliver === 'origin' ? '原会话' : task.deliver === 'local' ? '本地' : task.deliver === 'all' ? '全部' : '--';
        const schedule = task.schedule_display || task.cron || '--';
        const promptPreview = (task.prompt || '').slice(0, 120) + ((task.prompt || '').length > 120 ? '...' : '');
        return `
          <div class="job-card${enabled ? '' : ' disabled'}" data-job-id="${escapeHtml(task.id || '')}">
            <div class="job-card-top">
              <span class="job-card-name">${escapeHtml(task.name || '未命名')}</span>
              ${statusBadge}
            </div>
            <span class="job-card-schedule">${escapeHtml(schedule)}</span>
            ${promptPreview ? '<div class="job-card-prompt">' + escapeHtml(promptPreview) + '</div>' : ''}
            <div class="job-card-meta">
              <span>📦 投递: ${deliver}</span>
              <span>⏭ 下次: ${nextRun}</span>
              <span>✅ 上次: ${lastRun}</span>
            </div>
            <div class="job-card-actions">
              <button class="job-action-btn primary" data-job-act="run">▶ 立即执行</button>
              <button class="job-action-btn" data-job-act="toggle">${enabled ? '⏸ 停用' : '▶ 启用'}</button>
              <button class="job-action-btn" data-job-act="edit">✏️ 编辑</button>
              <button class="job-action-btn danger" data-job-act="delete">🗑 删除</button>
            </div>
          </div>
        `;
      }).join('');
    }

    // 任务卡片操作（委托）
    document.addEventListener('click', (e) => {
      const btn = e.target.closest('.job-action-btn');
      if (!btn) return;
      const card = btn.closest('.job-card');
      if (!card) return;
      const jobId = card.dataset.jobId;
      const act = btn.dataset.jobAct;
      if (!jobId) return;

      if (act === 'run') {
        if (!confirm('确定立即执行该任务吗？')) return;
        fetch('/api/cron/tasks/' + jobId + '/run', { method: 'POST', headers: { } })
          .then(r => r.json())
          .then(() => { loadJobs(); logEvent('system', '立即执行任务: ' + (card.querySelector('.job-card-name')?.textContent || jobId)); })
          .catch(err => alert('执行失败: ' + err.message));
      } else if (act === 'toggle') {
        const enable = card.classList.contains('disabled');
        fetch('/api/cron/tasks/' + jobId, {
          method: 'PATCH',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ enabled: enable })
        })
          .then(r => r.json())
          .then(() => { loadJobs(); })
          .catch(err => alert('操作失败: ' + err.message));
      } else if (act === 'edit') {
        openJobModal(jobId);
      } else if (act === 'delete') {
        if (!confirm('确定删除该任务吗？此操作不可恢复。')) return;
        fetch('/api/cron/tasks/' + jobId, { method: 'DELETE', headers: { } })
          .then(r => r.json())
          .then(() => { loadJobs(); logEvent('system', '删除任务'); })
          .catch(err => alert('删除失败: ' + err.message));
      }
    });

    // 打开任务编辑弹窗（jobId 为空 = 新增）
    function openJobModal(jobId) {
      editingJobId = jobId || null;
      const overlay = document.getElementById('jobModalOverlay');
      if (!overlay) return;
      document.getElementById('jobModalTitle').textContent = jobId ? '编辑任务' : '新增任务';
      document.getElementById('jobFormError').textContent = '';
      document.getElementById('jobFormName').value = '';
      document.getElementById('jobFormCron').value = '0 9 * * *';
      document.getElementById('jobFormPrompt').value = '';
      document.getElementById('jobFormDeliver').value = 'origin';
      document.getElementById('jobFormEnabled').checked = true;

      if (jobId) {
        // 从当前列表找任务数据回填（遍历查找，避免 CSS 选择器注入）
        const cards = document.querySelectorAll('.job-card');
        let card = null;
        for (const c of cards) {
          if (c.dataset.jobId === String(jobId)) { card = c; break; }
        }
        if (card) {
          document.getElementById('jobFormName').value = card.querySelector('.job-card-name').textContent;
          document.getElementById('jobFormCron').value = card.querySelector('.job-card-schedule').textContent;
          const promptEl = card.querySelector('.job-card-prompt');
          if (promptEl) document.getElementById('jobFormPrompt').value = promptEl.textContent;
          document.getElementById('jobFormEnabled').checked = !card.classList.contains('disabled');
        }
        // 尝试从任务列表获取完整 prompt（可能有截断）
        fetch('/api/cron/tasks', { headers: { } })
          .then(r => r.json())
          .then(tasks => {
            const t = (tasks || []).find(x => String(x.id) === String(jobId));
            if (t) {
              document.getElementById('jobFormName').value = t.name || '';
              document.getElementById('jobFormCron').value = t.schedule_display || t.cron || '';
              document.getElementById('jobFormPrompt').value = t.prompt || '';
              document.getElementById('jobFormDeliver').value = t.deliver || 'origin';
              document.getElementById('jobFormEnabled').checked = t.enabled !== false;
            }
          })
          .catch(() => {});
      }
      overlay.classList.add('show');
    }

    // 保存任务（新增或编辑）
    const jobFormSave = document.getElementById('jobFormSave');
    if (jobFormSave) {
      jobFormSave.onclick = () => {
        const name = document.getElementById('jobFormName').value.trim();
        const cron = document.getElementById('jobFormCron').value.trim();
        const prompt = document.getElementById('jobFormPrompt').value.trim();
        const deliver = document.getElementById('jobFormDeliver').value;
        const enabled = document.getElementById('jobFormEnabled').checked;
        const errEl = document.getElementById('jobFormError');
        if (!name) { errEl.textContent = '请输入任务名称'; return; }
        if (!cron) { errEl.textContent = '请输入执行计划（cron 表达式）'; return; }
        if (!prompt) { errEl.textContent = '请输入提示词'; return; }

        const payload = { name, cron, prompt, deliver, enabled };
        const url = editingJobId ? '/api/cron/tasks/' + editingJobId : '/api/cron/tasks';
        const method = editingJobId ? 'PATCH' : 'POST';

        fetch(url, {
          method,
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload)
        })
          .then(r => r.json())
          .then(() => {
            document.getElementById('jobModalOverlay').classList.remove('show');
            loadJobs();
            logEvent('system', (editingJobId ? '编辑任务: ' : '新增任务: ') + name);
          })
          .catch(err => { errEl.textContent = '保存失败: ' + err.message; });
      };
    }

    // 关闭弹窗
    const jobModalClose = document.getElementById('jobModalClose');
    if (jobModalClose) jobModalClose.onclick = () => document.getElementById('jobModalOverlay').classList.remove('show');
    const jobModalOverlay = document.getElementById('jobModalOverlay');
    if (jobModalOverlay) {
      jobModalOverlay.addEventListener('click', (e) => {
        if (e.target === jobModalOverlay) jobModalOverlay.classList.remove('show');
      });
    }

    // 新增按钮
    const newJobBtn = document.getElementById('newJobBtn');
    if (newJobBtn) newJobBtn.onclick = () => openJobModal(null);

    function escapeHtml(text) {
      const div = document.createElement('div');
      div.textContent = text;
      return div.innerHTML;
    }

    // Markdown 渲染引擎：marked + DOMPurify + highlight.js
    function renderMarkdown(text) {
      if (typeof marked === 'undefined') {
        return escapeHtml(text).replace(/\n/g, '<br>');
      }
      try {
        marked.setOptions({
          breaks: true,
          gfm: true
        });
        let raw = marked.parse(text || '');
        if (typeof DOMPurify !== 'undefined') {
          raw = DOMPurify.sanitize(raw, { ADD_ATTR: ['target'] });
        } else {
          // 安全回退：DOMPurify 缺失（CDN 失败）时强制转义，不信任 marked 输出
          return escapeHtml(text).replace(/\n/g, '<br>');
        }
        // highlight code blocks after rendering（hljs 缺失时触发懒加载）
        const container = document.createElement('div');
        container.innerHTML = raw;
        const codeBlocks = container.querySelectorAll('pre code');
        if (codeBlocks.length) {
          if (typeof hljs === 'undefined') {
            // 动态加载 highlight.js（缓存避免重复下载）
            loadLib('/libs/highlight.min.js')
              .then(() => { if (window.hljs) hljs.highlightAll(); })
              .catch(() => {});
          } else {
            codeBlocks.forEach(block => { try { hljs.highlightElement(block); } catch (e) {} });
          }
        }
        return container.innerHTML;
      } catch (e) {
        return escapeHtml(text).replace(/\n/g, '<br>');
      }
    }

    // 代码块增强：折叠 + 复制按钮
    // V1.2：消息图片懒加载（长会话滚动到才加载，省流量省内存）
    function enhanceImages(container) {
      if (!container) return;
      container.querySelectorAll('img:not([loading])').forEach(img => {
        img.loading = 'lazy';
        img.decoding = 'async';
      });
    }

    function enhanceCodeBlocks(container) {
      if (!container) return;
      container.querySelectorAll('pre').forEach(pre => {
        if (pre.dataset.enhanced) return;
        pre.dataset.enhanced = '1';
        const code = pre.querySelector('code');
        const lang = code && code.className ? (code.className.replace('hljs language-', '').replace('language-', '') || 'code') : 'code';
        const header = document.createElement('div');
        header.className = 'code-header';
        const langSpan = document.createElement('span');
        langSpan.textContent = lang;
        const btns = document.createElement('div');
        const copyBtn = document.createElement('button');
        copyBtn.className = 'copy-code-btn';
        copyBtn.textContent = '📋 复制';
        copyBtn.onclick = (e) => {
          e.stopPropagation();
          const text = code ? code.textContent : pre.textContent;
          navigator.clipboard.writeText(text).then(() => {
            copyBtn.textContent = '✅ 已复制';
            setTimeout(() => { copyBtn.textContent = '📋 复制'; }, 1500);
          }).catch(() => {
            copyBtn.textContent = '❌ 失败';
          });
        };
        const foldBtn = document.createElement('button');
        foldBtn.className = 'code-fold-btn';
        foldBtn.textContent = '▲ 折叠';
        let collapsed = false;
        foldBtn.onclick = (e) => {
          e.stopPropagation();
          collapsed = !collapsed;
          code.style.maxHeight = collapsed ? '200px' : '';
          code.style.overflow = collapsed ? 'hidden' : '';
          foldBtn.textContent = collapsed ? '▼ 展开' : '▲ 折叠';
        };
        btns.appendChild(copyBtn);
        btns.appendChild(foldBtn);
        header.appendChild(langSpan);
        header.appendChild(btns);
        pre.parentNode.insertBefore(header, pre);
      });
    }

    // V1.3：markdown 渲染内存缓存（会话切换/重复内容不再重复解析；LRU 上限 300 条防内存膨胀）
    const mdCache = new Map();
    const MD_CACHE_MAX = 300;
    function toSafeHtml(text) {
      if (mdCache.has(text)) return mdCache.get(text);
      const html = renderMarkdown(text);
      if (mdCache.size >= MD_CACHE_MAX) mdCache.delete(mdCache.keys().next().value);
      mdCache.set(text, html);
      return html;
    }

    // === V1.1 性能优化：流式增量渲染 ===
    // 流式期间只更新纯文本（textContent，零 markdown 解析/零 HTML 重建），
    // done 时一次性 markdown 最终渲染 —— 长消息从"每 0.8s 全量解析"→"全程只解析 1 次"
    const renderStreamingChunk = (el, full) => {
      if (!el) return;
      let body = el.querySelector('.stream-body');
      if (!body) {
        const hdr = el.querySelector('.msg-header');   // 保留时间戳头部（如有）
        el.innerHTML = '';
        if (hdr) el.appendChild(hdr);
        else el.insertAdjacentHTML('afterbegin', '<div class="msg-header"><div class="msg-avatar">H</div><span class="msg-sender">轻聊</span></div>');
        body = document.createElement('div');
        body.className = 'stream-body';
        el.appendChild(body);
      }
      body.textContent = full;   // 纯文本，零解析
    };
    const renderStreamingFinal = (el, full) => {
      if (!el) return;
      const hdr = el.querySelector('.msg-header');
      el.innerHTML = '';
      if (hdr) el.appendChild(hdr);
      else el.insertAdjacentHTML('afterbegin', '<div class="msg-header"><div class="msg-avatar">H</div><span class="msg-sender">轻聊</span></div>');
      const content = document.createElement('div');
      content.innerHTML = toSafeHtml(full || '');
      el.appendChild(content);
      enhanceCodeBlocks(el);
      enhanceImages(el);
    };
    // V1.2：流式轮询工厂（合并 send/recover 两份重复实现）
    // 持有 offset/full/hasContent/failCount/pollTimer，差异化逻辑经回调注入
    const createStreamPoller = (opts) => {
      const { getTaskId, onChunk, onDone } = opts;
      let full = opts.initialFull || '';
      let hasContent = !!full;
      let offset = full.length;
      let failCount = 0;
      let pollTimer = null;
      // V1.3：间隔自适应——有增量 500ms 提速，连续 3 次无内容降到 2000ms 省电省请求
      let intervalMs = 800;
      let idleStreak = 0;
      const restartInterval = () => {
        if (pollTimer) { clearInterval(pollTimer); pollTimer = setInterval(pollOnce, intervalMs); }
      };
      const pollOnce = async () => {
        try {
          const r = await fetch('/api/stream/' + getTaskId() + '?offset=' + offset, {
            headers: { }
          });
          if (!r.ok) throw new Error('HTTP ' + r.status);
          failCount = 0;
          const j = await r.json();
          if (j.content) {
            offset += j.content.length;
            full += j.content;
            hasContent = true;
            if (onChunk) onChunk(full);
            idleStreak = 0;
            if (intervalMs !== 500) { intervalMs = 500; restartInterval(); }
          } else if (!j.done) {
            idleStreak++;
            if (idleStreak >= 3 && intervalMs !== 2000) { intervalMs = 2000; restartInterval(); }
          }
          if (j.done) onDone(j.status, j.error || '');
        } catch (e) {
          // V1.1：连续失败 10 次即停止（后端/网络挂了不再无限重试打 NAS）
          if (++failCount >= 10) onDone('error', '连接中断，请重试');
          else console.warn('Stream poll failed (backend continues):', e);
        }
      };
      return {
        pollOnce,
        start: () => { pollTimer = setInterval(pollOnce, intervalMs); pollOnce(); },
        stop: () => { if (pollTimer) { clearInterval(pollTimer); pollTimer = null; } },
        full: () => full,
        hasContent: () => hasContent,
      };
    };


    navItems.forEach(item => {
      item.addEventListener('click', () => showPage(item.dataset.page));
    });

    let sbOpenedAt = 0;   // V1.1.1：侧栏最近打开时刻（看门狗动画窗口保护，顶层声明供 openSidebar 与看门狗共用）
    function openSidebar() {
      sidebar.classList.add('open');
      sbOpenedAt = Date.now();   // V1.1.1：记录打开时刻，看门狗跳过滑入动画窗口
      const mask = document.getElementById('sidebarMask');
      if (mask) mask.classList.add('show');
    }
    function closeSidebar() {
      sidebar.classList.remove('open');
      const mask = document.getElementById('sidebarMask');
      if (mask) mask.classList.remove('show');
    }

    // 移动端：点遮罩关闭侧栏
    const sidebarMask = document.getElementById('sidebarMask');
    if (sidebarMask) sidebarMask.addEventListener('click', closeSidebar);

    if (menuBtn) menuBtn.addEventListener('click', () => {
      if (sidebar.classList.contains('open')) closeSidebar();
      else {
        openSidebar();
      }
    });
    if (sidebarCollapse) sidebarCollapse.addEventListener('click', closeSidebar);

    let touchStartX = 0;
    let touchStartY = 0;
    document.addEventListener('touchstart', (e) => {
      touchStartX = e.changedTouches[0].screenX;
      touchStartY = e.changedTouches[0].screenY;
    }, { passive: true });
    document.addEventListener('touchend', (e) => {
      const dx = e.changedTouches[0].screenX - touchStartX;
      const dy = e.changedTouches[0].screenY - touchStartY;
      // 键盘弹出时页面滑动多用于收起键盘，不触发侧栏手势（防误开侧栏+蒙板）
      if (window.visualViewport && window.visualViewport.height < window.innerHeight - 150) return;
      const activePageEl = document.querySelector('.page.active');
      // 边缘滑出侧栏（输入框已在最上层，蒙板不再影响聊天；水平主导防滚动误触）
      const horizontal = Math.abs(dx) > Math.abs(dy) * 1.5;   // 水平主导，斜向滚动不误触
      if (horizontal && dx > 70 && touchStartX < 40 && !sidebar.classList.contains('open')) {
        openSidebar();
      }
      if (dx < -60 && sidebar.classList.contains('open')) closeSidebar();
    }, { passive: true });

    // Theme: one source of truth
    (function initTheme() {
      const saved = localStorage.getItem('theme');
      const isDark = saved === 'dark' || (!saved && window.matchMedia('(prefers-color-scheme: dark)').matches);
      if (isDark) document.documentElement.classList.add('dark');
      const hljsLight = document.getElementById('hljsLight');
      const hljsDark = document.getElementById('hljsDark');
      if (hljsLight) hljsLight.disabled = isDark;
      if (hljsDark) hljsDark.disabled = !isDark;
    })();

    function toggleTheme() {
      const isDark = document.documentElement.classList.toggle('dark');
      localStorage.setItem('theme', isDark ? 'dark' : 'light');
      // 同步 highlight.js 主题
      const hljsLight = document.getElementById('hljsLight');
      const hljsDark = document.getElementById('hljsDark');
      if (hljsLight) hljsLight.disabled = isDark;
      if (hljsDark) hljsDark.disabled = !isDark;
    }

    if (themeBtn) themeBtn.onclick = toggleTheme;
    if (themeBtn3) themeBtn3.onclick = toggleTheme;

    // Connection status
    const headerStatus = document.getElementById('headerStatus');
    const headerModel = document.getElementById('headerModel');
    // 当前模型（与 send 请求体一致；如响应返回真实 model 会动态更新）
    // V1.5：模型持久化——localStorage 保存用户选择，快捷切换一键生效
    let CURRENT_MODEL = localStorage.getItem('hermes_current_model') || 'deepseek-v4-flash';
    // V1.5：可用模型列表（OpenCode Go 订阅 26 个 + StepFun 3 个，实测可用）
    const QUICK_MODELS = [
      { group: 'OpenCode Go', models: [
        { provider: 'opencode', id: 'deepseek-v4-flash', name: 'DeepSeek V4 Flash' },
        { provider: 'opencode', id: 'deepseek-v4-flash-free', name: 'DeepSeek V4 Flash Free' },
        { provider: 'opencode', id: 'deepseek-v4-pro', name: 'DeepSeek V4 Pro' },
        { provider: 'opencode', id: 'kimi-k3', name: 'Kimi K3' },
        { provider: 'opencode', id: 'kimi-k2.7-code', name: 'Kimi K2.7 Code' },
        { provider: 'opencode', id: 'kimi-k2.6', name: 'Kimi K2.6' },
        { provider: 'opencode', id: 'kimi-k2.5', name: 'Kimi K2.5' },
        { provider: 'opencode', id: 'glm-5.2', name: 'GLM 5.2' },
        { provider: 'opencode', id: 'glm-5.1', name: 'GLM 5.1' },
        { provider: 'opencode', id: 'glm-5', name: 'GLM 5' },
        { provider: 'opencode', id: 'minimax-m3', name: 'MiniMax M3' },
        { provider: 'opencode', id: 'minimax-m2.7', name: 'MiniMax M2.7' },
        { provider: 'opencode', id: 'minimax-m2.5', name: 'MiniMax M2.5' },
        { provider: 'opencode', id: 'qwen3.8-max', name: '通义千问 3.8 Max' },
        { provider: 'opencode', id: 'qwen3.7-max', name: '通义千问 3.7 Max' },
        { provider: 'opencode', id: 'qwen3.7-plus', name: '通义千问 3.7 Plus' },
        { provider: 'opencode', id: 'qwen3.6-plus', name: '通义千问 3.6 Plus' },
        { provider: 'opencode', id: 'qwen3.5-plus', name: '通义千问 3.5 Plus' },
        { provider: 'opencode', id: 'mimo-v2-pro', name: '小米 MiMo V2 Pro' },
        { provider: 'opencode', id: 'mimo-v2-omni', name: '小米 MiMo V2 Omni' },
        { provider: 'opencode', id: 'mimo-v2.5-pro', name: '小米 MiMo V2.5 Pro' },
        { provider: 'opencode', id: 'mimo-v2.5', name: '小米 MiMo V2.5' },
        { provider: 'opencode', id: 'hy3', name: '阶跃 Step HY3' },
        { provider: 'opencode', id: 'hy3-preview', name: '阶跃 Step HY3 Preview' },
        { provider: 'opencode', id: 'gpt-5.6-luna', name: 'GPT 5.6 Luna' },
        { provider: 'opencode', id: 'grok-4.5', name: 'Grok 4.5' }
      ]},
      { group: 'StepFun', models: [
        { provider: 'stepfun', id: 'step-3.7-flash', name: 'StepFun 3.7 Flash' },
        { provider: 'stepfun', id: 'step-router-v1', name: 'StepFun Router' },
        { provider: 'stepfun', id: 'step-3.5-flash-2603', name: 'StepFun 3.5 Flash' }
      ]},
      { group: 'DeepSeek 官方（按量计费）', models: [
        { provider: 'deepseek', id: 'deepseek-v4-flash', name: 'DeepSeek V4 Flash' },
        { provider: 'deepseek', id: 'deepseek-v4-pro', name: 'DeepSeek V4 Pro' }
      ]},
      { group: '小米 MiMo 官方', models: [
        { provider: 'xiaomi', id: 'mimo-1.5-flash', name: 'MiMo 1.5 Flash' },
        { provider: 'xiaomi', id: 'mimo-v2-omni', name: 'MiMo V2 Omni' }
      ]}
    ];
    function setConnectionStatus(online) {
      if (!headerStatus) return;
      const dot = headerStatus.querySelector('.status-dot');
      const text = headerStatus.querySelector('.status-text');
      if (dot) dot.classList.toggle('offline', !online);
      if (text) text.textContent = online ? '已连接' : '连接失败';
      // 同步设置页状态
      const ss = document.getElementById('settingsStatus');
      if (ss) {
        ss.textContent = online ? '🟢 已连接' : '🔴 连接失败';
        ss.style.color = online ? '#22c55e' : 'var(--danger)';
      }
    }
    function updateModelName(name) {
      if (headerModel) headerModel.textContent = name || '';
      const sm = document.getElementById('settingsModel');
      if (sm) sm.textContent = name || CURRENT_MODEL || '--';
    }

    // V1.5：设置页模型快捷切换——渲染分组列表 + 设为当前
    function setCurrentModel(id, name, provider) {
      CURRENT_MODEL = id;
      try {
        localStorage.setItem('hermes_current_model', id);
        localStorage.setItem('hermes_current_provider', provider || '');
      } catch (e) {}
      updateModelName(id);
      renderQuickModels();
      showToast('已切换到 ' + (name || id));
    }
    // V1.5.2：分组可用性探测（取组内第一个模型，结果缓存 5 分钟）
    const GROUP_STATUS_KEY = 'qingliao_group_status';
    const GROUP_STATUS_TTL = 5 * 60 * 1000;
    function getGroupStatus(groupName) {
      try {
        const d = JSON.parse(localStorage.getItem(GROUP_STATUS_KEY) || '{}');
        const s = d[groupName];
        if (s) {
          // V1.5.5：可用/失败统一缓存 30 秒，避免长时间误报；点击圆点可强制重测
          const ttl = 30000;
          if (Date.now() - s.ts < ttl) return s;
        }
      } catch (e) {}
      return null;
    }
    // V1.5.7：手动刷新所有分组可用性（清缓存重新探测）
    function refreshModelStatus() {
      try { localStorage.removeItem(GROUP_STATUS_KEY); } catch (e) {}
      renderQuickModels();
      showToast('正在刷新模型状态…');
    }
    // V1.5.9：同步 provider 官方模型列表（覆盖内置，存 localStorage）
    const SYNC_KEY = 'qingliao_synced_models';
    async function syncModels(g) {
      const prov = g.models[0] && g.models[0].provider;
      if (!prov) { showToast('同步失败：该组无 provider'); return; }
      showToast('正在同步 ' + g.group + ' 模型列表…');
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 20000);   // V1.6 审查加固：20s 超时
      try {
        const r = await fetch('/api/stream/sync-models?provider=' + encodeURIComponent(prov), {
          headers: { },
          signal: ctrl.signal
        });
        if (!r.ok) throw new Error('HTTP ' + r.status);
        const j = await r.json();
        clearTimeout(timer);
        if (j.ok && Array.isArray(j.models)) {
          const list = j.models.map(id => ({ id, name: id, provider: prov }));
          try {
            const all = JSON.parse(localStorage.getItem(SYNC_KEY) || '{}');
            all[g.group] = list;
            localStorage.setItem(SYNC_KEY, JSON.stringify(all));
          } catch (e) {}
          renderQuickModels();
          showToast('已同步 ' + g.group + '：' + j.models.length + ' 个模型');
        } else {
          showToast('同步失败：' + (j.error || '未知错误'));
        }
      } catch (e) {
        clearTimeout(timer);
        showToast('同步失败：' + (e.name === 'AbortError' ? '超时' : e.message));
      }
    }
    function getGroupModels(g) {
      try {
        const all = JSON.parse(localStorage.getItem(SYNC_KEY) || '{}');
        if (all[g.group] && Array.isArray(all[g.group]) && all[g.group].length) return all[g.group];
      } catch (e) {}
      return g.models;
    }
    function deleteFromGroupStatus(groupName) {
      try {
        const d = JSON.parse(localStorage.getItem(GROUP_STATUS_KEY) || '{}');
        delete d[groupName];
        localStorage.setItem(GROUP_STATUS_KEY, JSON.stringify(d));
      } catch (e) {}
    }
    // V1.6 审查加固：同组探测去重（in-flight 标记），防并发重复请求
    const GROUP_CHECKING = {};
    async function checkGroup(g) {
      if (GROUP_CHECKING[g.group]) return;   // 已在探测中，跳过
      const probe = g.models[0];
      if (!probe) return;
      GROUP_CHECKING[g.group] = true;
      let ok = false, err = '';
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 12000);   // 12s 超时
      try {
        // V1.5.6：带 provider 探测——无 provider 时 Hermes 会 fallback 默认模型（假绿灯）
        const q = '/api/stream/check-model?model=' + encodeURIComponent(probe.id) + '&provider=' + encodeURIComponent(probe.provider || '');
        const r = await fetch(q, {
          headers: { },
          signal: ctrl.signal
        });
        if (!r.ok) throw new Error('HTTP ' + r.status);
        const j = await r.json();
        ok = !!j.ok; err = j.error || '';
      } catch (e) { err = (e.name === 'AbortError') ? '超时' : e.message; }
      clearTimeout(timer);
      delete GROUP_CHECKING[g.group];
      try {
        const d = JSON.parse(localStorage.getItem(GROUP_STATUS_KEY) || '{}');
        d[g.group] = { ok, err, ts: Date.now() };
        localStorage.setItem(GROUP_STATUS_KEY, JSON.stringify(d));
      } catch (e) {}
      renderQuickModels();
    }
    function renderQuickModels() {
      const box = document.getElementById('quickModelsList');
      if (!box || !Array.isArray(QUICK_MODELS)) return;
      let html = '';
      QUICK_MODELS.forEach(g => {
        const st = getGroupStatus(g.group);
        const safeGroup = escapeHtml(g.group);
        // V1.5.5：绿点=可用 红点=不可用（title 悬停看详情），点击圆点强制重测
        let badge = '<span class="qm-dot qm-dot-wait" title="检测中…" data-group="' + safeGroup + '"></span>';
        if (st) {
          badge = st.ok
            ? '<span class="qm-dot qm-dot-ok" title="当前可用" data-group="' + safeGroup + '"></span>'
            : '<span class="qm-dot qm-dot-fail" title="' + escapeHtml(st.err || '不可用') + '" data-group="' + safeGroup + '"></span>';
        }
        html += '<div class="qm-group" style="display:flex;align-items:center;justify-content:space-between;">'
          + '<span>' + safeGroup + badge + '</span>'
          + '<button class="msg-action-btn qm-sync-btn" style="font-size:10.5px;padding:2px 8px;" data-group="' + safeGroup + '">↻ 同步列表</button>'
          + '</div>';
        // 首次渲染触发探测（无缓存时）
        if (!st) setTimeout(() => checkGroup(g), 50);
        getGroupModels(g).forEach(m => {
          const isCur = m.id === CURRENT_MODEL;
          const safeName = escapeHtml(m.name);
          const safeId = escapeHtml(m.id);
          html += '<div class="qm-row" data-model="' + safeId + '" data-name="' + safeName + '" data-provider="' + escapeHtml(m.provider || '') + '">'
            + '<span class="qm-name' + (isCur ? ' qm-current' : '') + '">' + safeName + '</span>'
            + (isCur
                ? '<span class="qm-badge">✓ 当前</span>'
                : '<button class="msg-action-btn qm-btn">设为当前</button>')
            + '</div>';
        });
      });
      box.innerHTML = html;
    }

    // API Key (认证统一走网关 API_SERVER_KEY，保留读取能力)
    function getApiKey() { return localStorage.getItem('hermes_api_key') || ''; }

    // ==================== 操作日志 ====================
    const LOG_STORAGE_KEY = 'qingliao_op_logs';
    const LOG_MAX = 500;

    function logEvent(type, msg) {
      try {
        const logs = JSON.parse(localStorage.getItem(LOG_STORAGE_KEY) || '[]');
        logs.push({
          t: Date.now(),
          type: type,       // chat / device / session / system / file
          msg: String(msg || '')
        });
        // 只保留最近 500 条
        while (logs.length > LOG_MAX) logs.shift();
        localStorage.setItem(LOG_STORAGE_KEY, JSON.stringify(logs));
      } catch (e) { /* 日志失败不影响主流程 */ }
    }

    function getOpLogs() {
      try { return JSON.parse(localStorage.getItem(LOG_STORAGE_KEY) || '[]'); }
      catch (e) { return []; }
    }

    function clearOpLogs() {
      localStorage.removeItem(LOG_STORAGE_KEY);
    }

    const LOG_TYPE_ICON = {
      chat: '💬', device: '🔌', session: '📁', system: '⚙️', file: '📎', error: '⚠️'
    };

    function renderOpLogs() {
      const list = document.getElementById('opLogsList');
      if (!list) return;
      const logs = getOpLogs();
      if (!logs.length) {
        list.innerHTML = '<div class="log-empty">暂无操作记录</div>';
        return;
      }
      // 倒序：最新在前
      const sorted = [...logs].reverse();
      list.innerHTML = sorted.map(l => {
        const d = new Date(l.t);
        const time = d.getMonth() + 1 + '-' + d.getDate() + ' ' + d.getHours().toString().padStart(2,'0') + ':' + d.getMinutes().toString().padStart(2,'0') + ':' + d.getSeconds().toString().padStart(2,'0');
        const icon = LOG_TYPE_ICON[l.type] || '📋';
        return '<div class="log-item"><span class="log-icon">' + icon + '</span><span class="log-time">' + time + '</span><span class="log-msg">' + escapeHtml(l.msg) + '</span></div>';
      }).join('');
    }

    
// Chat
    function appendMsg(role, text, opts) {
      opts = opts || {};
      const div = document.createElement('div');
      div.className = 'msg ' + role;
      div.dataset.role = role;
      div.dataset.raw = text;
      const now = new Date();
      const time = now.getHours().toString().padStart(2,'0') + ':' + now.getMinutes().toString().padStart(2,'0');
      const sender = role === 'user' ? 'U' : 'H';
      const safeText = toSafeHtml(text);
      let actionsHtml = '';
      if (role === 'user' || role === 'assistant') {
        actionsHtml = '<div class="msg-actions">'
          + '<button class="msg-action-btn" data-action="copy">📋 复制</button>'
          + (role === 'assistant' ? '<button class="msg-action-btn" data-action="regenerate">🔄 重新生成</button>' : '')
          + (opts.isError ? '<button class="msg-action-btn" data-action="retry">↻ 重试</button>' : '')
          + '</div>';
      }
      div.innerHTML = '<div class="msg-header"><div class="msg-avatar">' + sender + '</div><span class="msg-sender">' + (role === 'user' ? 'You' : '轻聊') + '</span><span class="msg-time">' + time + '</span></div>' + safeText + actionsHtml;
      enhanceCodeBlocks(div);
      chat.appendChild(div);
      chat.scrollTop = chat.scrollHeight;
      return div;
    }

    function showWelcome() {
      if (!chat.children.length) {
        const welcome = document.createElement('div');
        welcome.className = 'welcome';
        welcome.innerHTML = '<div class="welcome-icon">💬</div><div class="welcome-title">你好，我是轻聊</div><div class="welcome-desc">输入消息与 轻聊 对话</div>';
        chat.appendChild(welcome);
      }
    }

    // P4-13: 批量渲染消息（DocumentFragment 减少回流）
    function renderSessionMessages(session) {
      chat.innerHTML = '';
      const fragment = document.createDocumentFragment();
      const msgs = (session && session.messages) || [];
      // 只渲染 user/assistant 消息，超长会话分批处理
      const MAX_RENDER = 500;
      const slice = msgs.slice(-MAX_RENDER);
      slice.forEach(m => {
        if (m.role === 'user' || m.role === 'assistant') {
          const div = appendMsgTo(m.role, m.content);
          if (div) fragment.appendChild(div);
        }
      });
      chat.appendChild(fragment);
      enhanceImages(chat);   // V1.2：懒加载
      chat.scrollTop = chat.scrollHeight;
      if (msgs.length > MAX_RENDER) {
        const tip = document.createElement('div');
        tip.className = 'msg system';
        tip.textContent = `（会话较长，仅显示最近 ${MAX_RENDER} 条消息）`;
        chat.insertBefore(tip, chat.firstChild);
      }
      // 恢复进行中的流式输出：重新进入会话时，把部分内容渲染出来并让后续 chunk 继续写入
      if (activeStream && !activeStream.done && activeStream.sessionId === session.id) {
        // 复用已渲染的部分内容气泡（避免重复）；否则新建
        let el = chat.querySelector('.msg.assistant:last-child');
        const lastMsg = (session.messages || []).slice(-1)[0];
        if (!el || !(lastMsg && lastMsg.role === 'assistant' && lastMsg.streamKey === activeStream.key)) {
          el = document.createElement('div');
          el.className = 'msg assistant';
          chat.appendChild(el);
        }
        el.innerHTML = activeStream.avatarHtml + toSafeHtml(activeStream.full || '') + '<div class="typing-indicator"><span></span><span></span><span></span></div>';
        activeStream.assistantEl = el;
        lastAssistantEl = el;
        chat.scrollTop = chat.scrollHeight;
        showStopBtn(true);
      } else if (!activeStream && session.pendingStream && session.pendingStream.taskId && !session.pendingStream.done) {
        // PWA 重启/重新打开：从 NAS 恢复进行中的流式输出（后端一直在写盘）
        recoverStreamFromNas(session);
      }
    }

    // 从 NAS 恢复进行中的流：拉取已生成内容 + 继续轮询增量
    function recoverStreamFromNas(session) {
      const pend = session.pendingStream || {};
      const taskId = pend.taskId;
      if (!taskId) return;
      const streamSessionId = session.id;
      const key = pend.key || 'stream_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8);
      // 先创建部分内容气泡（后续 chunk 写进去）
      const el = document.createElement('div');
      el.className = 'msg assistant';
      chat.appendChild(el);
      el.innerHTML = '<div class="msg-avatar">H</div><span class="msg-sender">轻聊</span><div class="typing-indicator"><span></span><span></span><span></span></div>';
      // V1.2：轮询状态由 createStreamPoller 统一管理
      let lastPartialSave = 0;    // V1.1：部分落盘节流（≥2s 一次）
      window.__pollOnce = null;
      const finishStream = (status, errMsg) => {
        poller.stop();
        window.__pollOnce = null;
        const full = poller.full();
        const hasContent = poller.hasContent();
        const ti = el.querySelector('.typing-indicator');
        if (ti) ti.remove();
        // V1.1：done 时一次性 markdown 最终渲染（流式期间只显示纯文本）
        if (status !== 'error' && hasContent) renderStreamingFinal(el, full);
        if (status === 'error' && !hasContent && el.parentNode) el.parentNode.removeChild(el);
        // 更新 session：标记完成并落盘最终内容
        const sessions = getSessions();
        const s = sessions.find(x => x.id === streamSessionId);
        if (s) {
          const msgs = s.messages || [];
          const last = msgs[msgs.length - 1];
          if (last && last.role === 'assistant' && last.streamKey === key) {
            last.content = full;
            delete last.streamKey;
          } else if (full) {
            msgs.push({ role: 'assistant', content: full, timestamp: Date.now() });
          }
          if (s.pendingStream) s.pendingStream.done = true;
          s.updatedAt = Date.now();
          saveSessions(sessions);
        }
        renderHistory();
        setConnectionStatus(status !== 'error');
      };
      // V1.2：轮询逻辑合并进共享工厂（与 send 路径同一实现）
      const poller = createStreamPoller({
        getTaskId: () => taskId,
        initialFull: pend.content || '',
        onChunk: (full) => {
          const ti = el.querySelector('.typing-indicator');
          if (ti) ti.remove();
          renderStreamingChunk(el, full);   // V1.1：纯文本增量，零 markdown 解析
          chat.scrollTop = chat.scrollHeight;
          // 部分内容落盘（防止再次重启丢失）——V1.1：节流到 ≥2s 一次，避免每 chunk 全量写 localStorage
          const nowMs = Date.now();
          if (nowMs - lastPartialSave > 2000) {
            lastPartialSave = nowMs;
            const sessions = getSessions();
            const s = sessions.find(x => x.id === streamSessionId);
            if (s) {
              const msgs = s.messages || [];
              const last = msgs[msgs.length - 1];
              if (last && last.role === 'assistant' && last.streamKey === key) {
                last.content = full;
              } else if (full) {
                msgs.push({ role: 'assistant', content: full, timestamp: Date.now(), streamKey: key });
              }
              if (s.pendingStream) s.pendingStream.content = full;
              saveSessions(sessions);
            }
          }
        },
        onDone: (status, errMsg) => finishStream(status, errMsg),
      });
      window.__pollOnce = poller.pollOnce;
      poller.start();
      showStopBtn(true);
      // 记录到全局（停止按钮等复用）
      if (typeof currentTaskId !== 'undefined') currentTaskId = taskId;
    }

    // 构造消息 DOM 但不立即插入（供批量渲染用）
    function appendMsgTo(role, text, opts) {
      opts = opts || {};
      const div = document.createElement('div');
      div.className = 'msg ' + role;
      div.dataset.role = role;
      div.dataset.raw = text;
      const now = new Date();
      const time = now.getHours().toString().padStart(2,'0') + ':' + now.getMinutes().toString().padStart(2,'0');
      const sender = role === 'user' ? 'U' : 'H';
      const safeText = toSafeHtml(text);
      let actionsHtml = '';
      if (role === 'user' || role === 'assistant') {
        actionsHtml = '<div class="msg-actions">'
          + '<button class="msg-action-btn" data-action="copy">📋 复制</button>'
          + (role === 'assistant' ? '<button class="msg-action-btn" data-action="regenerate">🔄 重新生成</button>' : '')
          + (opts.isError ? '<button class="msg-action-btn" data-action="retry">↻ 重试</button>' : '')
          + '</div>';
      }
      div.innerHTML = '<div class="msg-header"><div class="msg-avatar">' + sender + '</div><span class="msg-sender">' + (role === 'user' ? 'You' : '轻聊') + '</span><span class="msg-time">' + time + '</span></div>' + safeText + actionsHtml;
      enhanceCodeBlocks(div);
      enhanceImages(div);   // V1.2：懒加载
      return div;
    }

    let attachedFiles = [];

    // 当前模型是否支持图片输入（DeepSeek 不支持；后续切换多模态模型时改为 true）
    const MODEL_SUPPORTS_VISION = true;  // V1.7：后端 auxiliary.vision=stepfun 就绪，图片走 image_url 视觉链路

    // 图片降级：转成文本附件描述，避免后端 400（图片仍保留在本地预览/历史中）
    function imageToTextAttachment(file, base64) {
      const size = formatFileSize(file.size);
      // 附带基础信息；完整 base64 不发给不支持视觉的模型（避免上下文膨胀）
      return `[图片附件: ${file.name} (${size}, ${file.type || 'image/jpeg'})]`;
    }

    function updateAttachedFiles() {
      const container = document.getElementById('attachedFiles');
      if (!container) return;
      container.innerHTML = attachedFiles.map((file, idx) => 
        `<div style="display:inline-flex;align-items:center;gap:4px;padding:4px 8px;background:var(--accent-soft);border-radius:6px;font-size:12px;margin:2px;">
          ${escapeHtml(file.name)}
          <button onclick="removeAttachment(${idx})" style="background:none;border:none;color:var(--danger);cursor:pointer;font-size:14px;line-height:1;">✕</button>
        </div>`
      ).join('');
    }

    function removeAttachment(idx) {
      attachedFiles.splice(idx, 1);
      updateAttachedFiles();
    }

    function formatFileSize(bytes) {
      if (bytes < 1024) return bytes + ' B';
      if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
      return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    }

    function fileToBase64(file) {
      return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = reject;
        reader.readAsDataURL(file);
      });
    }

    // V1.7：图片压缩（iOS 原图 3-12MB 会超 nginx 1MB body 限制）——canvas 缩放 + JPEG 压缩
    async function compressImage(file) {
      const MAX_EDGE = 1280, QUALITY = 0.72;
      try {
        const dataUrl = await fileToBase64(file);
        // 原图已较小（<400KB）直接用，避免不必要的解码
        if (file.size < 400 * 1024) return dataUrl;
        const img = await new Promise((res, rej) => {
          const im = new Image();
          im.onload = () => res(im);
          im.onerror = rej;
          im.src = dataUrl;
        });
        let { width, height } = img;
        if (width > MAX_EDGE || height > MAX_EDGE) {
          const ratio = MAX_EDGE / Math.max(width, height);
          width = Math.round(width * ratio);
          height = Math.round(height * ratio);
        }
        const canvas = document.createElement('canvas');
        canvas.width = width; canvas.height = height;
        canvas.getContext('2d').drawImage(img, 0, 0, width, height);
        let out = canvas.toDataURL('image/jpeg', QUALITY);
        // V1.8.2：循环降质直到 <900KB（极限大图防 nginx 1MB 413）
        let q = 0.5;
        while (out.length > 900 * 1024 && q > 0.15) {
          out = canvas.toDataURL('image/jpeg', q);
          q -= 0.12;
        }
        // V1.8.3：降质到底仍超 900KB → 缩边重绘（每次 0.7x），防极端大图超 nginx 1MB
        let edge = Math.max(width, height);
        while (out.length > 900 * 1024 && edge > 480) {
          edge = Math.round(edge * 0.7);
          const ratio = edge / Math.max(img.width, img.height);
          const w2 = Math.round(img.width * ratio), h2 = Math.round(img.height * ratio);
          canvas.width = w2; canvas.height = h2;
          canvas.getContext('2d').drawImage(img, 0, 0, w2, h2);
          out = canvas.toDataURL('image/jpeg', 0.5);
        }
        return out;
      } catch (e) {
        return await fileToBase64(file);  // HEIC 等解码失败→原图兜底
      }
    }

        // File parsing libraries (loaded via CDN in head)
    // PDF: PDF.js, Word: mammoth.js, Excel: SheetJS
    // 懒加载：按需动态加载附件解析库（主路径不下载，移动端性能优化）
    const _libCache = {};
    function loadLib(src) {
      if (_libCache[src]) return _libCache[src];
      _libCache[src] = new Promise((resolve, reject) => {
        const s = document.createElement('script');
        s.src = src;
        s.onload = () => resolve();
        s.onerror = () => reject(new Error('库加载失败: ' + src));
        document.head.appendChild(s);
      });
      return _libCache[src];
    }
    
    async function extractPdfText(file) {
      try {
        await loadLib('/libs/pdf.min.js?v=20260809');   // V1.8：版本戳绕过 SW/HTTP 缓存（旧 SW 缓存忽略不了带查询的 URL）
        // V1.7.3：pdf.min.js 是 UMD 多格式构建——浏览器分支导出到 globalThis['pdfjs-dist/build/pdf']，
        // 且页面若有 AMD(define.amd) 会走 define 分支不设 window.pdfjsLib——必须多路径获取
        let lib = window.pdfjsLib || null;
        if (!lib && typeof globalThis !== 'undefined') {
          lib = globalThis.pdfjsLib || globalThis['pdfjs-dist/build/pdf'] || null;
        }
        if (!lib) return '[PDF 解析库加载失败（pdfjsLib 未定义）]';
        lib.GlobalWorkerOptions = lib.GlobalWorkerOptions || {};
        lib.GlobalWorkerOptions.workerSrc = '/libs/pdf.worker.min.js?v=20260809';
        const arrayBuffer = await file.arrayBuffer();
        const pdf = await lib.getDocument({ data: arrayBuffer }).promise;
        let text = '';
        for (let i = 1; i <= pdf.numPages; i++) {
          const page = await pdf.getPage(i);
          const content = await page.getTextContent();
          text += content.items.map(item => item.str).join(' ') + '\n';
        }
        return text.trim() || '[PDF contains no extractable text]';
      } catch (e) {
        return `[PDF extraction failed: ${e.message}]`;
      }
    }

    async function extractWordText(file) {
      try {
        await loadLib('/libs/mammoth.browser.min.js');
        const arrayBuffer = await file.arrayBuffer();
        const result = await mammoth.extractRawText({ arrayBuffer });
        return result.value || '[Word document contains no text]';
      } catch (e) {
        return `[Word extraction failed: ${e.message}]`;
      }
    }

    async function extractExcelText(file) {
      try {
        await loadLib('/libs/xlsx.full.min.js');
        const arrayBuffer = await file.arrayBuffer();
        const workbook = XLSX.read(arrayBuffer, { type: 'array' });
        let text = '';
        for (const sheetName of workbook.SheetNames) {
          const sheet = workbook.Sheets[sheetName];
          text += `Sheet: ${sheetName}\n`;
          text += XLSX.utils.sheet_to_csv(sheet);
          text += '\n\n';
        }
        return text.trim() || '[Excel file contains no data]';
      } catch (e) {
        return `[Excel extraction failed: ${e.message}]`;
      }
    }

    // 聊天附件：上传到 NAS（复用文件管理接口，独立密码，不依赖文件管理解锁状态）
    async function chatUploadFile(file) {
      const formData = new FormData();
      formData.append('file', file);
      const res = await fetch('/api/files/upload', {
        method: 'POST',
        headers: { },
        body: formData
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || !data.ok) {
        throw new Error((data && data.error) || ('HTTP ' + res.status));
      }
      // 返回可下载的 URL（经 nginx 反代）
      const saved = data.saved || '';
      const fileName = saved.split('/').pop() || file.name;
      return { url: '/api/files/download?path=' + encodeURIComponent(saved), saved: saved, name: fileName };
    }

    // 打开/预览 NAS 附件（fetch + blob，带密码头；图片/视频新窗口预览，其他触发下载）
    window.openNasFile = async function(url) {
      try {
        const res = await fetch(url, { headers: { } });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const blob = await res.blob();
        const objUrl = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = objUrl;
        a.target = '_blank';
        a.download = url.split('path=')[1] ? decodeURIComponent(url.split('path=')[1]) : 'attachment';
        document.body.appendChild(a);
        a.click();
        setTimeout(() => { URL.revokeObjectURL(objUrl); a.remove(); }, 60000);
      } catch (e) {
        alert('附件加载失败: ' + e.message);
      }
    };

    // V1.7.1：文档文本截断（长 PDF/Word/Excel 防止爆 context）
    function truncateDocText(text, name) {
      const MAX = 12000;
      if (text.length <= MAX) return text;
      return text.slice(0, MAX) + '\n\n[内容过长，已截取前 ' + MAX + ' 字符。如需分析后续内容，请分段发送或提问]';
    }

    async function extractFileContent(file) {
      const type = file.type || '';
      const name = file.name.toLowerCase();
      
      if (type.startsWith('image/')) {
        return { type: 'image', base64: await compressImage(file) };
      }
      
      if (type === 'application/pdf' || name.endsWith('.pdf')) {
        let text = await extractPdfText(file);
        if (text.startsWith('[PDF')) {   // V1.8.2：只认提取失败前缀，避免合法文本以 [ 开头被误判
          // V1.8：本地解析失败（pdfjsLib 异常）→ 上传 PDF 到 NAS，AI 至少拿到文件
          try {
            const up = await chatUploadFile(file);
            text = `[PDF 本地解析失败: ${text.replace(/^\[|\]$/g, '')}]\n文件已上传: ${up.url}\n路径: ${up.saved}`;
          } catch (e2) {
            text = `[PDF 解析与上传均失败: ${e2.message}]`;
          }
        } else {
          text = truncateDocText(text, file.name);
        }
        return { type: 'text', text: `📄 PDF: ${file.name}\n\n${text}` };
      }
      
      if (type === 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' || 
          name.endsWith('.docx')) {
        let text = await extractWordText(file);
        if (text.startsWith('[Word')) {   // V1.8.3：与 PDF 同款兜底——解析失败上传 NAS
          try {
            const up = await chatUploadFile(file);
            text = `[Word 本地解析失败: ${text.replace(/^\[|\]$/g, '')}]\n文件已上传: ${up.url}\n路径: ${up.saved}`;
          } catch (e2) {
            text = `[Word 解析与上传均失败: ${e2.message}]`;
          }
        } else {
          text = truncateDocText(text, file.name);
        }
        return { type: 'text', text: `📝 Word: ${file.name}\n\n${text}` };
      }
      
      if (type === 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' ||
          name.endsWith('.xlsx') || name.endsWith('.xls')) {
        let text = await extractExcelText(file);
        if (text.startsWith('[Excel')) {   // V1.8.3：与 PDF 同款兜底——解析失败上传 NAS
          try {
            const up = await chatUploadFile(file);
            text = `[Excel 本地解析失败: ${text.replace(/^\[|\]$/g, '')}]\n文件已上传: ${up.url}\n路径: ${up.saved}`;
          } catch (e2) {
            text = `[Excel 解析与上传均失败: ${e2.message}]`;
          }
        } else {
          text = truncateDocText(text, file.name);
        }
        return { type: 'text', text: `📊 Excel: ${file.name}\n\n${text}` };
      }
      
      if (type.startsWith('video/')) {
        const base64 = await fileToBase64(file);
        return { type: 'text', text: `🎬 Video: ${file.name} (${formatFileSize(file.size)}, Type: ${type})
[Video files cannot be directly parsed. Base64 preview not included due to size.]` };
      }
      
      // Default: try to read as text
      try {
        const text = await file.text();
        return { type: 'text', text: `📎 ${file.name}\n\n${text}` };
      } catch (e) {
        return { type: 'text', text: `📎 File: ${file.name} (${formatFileSize(file.size)}, Type: ${type || 'unknown'})
[Cannot extract content from this file type]` };
      }
    }

    
    function getCurrentSessionMessages() {
      const sessions = getSessions();
      const id = getCurrentId();
      const session = sessions.find(s => s.id === id);
      if (!session || !session.messages) return [];
      return session.messages
        .filter(m => m.role === 'user' || m.role === 'assistant')
        .map(m => ({ role: m.role, content: m.content }));
    }


    // 导出操作日志（设置页/聊天文件共用）
    function exportOpLogs() {
      const logs = getOpLogs();
      if (!logs.length) return alert('暂无操作日志');
      const blob = new Blob([JSON.stringify(logs, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'oplogs_' + new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19) + '.json';
      a.click();
      URL.revokeObjectURL(url);
    }

    function exportAllSessions() {
      const sessions = getSessions();
      if (!sessions.length) return alert('没有可导出的会话');
      const blob = new Blob([JSON.stringify(sessions, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'sessions_' + new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19) + '.json';
      a.click();
      URL.revokeObjectURL(url);
      alert('已导出 ' + sessions.length + ' 个会话');
    }

    function exportSession(id) {
      const sessions = getSessions();
      const session = sessions.find(s => s.id === id);
      if (!session) return alert('会话不存在');
      const blob = new Blob([JSON.stringify(session, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'session_' + (session.title || 'untitled').replace(/[^a-zA-Z0-9\u4e00-\u9fa5_-]/g, '_') + '_' + session.id.slice(0,8) + '.json';
      a.click();
      URL.revokeObjectURL(url);
    }

    function importSession() {
      const input = document.createElement('input');
      input.type = 'file';
      input.accept = 'application/json';
      input.onchange = async (e) => {
        const file = e.target.files[0];
        if (!file) return;
        try {
          const text = await file.text();
          const session = JSON.parse(text);
          if (!session.id || !session.messages) throw new Error('无效的会话文件');
          const sessions = getSessions();
          session.id = Date.now().toString();
          session.createdAt = Date.now();
          session.updatedAt = Date.now();
          sessions.unshift(session);
          saveSessions(sessions);
          setCurrentId(session.id);
          renderHistory();
          chat.innerHTML = '';
          renderSessionMessages(session);
          showPage('chat');
        } catch (e) {
          alert('导入失败：' + e.message);
        }
      };
      input.click();
    }

    function syncSessions() {
      alert('同步功能需要后端服务支持，当前已禁用。\n可使用"导入会话"恢复之前导出的文件。');
    }

    function mergeSessions(local, nas) {
      const map = new Map();
      for (const s of local) map.set(s.id, s);
      for (const s of nas) {
        const existing = map.get(s.id);
        if (!existing) {
          map.set(s.id, { ...s, id: Date.now() + '_' + Math.random().toString(36).slice(2, 8) });
        } else if (s.updatedAt > existing.updatedAt) {
          map.set(s.id, s);
        }
      }
      return Array.from(map.values()).sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
    }

async function send(skipUserAppend, resumeOpts) {
      const text = input.value.trim();
      if (!text && attachedFiles.length === 0 && !resumeOpts) return;
      if (busy) return;
      busy = true;
      showStopBtn(true);
      // 流式输出全局状态：记录会话/唯一key/已生成内容（供退出后恢复）
      const streamSessionId = resumeOpts ? resumeOpts.sessionId : getCurrentId();
      const streamKey = Date.now() + '_' + Math.random().toString(36).slice(2, 8);
      // 续写模式：partial 作为已生成内容基线（气泡保留旧内容，新内容接在后面）
      const resumePartial = (resumeOpts && resumeOpts.partial) ? resumeOpts.partial : '';
      activeStream = { sessionId: streamSessionId, key: streamKey, full: resumePartial, done: false, assistantEl: null, avatarHtml: '' };
      // Keep send button enabled for queuing
      input.value = '';
      autoResizeInput();
      const welcome = chat.querySelector('.welcome');
      if (welcome) welcome.remove();
      
      // Build multi-modal message content
      const messageContent = [];
      if (text) {
        messageContent.push({ type: 'text', text: text });
      }
      
      // Process file attachments
      const processedFiles = [];
      for (const file of attachedFiles) {
        try {
          const isVideo = file.type.startsWith('video/');
          const isAudio = file.type.startsWith('audio/');
          const isBig = file.size > 5 * 1024 * 1024; // >5MB 一律上传
          if (isVideo || isAudio || isBig) {
            // 视频/音频/大文件：真上传到 NAS，消息带下载链接
            const up = await chatUploadFile(file);
            messageContent.push({
              type: 'text',
              text: `[附件上传] ${isVideo ? '🎬' : isAudio ? '🎵' : '📎'} ${file.name} (${formatFileSize(file.size)}) 已上传至NAS\n下载链接: ${up.url}\n文件路径: ${up.saved}`
            });
            processedFiles.push({ name: file.name, type: isVideo ? 'video' : isAudio ? 'audio' : 'file', size: file.size, url: up.url });
          } else {
            const extracted = await extractFileContent(file);
            if (extracted.type === 'image') {
              if (MODEL_SUPPORTS_VISION) {
                // 多模态模型：发送标准 image_url 内容块
                messageContent.push({
                  type: 'image_url',
                  image_url: { url: extracted.base64 }
                });
              } else {
                // 纯文本模型：降级为附件描述（避免后端 400 / 重试）
                messageContent.push({
                  type: 'text',
                  text: imageToTextAttachment(file, extracted.base64)
                });
              }
              processedFiles.push({ name: file.name, type: 'image' });
            } else {
              messageContent.push({
                type: 'text',
                text: extracted.text
              });
              processedFiles.push({ name: file.name, type: 'file', size: file.size });
            }
          }
        } catch (e) {
          console.error('Failed to process file:', e);
          const fileInfo = `📎 File: ${file.name} (${formatFileSize(file.size)}, Type: ${file.type || 'unknown'})\n[Extraction failed]`;
          messageContent.push({ type: 'text', text: fileInfo });
          processedFiles.push({ name: file.name, type: 'file', size: file.size });
        }
      }
      
      // Show user message in chat (skip if regenerating)
      if (!skipUserAppend) {
        let userContent = text;
        if (processedFiles.length > 0) {
          const fileList = processedFiles.map(f => {
            if (f.type === 'image') {
              return `🖼️ ${escapeHtml(f.name)}${MODEL_SUPPORTS_VISION ? '' : ' <span style="color:var(--text-muted);font-size:11px;">(已作为附件发送)</span>'}`;
            }
            if (f.url) {
              // 已上传 NAS：显示可点击附件卡片（fetch+blob 带密码头，避免 401）
              const icon = f.type === 'video' ? '🎬' : f.type === 'audio' ? '🎵' : '📎';
              return `<a href="javascript:void(0)" onclick="openNasFile('${f.url.replace(/'/g, "\\'")}')" style="display:inline-flex;align-items:center;gap:6px;padding:6px 10px;background:var(--bg-input);border-radius:10px;text-decoration:none;color:var(--accent);font-size:13px;">${icon} ${escapeHtml(f.name)} <span style="color:var(--text-muted);font-size:11px;">(${formatFileSize(f.size)})</span> ↗</a>`;
            }
            return `📎 ${escapeHtml(f.name)} (${formatFileSize(f.size)})`;
          }).join('<br>');
          userContent = text ? `${text}<br><br>${fileList}` : fileList;
        }
        appendMsg('user', userContent);
      }
      
      // Clear attachments after processing
      attachedFiles = [];
      updateAttachedFiles();
      
      // Create assistant message bubble (regenerate 时复用旧气泡，需确认仍在 DOM)
      let assistant = null;
      let avatarHtml = '';
      if (resumePartial && lastAssistantEl && document.contains(lastAssistantEl)) {
        // 续写模式：直接复用已有气泡（保留已生成内容），仅移除 typing 残留
        assistant = lastAssistantEl;
        assistant.querySelectorAll('.typing-indicator').forEach(t => t.remove());
        const hdr = assistant.querySelector('.msg-header');
        avatarHtml = hdr ? hdr.outerHTML : '<div class="msg-header"><div class="msg-avatar">H</div><span class="msg-sender">轻聊</span><span class="msg-time">' + new Date().toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'}) + '</span></div>';
      } else if (skipUserAppend && lastAssistantEl && document.contains(lastAssistantEl)) {
        assistant = lastAssistantEl;
        assistant.innerHTML = '';
        const hdr = document.createElement('div');
        hdr.className = 'msg-header';
        hdr.innerHTML = '<div class="msg-avatar">H</div><span class="msg-sender">轻聊</span><span class="msg-time">' + new Date().toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'}) + '</span>';
        assistant.appendChild(hdr);
        avatarHtml = hdr.outerHTML;
      } else {
        assistant = document.createElement('div');
        assistant.className = 'msg assistant';
        avatarHtml = '<div class="msg-header"><div class="msg-avatar">H</div><span class="msg-sender">轻聊</span><span class="msg-time">' + new Date().toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'}) + '</span></div>';
        assistant.innerHTML = avatarHtml;
        chat.appendChild(assistant);
        lastAssistantEl = assistant;
      }
      if (activeStream) activeStream.avatarHtml = avatarHtml;
      chat.scrollTop = chat.scrollHeight;
      
      // Typing indicator
      const typingEl = document.createElement('div');
      typingEl.className = 'typing-indicator';
      typingEl.innerHTML = '<span></span><span></span><span></span>';
      assistant.appendChild(typingEl);
      chat.scrollTop = chat.scrollHeight;
      
      const controller = new AbortController();
      currentController = controller;
      abortedByUser = false; // 每次发送重置全局停止标记
      // 120s 无任何数据才超时；收到数据后重置计时器
      let timeoutTimer = null;
      const resetTimeout = () => {
        if (timeoutTimer) clearTimeout(timeoutTimer);
        timeoutTimer = setTimeout(() => {
          if (!abortedByUser) {
            controller.abort();
            setConnectionStatus(false);
            showToast('请求超时（120s 无响应），请重试');
          }
        }, 120000);
      };
      resetTimeout();
      
      try {
        const modelName = CURRENT_MODEL;
        // 续写模式：历史消息 + 已生成 partial 作为 assistant 上下文 + 续写指令（模型接着输出，不从头思考）
        let reqMessages;
        if (resumePartial) {
          const hist = getCurrentSessionMessages();
          reqMessages = hist.concat([
            { role: 'assistant', content: resumePartial },
            { role: 'user', content: '[系统] 你上一条回复因网络中断被截断。请接着上面已生成的内容继续输出，不要重复已输出的部分，直接从断点继续。' }
          ]);
        } else {
          reqMessages = getCurrentSessionMessages().concat([{ role: 'user', content: messageContent }]);
        }
        // 新架构：请求交给 NAS 后端代理持流（后端连 Hermes 流式读取，写入 NAS 文件），
        // 前端只轮询增量——iOS 杀前端连接不影响后端输出，后台期间内容不丢。
        const startRes = await fetch('/api/stream/start', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ sessionId: streamSessionId, model: modelName, provider: localStorage.getItem('hermes_current_provider') || '', messages: reqMessages, pushEnabled: localStorage.getItem('qingliao_push_enabled') === '1' })
        });
        if (!startRes.ok) {
          setConnectionStatus(false);
          throw new Error('HTTP ' + startRes.status);
        }
        const startData = await startRes.json();
        if (!startData.taskId) throw new Error('start failed');
        currentTaskId = startData.taskId;
        // 持久化进行中任务：PWA 重启后凭此从 NAS 恢复流
        try {
          const sessions = getSessions();
          const s = sessions.find(x => x.id === streamSessionId);
          if (s) {
            s.pendingStream = { taskId: currentTaskId, key: streamKey, content: resumePartial || '', done: false, ts: Date.now() };
            saveSessions(sessions);
          }
        } catch (e) { console.warn('save pendingStream failed', e); }
        resetTimeout(); // 已发起，重置超时
        // 轮询增量：后端把内容写入 NAS，前端按 offset 拉新内容。
        // iOS 冻结 JS 期间 interval 暂停，回前台由 visibilitychange 立即拉一次——积压内容一次拉回。
        // V1.2：轮询状态由 createStreamPoller 统一管理
        const finishStream = (status, errMsg) => {
          clearTimeout(timeoutTimer);
          clearTimeout(streamSaveTimer);
          poller.stop();
          window.__pollOnce = null;
          const full = poller.full();
          const hasContent = poller.hasContent();
          const finEl = (activeStream && activeStream.assistantEl) ? activeStream.assistantEl : assistant;
          const finTi = finEl.querySelector('.typing-indicator');
          if (finTi) finTi.remove();
          typingEl.remove();
          // V1.1：done/中断时一次性 markdown 最终渲染（流式期间只显示纯文本）
          if (hasContent) renderStreamingFinal(finEl, full);
          if ((status === 'cancelled' || status === 'error') && !hasContent) {
            // 用户停止/出错且无任何内容：移除空气泡
            if (assistant && assistant.parentNode) assistant.parentNode.removeChild(assistant);
          }
          if (status === 'error') {
            setConnectionStatus(false);
            if (!hasContent) {
              appendMsg('error', errMsg || '请求失败，请重试');
            } else {
              appendMsg('error', '输出中断（已保留已生成内容）');
            }
          } else {
            setConnectionStatus(true);
          }
          // Save assistant reply after streaming completes（带 streamKey 替换部分内容）
          saveStreamingFinal(streamSessionId, full, streamKey);
          // 清除持久化的进行中任务标记（流已完成）
          try {
            const sessions = getSessions();
            const s = sessions.find(x => x.id === streamSessionId);
            if (s && s.pendingStream) { delete s.pendingStream; saveSessions(sessions); }
          } catch (e) {}
          if (activeStream) { activeStream.done = true; activeStream = null; }
          renderHistory();
          updateModelName(modelName);
          currentTaskId = null;
        };
        // V1.2：轮询逻辑合并进共享工厂（与 recover 路径同一实现）
        const poller = createStreamPoller({
          getTaskId: () => currentTaskId,
          initialFull: resumePartial || '',
          onChunk: (full) => {
            if (activeStream) activeStream.full = full;
            resetTimeout(); // 收到数据，重置超时
            // 优先写入恢复后的元素（退出会话再进入后继续渲染）
            const targetEl = (activeStream && activeStream.assistantEl) ? activeStream.assistantEl : assistant;
            const ti = targetEl.querySelector('.typing-indicator');
            if (ti) ti.remove();
            renderStreamingChunk(targetEl, full);   // V1.1：纯文本增量，零 markdown 解析
            if (chat.contains(targetEl)) chat.scrollTop = chat.scrollHeight;
          },
          onDone: (status, errMsg) => finishStream(status, errMsg),
        });
        window.__pollOnce = poller.pollOnce;
        poller.start(); // 立即拉一次（首个增量 + 快速反馈）
      } catch (e) {
        // start 请求失败或异常：清理并提示
        clearTimeout(timeoutTimer);
        clearTimeout(streamSaveTimer);
        poller.stop();
        window.__pollOnce = null;
        typingEl.remove();
        currentTaskId = null;
        console.error('Chat error:', e);
        const errMsg = appendMsg('error', '发送失败，请重试', { isError: true });
        errMsg.dataset.retryText = text;
      } finally {
        busy = false;
        showStopBtn(false);
        currentController = null;
        activeStream = null;
        sendBtn.disabled = false;
        input.focus();
        autoResizeInput();
      }
    }

    const nasRefreshBtn = document.getElementById('nasRefreshBtn');
    if (nasRefreshBtn) {
      nasRefreshBtn.onclick = () => { loadNasStatus(); };
      startNasAutoRefresh();
    }
    const attachBtn = document.getElementById('attachBtn');
    const fileInput = document.getElementById('fileInput');
    const stopBtn = document.getElementById('stopBtn');
    
    if (attachBtn && fileInput) {
      attachBtn.onclick = () => fileInput.click();
      fileInput.onchange = (e) => {
        const files = Array.from(e.target.files || []);
        attachedFiles.push(...files);
        updateAttachedFiles();
        fileInput.value = '';
      };
    }

    sendBtn.onclick = () => send();
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } });

    // P0-2: 停止生成
    let currentController = null;
    let currentTaskId = null; // 新架构：NAS 后端流式任务 ID（前端只轮询）
    let lastAssistantEl = null;
    let abortedByUser = false;
    function showStopBtn(show) {
      if (stopBtn) stopBtn.style.display = show ? 'flex' : 'none';
      if (sendBtn) sendBtn.style.display = show ? 'none' : 'flex';
    }
    if (stopBtn) {
      stopBtn.onclick = () => {
        abortedByUser = true;
        if (currentController) { try { currentController.abort(); } catch (e) {} }
        // 新架构：通知 NAS 后端停止流式任务（前端连接死了也没关系，后端在收）
        if (currentTaskId) {
          fetch('/api/stream/' + currentTaskId + '/stop', {
            method: 'POST',
            headers: { }
          }).catch(() => {});
        }
      };
    }

    // P2-8: 输入框多行自适应
    function autoResizeInput() {
      if (!input) return;
      input.style.height = 'auto';
      input.style.height = Math.min(input.scrollHeight, 120) + 'px';
    }
    input.addEventListener('input', autoResizeInput);

    // P2-6: 图片点击预览
    const imagePreviewOverlay = document.getElementById('imagePreviewOverlay');
    const imagePreviewImg = document.getElementById('imagePreviewImg');
    chat.addEventListener('click', (e) => {
      const img = e.target.closest('.msg img');
      if (img && img.src) {
        imagePreviewImg.src = img.src;
        imagePreviewOverlay.classList.add('show');
      }
    });
    if (imagePreviewOverlay) {
      imagePreviewOverlay.addEventListener('click', () => imagePreviewOverlay.classList.remove('show'));
    }

    // P2-7: 拖拽上传
    let dragCounter = 0;
    document.addEventListener('dragenter', (e) => {
      e.preventDefault();
      dragCounter++;
    });
    document.addEventListener('dragover', (e) => { e.preventDefault(); });
    document.addEventListener('dragleave', (e) => {
      e.preventDefault();
      dragCounter--;
    });
    document.addEventListener('drop', (e) => {
      e.preventDefault();
      dragCounter = 0;
      const files = Array.from(e.dataTransfer?.files || []);
      if (files.length) {
        attachedFiles.push(...files);
        updateAttachedFiles();
      }
    });

    // P3-10: 断网状态检测
    window.addEventListener('online', () => {
      setConnectionStatus(true);
      showToast('网络已恢复');
    });
    window.addEventListener('offline', () => {
      setConnectionStatus(false);
      showToast('网络已断开');
    });

    // P3-9: Toast 提示
    let toastTimer = null;
    function showToast(msg, onClick) {
      let toast = document.getElementById('toast');
      if (!toast) {
        toast = document.createElement('div');
        toast.id = 'toast';
        toast.style.cssText = 'position:fixed;top:64px;left:50%;transform:translateX(-50%);background:var(--text);color:var(--bg-card);padding:8px 16px;border-radius:20px;font-size:13px;z-index:9998;opacity:0;transition:opacity 0.3s;pointer-events:none;max-width:80%;text-align:center;box-shadow:0 2px 12px rgba(0,0,0,0.2);';
        document.body.appendChild(toast);
      }
      toast.textContent = msg;
      toast.style.opacity = '1';
      // V1.2：带回调的 toast 可点击（新版提示用），显示更久
      toast.style.pointerEvents = onClick ? 'auto' : 'none';
      toast.style.cursor = onClick ? 'pointer' : 'default';
      toast.onclick = onClick || null;
      clearTimeout(toastTimer);
      toastTimer = setTimeout(() => { toast.style.opacity = '0'; }, onClick ? 6000 : 2500);
    }

    // 消息操作：复制 / 重新生成 / 重试
    chat.addEventListener('click', (e) => {
      const btn = e.target.closest('.msg-action-btn');
      if (!btn) return;
      const msgEl = btn.closest('.msg');
      if (!msgEl) return;
      const action = btn.dataset.action;
      if (action === 'copy') {
        const raw = msgEl.dataset.raw || msgEl.textContent;
        navigator.clipboard.writeText(raw).then(() => {
          btn.textContent = '✅ 已复制';
          btn.classList.add('copied');
          setTimeout(() => { btn.textContent = '📋 复制'; btn.classList.remove('copied'); }, 1500);
        }).catch(() => { btn.textContent = '❌ 失败'; });
      } else if (action === 'regenerate') {
        // 删除本条 assistant 消息及其对应的最后一条 user 消息，用该 user 消息重新生成
        const sessions = getSessions();
        const id = getCurrentId();
        const session = sessions.find(s => s.id === id);
        if (!session || !session.messages.length) return;
        let regenerateText = '';
        const lastMsg = session.messages[session.messages.length - 1];
        if (lastMsg && lastMsg.role === 'assistant') {
          session.messages.pop(); // 删除 assistant 回复
          const prevMsg = session.messages[session.messages.length - 1];
          if (prevMsg && prevMsg.role === 'user') {
            session.messages.pop(); // 删除对应的 user 消息
            regenerateText = prevMsg.content;
          }
        }
        if (!regenerateText) { showToast('没有可重新生成的消息'); return; }
        saveSessions(sessions);
        // 重新渲染聊天
        chat.innerHTML = '';
        renderSessionMessages(session);
        renderHistory();
        // 用刚删除的 user 消息重新生成（完整流程，重新保存 user 并显示）
        if (regenerateText) {
          input.value = regenerateText;
          input.dispatchEvent(new Event('input'));
          send();
        }
      } else if (action === 'retry') {
        // 重试：移除错误消息，重发上次内容（跳过重复保存 user，复用失败气泡）
        const retryText = msgEl.dataset.retryText;
        if (retryText) {
          if (msgEl.parentNode) msgEl.parentNode.removeChild(msgEl);
          input.value = retryText;
          input.dispatchEvent(new Event('input'));
          send(true);
        }
      }
    });

    // P3-11: 移动端键盘适配（V1.0 正式版架构：微信式）
    // 设计：
    //   1) 输入框 position:fixed 贴底（z-index 1050，第二层；抽屉 1100/蒙板 1090 最上，打开时盖住输入框=标准抽屉行为）
    //   2) 键盘弹出：bottom = 实时 innerHeight - 实时 visualViewport.height（键盘遮挡高度），输入框跟随键盘浮起
    //      ——绝不能用历史最大值当基准：iOS 偶发压缩布局视口(innerHeight 793→410)，历史值算出 383 而实际应为 0，输入框被顶出屏幕（实测坑）
    //   3) 键盘"真在"判定 = 视口明显小于本次聚焦会话峰值(≥60px)；点"完成"收键盘后 vv 回到峰值即判定收起 → 贴底归位（防悬空留白）
    //   4) 消息区底部留白随键盘同步（76+抬升高度），最后一条消息始终可滚到输入框上方；聚焦时若在底部自动滚底
    //   5) JS 只保留：键盘同步 + 抽屉/蒙板看门狗 + 事件型诊断上报（page-load/watchdog-fixed，无周期上报）
    if (window.visualViewport) {
      // V1.6.1：移除诊断上报（kb_diag 文件堆积），保留键盘适配
      // 微信式键盘适配：输入框贴底固定（position:fixed;bottom:0），键盘弹出时把 bottom 设为键盘遮挡高度，
      // 输入框跟随键盘浮起；收起时 bottom 归零贴底。无高度恢复、无竞态。
      const inputArea = document.querySelector('.chat-input-area');
      let vvSessionMax = 0;   // 本次聚焦会话内见过的视口高度峰值（键盘关闭时 vv 会回到接近峰值）
      // 键盘遮挡 = 实时布局视口高(innerHeight) - 实时可视视口高(vv)
      // 注意：iOS 偶发把布局视口一起压缩（innerHeight 793→410，app 整体缩到键盘上方），
      // 此时差值为 0（浏览器已处理，无需抬升）；不压缩时才等于键盘高度。
      // 绝不能用"历史最大值"当基准——会算出 383px 而实际应为 0，输入框被顶出屏幕顶部（实测坑）。
      const kbOffset = () => Math.max(0, window.innerHeight - window.visualViewport.height);
      const kbSync = () => {
        if (!inputArea) return;
        const h = kbOffset();
        const vvH = window.visualViewport.height;
        if (vvH > vvSessionMax) vvSessionMax = vvH;
        const ae = document.activeElement;
        const typing = !!(ae && (ae === chatInputEl || /input|textarea/i.test(ae.tagName || '') || ae.isContentEditable));
        // 键盘"真在"判定：视口明显小于会话峰值（≥60px 差）= 键盘还开着
        // 关键修复：点"完成"收键盘后 vv 回到峰值（793=793），此条件即不成立 → 输入框归位贴底。
        // 旧逻辑要求 vv 超过峰值+100 才判定收起，永远不满足 → 输入框悬空留白（实测坑）。
        const kbOpen = (h > 60 && typing && vvH < vvSessionMax - 60);
        // 上限保护：抬升最多到屏幕中部，防瞬时异常视口值把输入框顶出屏幕
        const lift = Math.min(h, window.innerHeight - 140);
        const want = kbOpen ? lift + 'px' : '';
        if (inputArea.style.bottom !== want) inputArea.style.bottom = want;
        // 消息区底部留白同步：输入框抬起时让位（最后一条消息可滚到输入框上方），收起时还原 CSS 默认
        const chatEl = document.getElementById('chat');
        if (chatEl) {
          const wantPad = want ? (76 + lift) + 'px' : '';
          if (chatEl.style.paddingBottom !== wantPad) {
            chatEl.style.paddingBottom = wantPad;
            // 垫高生效且用户原本在消息底部 → 固定滚到底部（最后一条紧贴输入框上方）
            // 关键：留白增长会让内容总高变大、scrollTop 停在原位 → 底部消息被输入框盖住
            if (wantPad && nearBottom) {
              requestAnimationFrame(() => { chatEl.scrollTop = chatEl.scrollHeight; });
            }
          }
        }
      };
      window.visualViewport.addEventListener('resize', kbSync);
      window.addEventListener('resize', kbSync);
      // V1.1：600ms 兜底轮询只在输入框聚焦期间运行（resize 事件为主路径，待机零空转省电）
      let kbPollTimer = null;
      const kbPollStart = () => { if (!kbPollTimer) kbPollTimer = setInterval(kbSync, 600); };
      const kbPollStop = () => { if (kbPollTimer) { clearInterval(kbPollTimer); kbPollTimer = null; } };
      document.addEventListener('visibilitychange', () => {
        if (!document.hidden) setTimeout(kbSync, 100);
      });
      // V1.6.1：移除页面加载诊断上报
      // 消息滚动位置跟踪：是否停在底部附近（键盘垫高时据此决定是否固定到底）
      let nearBottom = true;
      const chatElRef = document.getElementById('chat');
      if (chatElRef) {
        chatElRef.addEventListener('scroll', () => {
          nearBottom = (chatElRef.scrollHeight - chatElRef.scrollTop - chatElRef.clientHeight) < 80;
        }, { passive: true });
      }
      // 输入时收起侧栏（微信式）
      const chatInputEl = document.getElementById('input');
      if (chatInputEl) {
        chatInputEl.addEventListener('focus', () => {
          // 峰值只在页面加载后首次初始化；键盘已开着时聚焦不重置（否则峰值=小值→判定"无键盘"→不抬升）
          if (vvSessionMax === 0) vvSessionMax = window.visualViewport.height;
          kbPollStart();
          closeSidebar();
          // iOS 原生补偿辅助：确保聚焦的输入框滚入可见区
          if (chatInputEl.scrollIntoView) chatInputEl.scrollIntoView({ block: 'nearest' });
          setTimeout(kbSync, 100);
          setTimeout(kbSync, 400);
        });
        chatInputEl.addEventListener('blur', () => {
          kbPollStop();
          setTimeout(kbSync, 300);
        });
      }
      // 看门狗：每秒检查抽屉/蒙板/预览残留，自动清除（与键盘完全解耦）
      // V1.5：删除 sidebarStuck 自动关闭——侧栏正常打开（蒙板+侧栏位置正确）= 用户主动使用，
      // 持续 ≥3 秒被强关是误报（V1.1.1 只修了 600ms 动画窗口，3 秒后照样误杀）。
      // 真正的残留（蒙板有但侧栏没开/位置在屏外）由下方 sidebarMask 分支处理。
      setInterval(() => {
        const sb = document.getElementById('sidebar');
        const mk = document.getElementById('sidebarMask');
        const maskShow = !!(mk && mk.classList.contains('show'));
        const sbOpen = !!(sb && sb.classList.contains('open'));
        const activePageEl = document.querySelector('.page.active');
        const onChatPage = !!(activePageEl && activePageEl.id === 'page-chat');
        // V1.1 省电：非聊天页且无抽屉/蒙板 → 无事可做，快速返回（预览遮罩是模态点击关闭，无需看门狗）
        if (!onChatPage && !maskShow && !sbOpen) return;
        // V1.1.1：侧栏滑入动画窗口（transition 0.3s + 余量）内不判残留——
        // 否则 tick 落在动画中时 left < -50 会把刚打开的侧栏当"蒙板残留"强制关闭并弹 toast
        const animating = (Date.now() - sbOpenedAt) < 600;
        const fixes = [];
        if (maskShow) {
          const r = sb ? sb.getBoundingClientRect() : null;
          if (!animating && (!sb || !sb.classList.contains('open') || (r && r.left < -50))) {
            closeSidebar(); fixes.push('sidebarMask');
          }
        }
        if (sbOpen && document.activeElement === chatInputEl) {
          closeSidebar(); fixes.push('sidebar');
        }
        ['imagePreviewOverlay','filePreviewOverlay','jobModalOverlay'].forEach(id => {
          const el = document.getElementById(id);
          if (el && el.classList.contains('show')) { el.classList.remove('show'); fixes.push(id); }
        });
        if (fixes.length) {
          if (typeof showToast === 'function') showToast('已自动清除界面残留: ' + fixes.join(', '));
        }
      }, 1000);
    }

    // Sessions
    const storageKey = 'hermes_chat_sessions';
    const currentIdKey = 'hermes_current_session_id';

    function getSessions() {
      try { return JSON.parse(localStorage.getItem(storageKey) || '[]'); }
      catch (e) { return []; }
    }
    function saveSessions(sessions) {
      try {
        let data = JSON.stringify(sessions);
        // V1.2：存储容量保护——超限时归档最旧的非当前会话（防长期使用后 localStorage 写满 5MB 上限）
        const MAX = 3.5 * 1024 * 1024;
        let guard = 0;
        while (data.length > MAX && sessions.length > 1 && guard < 50) {
          const curId = getCurrentId();
          const idx = sessions.findIndex(s => s.id !== curId);
          if (idx < 0) break;
          sessions.splice(idx, 1);
          data = JSON.stringify(sessions);
          guard++;
        }
        localStorage.setItem(storageKey, data);
      } catch (e) { console.warn('本地存储失败', e); }
      schedulePush();
    }
    function getCurrentId() {
      return localStorage.getItem(currentIdKey);
    }
    function setCurrentId(id) {
      localStorage.setItem(currentIdKey, id);
    }

    // === NAS 会话同步（V0.24 方案A：跨设备共享会话）===
        const pushedKey = 'hermes_sessions_pushed';

    function schedulePush() {
      clearTimeout(window.__syncTimer);
      window.__syncTimer = setTimeout(pushToNas, 800);
    }

    // 全量推送：对比上次推送快照，diff 出被删除的会话 id 一并上报
    async function pushToNas() {
      try {
        const sessions = getSessions();
        let last = [];
        try { last = JSON.parse(localStorage.getItem(pushedKey) || '[]'); } catch (e) { last = []; }
        const deleted = last.filter(s => !sessions.some(x => x.id === s.id)).map(s => s.id);
        const res = await fetch('/api/sessions/merge', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ sessions, deleted })
        });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        localStorage.setItem(pushedKey, JSON.stringify(sessions));
      } catch (e) {
        console.warn('[NAS同步] 推送失败（自动降级为本地存储）:', e.message);
      }
    }

    // 本地 + NAS 合并：同 id 取 updatedAt 较新者
    function mergeSessionLists(local, nas) {
      const map = new Map();
      local.forEach(s => { if (s && s.id) map.set(s.id, s); });
      let changed = false;
      (nas || []).forEach(s => {
        if (!s || !s.id) return;
        const cur = map.get(s.id);
        if (!cur) { map.set(s.id, s); changed = true; }
        else if ((s.updatedAt || 0) > (cur.updatedAt || 0)) { map.set(s.id, s); changed = true; }
      });
      const merged = [...map.values()].sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
      return { merged, changed };
    }

    // 启动时从 NAS 拉取合并（后台执行，失败静默降级本地）
    async function syncFromNas() {
      try {
        const res = await fetch('/api/sessions/list', { headers: { } });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const data = await res.json();
        if (!data || !Array.isArray(data.sessions)) return;
        const local = getSessions();
        const { merged, changed } = mergeSessionLists(local, data.sessions);
        if (!changed) return;
        const curId = getCurrentId();
        const curBefore = local.find(s => s.id === curId);
        const curAfter = merged.find(s => s.id === curId);
        saveSessions(merged);
        renderHistory();
        // 当前会话在别的设备有新消息时刷新聊天区（流式输出中跳过，避免毁掉流式气泡）
        if (!busy && !(activeStream && !activeStream.done) && curAfter && curBefore && (curAfter.messages || []).length !== (curBefore.messages || []).length) {
          chat.innerHTML = '';
          renderSessionMessages(curAfter);
        }
      } catch (e) {
        console.warn('[NAS同步] 拉取失败（继续使用本地会话）:', e.message);
      }
    }

    function saveCurrentMessage(role, text) {
      const sessions = getSessions();
      let id = getCurrentId();
      let session = sessions.find(s => s.id === id);
      if (!session) {
        id = Date.now().toString();
        session = { id, title: '新对话', messages: [], createdAt: Date.now(), updatedAt: Date.now(), pinned: false };
        sessions.unshift(session);
        setCurrentId(id);
      }
      session.messages.push({ role, content: text, timestamp: Date.now() });
      // P1-5: 自动标题（首条用户消息截取）
      if (session.messages.length === 1 && role === 'user') {
        session.title = text.slice(0, 30) + (text.length > 30 ? '...' : '');
      }
      session.updatedAt = Date.now();
      saveSessions(sessions);
    }

    // 流式输出部分内容落盘：同一次流（streamKey 相同）更新最后一条 assistant 消息，不重复追加
    function saveStreamingPartial(sessionId, text, key) {
      const sessions = getSessions();
      const session = sessions.find(s => s.id === sessionId);
      if (!session) return;
      const msgs = session.messages || [];
      const last = msgs[msgs.length - 1];
      if (last && last.role === 'assistant' && last.streamKey === key) {
        last.content = text;
      } else {
        msgs.push({ role: 'assistant', content: text, timestamp: Date.now(), streamKey: key });
      }
      session.updatedAt = Date.now();
      saveSessions(sessions);
    }

    // 流式输出最终落盘：替换部分内容并去掉 streamKey 标记（标记为完整消息）
    function saveStreamingFinal(sessionId, text, key) {
      const sessions = getSessions();
      const session = sessions.find(s => s.id === sessionId);
      if (!session) return;
      const msgs = session.messages || [];
      const last = msgs[msgs.length - 1];
      if (last && last.role === 'assistant' && last.streamKey === key) {
        last.content = text;
        delete last.streamKey;
      } else {
        msgs.push({ role: 'assistant', content: text, timestamp: Date.now() });
      }
      session.updatedAt = Date.now();
      saveSessions(sessions);
    }

    // P1-3: 会话搜索过滤
    let sessionSearchQuery = '';
    function getFilteredSessions() {
      const sessions = getSessions();
      if (!sessionSearchQuery) return sessions;
      const q = sessionSearchQuery.toLowerCase();
      return sessions.filter(s => {
        if ((s.title || '').toLowerCase().includes(q)) return true;
        return (s.messages || []).some(m => (m.content || '').toLowerCase().includes(q));
      });
    }

    // P1-4: 会话置顶
    function togglePinSession(id) {
      const sessions = getSessions();
      const session = sessions.find(s => s.id === id);
      if (!session) return;
      session.pinned = !session.pinned;
      session.updatedAt = Date.now();
      saveSessions(sessions);
      renderHistory();
    }

    // P1-4: 会话重命名
    function renameSession(id) {
      const sessions = getSessions();
      const session = sessions.find(s => s.id === id);
      if (!session) return;
      const newTitle = prompt('输入新的会话名称：', session.title || '');
      if (newTitle === null) return;
      session.title = newTitle.trim() || '新对话';
      session.updatedAt = Date.now();
      saveSessions(sessions);
      renderHistory();
    }

    function renderHistory() {
      const list = document.getElementById('sessionList');
      if (!list) return;
      let sessions = getFilteredSessions();
      if (!sessions.length) { list.innerHTML = '<div class="empty-state">暂无历史会话</div>'; return; }
      // 置顶的排前面
      sessions = [...sessions].sort((a, b) => (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0) || (b.updatedAt || 0) - (a.updatedAt || 0));
      const currentId = getCurrentId();
      list.innerHTML = sessions.map(s => {
        const date = new Date(s.updatedAt).toLocaleDateString('zh-CN');
        const time = new Date(s.updatedAt).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
        const count = s.messages ? s.messages.length : 0;
        const title = escapeHtml((s.title || '新对话'));
        const isActive = s.id === currentId;
        const isPinned = s.pinned;
        return '<div class="session-item' + (isActive ? ' active' : '') + (isPinned ? ' pinned-session' : '') + '" data-id="' + s.id + '"><div class="session-info" data-id="' + s.id + '"><div class="session-title">' + (isPinned ? '📌 ' : '') + title + '</div><div class="session-meta">' + date + ' ' + time + ' · ' + count + '条消息</div></div><button class="session-pin' + (isPinned ? ' pinned' : '') + '" data-id="' + s.id + '" title="' + (isPinned ? '取消置顶' : '置顶') + '">' + (isPinned ? '★' : '☆') + '</button><button class="session-rename" data-id="' + s.id + '" title="重命名">✏️</button><button class="session-export" data-id="' + s.id + '" title="导出会话">⤓</button><button class="session-delete" data-id="' + s.id + '" title="删除会话">✕</button></div>';
      }).join('');
    }

    // P1-3: 搜索框事件
    const sessionSearch = document.getElementById('sessionSearch');
    if (sessionSearch) {
      sessionSearch.addEventListener('input', () => {
        sessionSearchQuery = sessionSearch.value.trim();
        renderHistory();
      });
    }

    document.addEventListener('click', (e) => {
      // Handle session export
      const exportBtn = e.target.closest('.session-export');
      if (exportBtn) {
        e.stopPropagation();
        exportSession(exportBtn.dataset.id);
        return;
      }
      // Handle session pin
      const pinBtn = e.target.closest('.session-pin');
      if (pinBtn) {
        e.stopPropagation();
        togglePinSession(pinBtn.dataset.id);
        return;
      }
      // Handle session rename
      const renameBtn = e.target.closest('.session-rename');
      if (renameBtn) {
        e.stopPropagation();
        renameSession(renameBtn.dataset.id);
        return;
      }
      // Handle session delete
      const deleteBtn = e.target.closest('.session-delete');
      if (deleteBtn) {
        e.stopPropagation();
        const id = deleteBtn.dataset.id;
        if (!confirm('确定要删除这个会话吗？')) return;
        let sessions = getSessions();
        sessions = sessions.filter(s => s.id !== id);
        saveSessions(sessions);
        logEvent('session', '删除会话');
        const currentId = getCurrentId();
        if (currentId === id) {
          setCurrentId('');
          chat.innerHTML = '';
          showWelcome();
        }
        renderHistory();
        return;
      }
      // Handle session click
      const item = e.target.closest('.session-item');
      if (!item) return;
      const sessions = getSessions();
      const session = sessions.find(s => s.id === item.dataset.id);
      if (!session) return;
      setCurrentId(session.id);
      chat.innerHTML = '';
      renderSessionMessages(session);
      showPage('chat');
    });

    const newSessionBtn = document.getElementById('newSessionBtn');
    if (newSessionBtn) {
      newSessionBtn.onclick = () => {
        const session = { id: Date.now().toString(), title: '新对话', messages: [], createdAt: Date.now(), updatedAt: Date.now(), pinned: false };
        const sessions = getSessions();
        sessions.unshift(session);
        setCurrentId(session.id);
        saveSessions(sessions);
        chat.innerHTML = '';
        showWelcome();
        showPage('chat');
        logEvent('session', '新建会话');
      };
    }

    // Wrap send to save messages (skipUserAppend=true 时不再重复保存 user)
    const originalSend = send;
    send = async function(skipUserAppend) {
      const text = input.value.trim();
      if (!text || busy) return;
      if (!skipUserAppend) {
        saveCurrentMessage('user', text);
        renderHistory();
        logEvent('chat', '发送消息: ' + text.slice(0, 50) + (text.length > 50 ? '...' : ''));
      }
      await originalSend(skipUserAppend);
    };

    // 初始化文件管理密码验证

    // Restore last session
    (function() {
      const id = getCurrentId();
      if (!id) return;
      const sessions = getSessions();
      const session = sessions.find(s => s.id === id);
      if (session && session.messages.length) {
        chat.innerHTML = '';
        renderSessionMessages(session);
      }
    })();

    // 启动后从 NAS 拉取合并（后台执行，失败静默降级本地存储）
    syncFromNas();

    // Version / release notes
    const WEBUI_VERSION = 'V1.8.4';
    // V1.4 微信推送开关
    (function () {
      const pushToggle = document.getElementById('pushToggle');
      if (pushToggle) {
        pushToggle.checked = localStorage.getItem('qingliao_push_enabled') === '1';
        pushToggle.addEventListener('change', () => {
          localStorage.setItem('qingliao_push_enabled', pushToggle.checked ? '1' : '0');
          showToast(pushToggle.checked ? '微信推送已开启' : '微信推送已关闭');
        });
      }
    })();
    const RELEASE_NOTES = `# 轻聊 版本记录

## V1.8.4 (2026-08-09) - 登录与通用型架构
- 🔐 新增登录界面：首次登录默认 qingliao / qingliao2026，支持"记住登录"（7 天免登录）
- ⚙️ 服务器地址可配置：登录页与设置页均可设置（默认当前地址，支持外网域名，为打包 IPA 铺路）
- 🔑 设置页新增"账号与安全"：修改登录密码、退出登录
- 🔌 连接信息卡升级：显示/修改服务器地址 + 一键测试连接
- 📖 新增"关于轻聊"页面（侧边栏独立入口）：项目介绍与使用说明
- 🧹 清理数据管理残留（用量统计清零空条目）

## V1.8.3 (2026-08-09) - 文件解析兜底统一 + 图片压缩缩边
- Word/Excel 解析失败自动降级：与 PDF 同款——上传文件到 NAS 并附链接（AI 不再"找不到文件"）
- 图片压缩加缩边兜底：降质到底仍超 900KB 时逐步缩边重绘（每次 0.7x，下限 480px），防极端大图超 nginx 1MB 413

## V1.8.2 (2026-08-09) - code review 修复
- PDF 降级判定收窄：只认 [PDF 失败前缀（避免以 [ 开头的合法提取文本被误判为失败）
- PDF 失败文案剥括号修正（错误信息含 ] 不再截断错位）
- 图片压缩循环降质（极限大图防 nginx 413）
- 清理看门狗 skillDetailOverlay 死代码

## V1.8.1 (2026-08-09) - 移除用量统计模块
- 移除用量统计：侧边栏入口、统计页面、清零按钮、前端统计记录逻辑（saveUsageToStorage/loadUsage/resetUsage）全部删除
- 后端无独立用量服务，无端口变化

## V1.8 (2026-08-09) - 移除技能模块 + PDF 缓存根治
- 移除技能模块（侧边栏入口、页面、前端 JS、后端 skills_api 9130 端口全部删除）
- PDF 解析根治：pdf.min.js 加载带版本戳（绕过 SW/HTTP 缓存——之前手机一直加载旧损坏库）
- PDF 本地解析失败自动降级：上传文件到 NAS 并附链接（AI 不再"找不到文件"）

## V1.7.5 (2026-08-09) - 磁盘备注 + 远程挂载过滤
- NAS 面板磁盘：volume1 标注"固态硬盘"备注（可扩展映射）
- 磁盘列表移除远程网盘挂载（/mnt/@remote）

## V1.7.4 (2026-08-09) - NAS 面板 HomeKit 化 + PDF 库修复
- NAS 面板重构：概览条（CPU/内存/磁盘/运行）+ 服务卡片网格（HomeKit 风格，智能家居同款圆角卡片）
- 服务状态显示内存占用（轻聊后端 22MB / Hermes 网关 395MB 实测）
- 修复 PDF 解析库损坏：替换为 PDF.js v3.11.174 UMD 版（原文件语法错误导致 pdfjsLib 未定义、PDF 附件无法上传）

## V1.7.3 (2026-08-09) - 修复 PDF 解析
- 修复 PDF 附件无法解析：pdf.min.js 为 UMD 构建，浏览器分支导出到 globalThis['pdfjs-dist/build/pdf']，AMD 场景不设 window.pdfjsLib——改为多路径获取
- 之前 pdfjsLib 未定义 → 提取失败 → PDF 附件内容从未发出（AI 收到只有文件名）

## V1.7.2 (2026-08-09) - NAS 面板
- 侧边栏新增 NAS 面板页：系统信息（主机名/运行时间）、CPU、内存、磁盘、服务状态
- 后端 /api/nas/status 端点（读 /proc/stat、meminfo、df、systemctl）
- 状态圆点（🟢运行中/🔴异常）、10s 自动刷新 + 手动刷新按钮

## V1.7.1 (2026-08-09) - 文件对话增强
- 文档文本截断保护：长 PDF/Word/Excel 提取超 12000 字符自动截断（防 context 溢出）
- 文件问答：发 PDF/Word/Excel → AI 提炼要点/回答内容问题（PDF.js/mammoth/SheetJS 提取）

## V1.7 (2026-08-09) - 图片理解
- 启用图片理解：聊天发图片 → AI 真正看图回答
- 后端：auxiliary.vision=stepfun（step-3.7-flash 视觉，唯一支持图片的 provider——opencode Go/DeepSeek 官方均不支持 image_url）
- 修复 config supports_vision 误标（opencode 实际不支持视觉，改为 false 走辅助视觉链路）
- 前端：MODEL_SUPPORTS_VISION=true + 图片压缩（canvas 最长边 1280px/JPEG 0.72，防超 nginx 1MB）
- 图片消息走标准 image_url 内容块

## V1.6.1 (2026-08-08) - 清理诊断残留
- 移除 kb_diag 诊断埋点（每次开侧栏/加载页面/看门狗修复都上传诊断文件，导致微信文件目录堆积）
- 清理现有 kb_diag_*.json 诊断文件

## V1.6 (2026-08-08) - 模型中心 + 审查加固
- 模型快捷切换全面升级：4 组 33+ 模型、可用性圆点（绿/红）、同步官方列表、模型切换真正生效（provider 透传）
- 修复：StepFun 域名（.ai→.com 中国站）、DeepSeek 官方 key/model 名（v4-flash/v4-pro）、小米 key 无效红点
- 安全加固：模型名/ID 渲染转义（escapeHtml），防官方 API 异常数据注入
- 新增：刷新按钮（重测可用性）、同步列表按钮（拉官方 /v1/models）

## V1.5.10 (2026-08-08) - 安全修复：模型名转义
- 修复：模型列表渲染时对模型名/ID/provider 做 escapeHtml 转义，防止 XSS（数据来自官方 API 同步）
- 影响范围：设置页快捷模型列表

## V1.5.9 (2026-08-08) - 同步官方模型列表
- 每个供应商分组标题新增"↻ 同步列表"按钮：调各官方 /v1/models 拉取真实模型并覆盖该组
- 同步结果持久化（localStorage），重启保留
- 后端新增 sync-models 端点（读 config 的 provider key 调官方接口）

## V1.5.8 (2026-08-08) - 修正 DeepSeek 官方模型名
- DeepSeek 官方 API 模型为 deepseek-v4-flash / deepseek-v4-pro（官方文档确认，V4 时代新命名）
- 修正：原误用旧命名 deepseek-chat/reasoner（V3/R1 时代）

## V1.5.7 (2026-08-08) - 模型状态刷新按钮
- 模型快捷切换卡片标题栏新增"刷新"按钮：一键清缓存并重新探测所有分组可用性
- 修复 StepFun 域名问题（api.stepfun.ai → api.stepfun.com）

## V1.5.6 (2026-08-08) - 探测带 provider（修复假绿灯）
- 根因：探测不带 provider 时 Hermes 静默 fallback 默认模型（如小米 key 无效仍返回 200）
- 修复：探测携带 provider 参数，路由失败（401 等）正确显示红点
- 验证：小米 MiMo 官方 API Key 无效 → 正确红点；其余组绿点

## V1.5.5 (2026-08-08) - 分组状态改圆点
- 分组状态改为绿点（可用）/红点（不可用），无文字干扰
- 探测缓存统一 30 秒；点击圆点可强制重新检测

## V1.5.4 (2026-08-08) - 分组可用性探测优化
- 修复：探测失败结果只缓存 30 秒（此前 5 分钟，服务抖动后长时间误报"不可用"）
- 徽标悬停可看失败原因（title）

## V1.5.3 (2026-08-08) - 修复模型切换不生效（真凶）
- 根因：9123 裸 model 参数（无 provider）时 Hermes 静默回退默认模型，且响应回显请求模型名（假切换）
- 修复：模型列表每个模型携带 provider（opencode/stepfun/deepseek/xiaomi），发送请求透传 provider —— 切换真正生效
- 实测：kimi-k3 裸请求=DeepSeek 回复，带 provider 后=Kimi 回复

## V1.5.2 (2026-08-08) - 模型分组可用性标注
- 快捷列表新增"小米 MiMo 官方"组：MiMo 1.5 Flash / V2 Omni（共 33 个模型）
- 每个分组标题标注可用状态：✓ 当前可用 / ✗ 不可用（后端实时探测，缓存 5 分钟）
- 模型切换实际生效验证：切换后发送请求携带新模型 ID

## V1.5.1 (2026-08-08) - 补 DeepSeek 官方模型
- 快捷列表新增"DeepSeek 官方"组：DeepSeek Chat (V3) / Reasoner (R1)，共 31 个模型
- 注意：官方 API 按量计费（走官方余额），其余模型走 Go 订阅免费额度
- SW 缓存升级 v19

## V1.5 (2026-08-08) - 模型快捷切换
- 设置页新增"模型快捷切换"：29 个可用模型（OpenCode Go 订阅 26 个 + StepFun 3 个）分组列表，点「设为当前」一键切换
- 模型选择持久化（localStorage），重启不丢；切换后下一条消息立即用新模型
- 修复：删除看门狗 sidebarStuck 误报——侧栏正常打开超过 3 秒被误判为"卡住"强关（现在侧栏开着=正常使用，不再自动关闭+弹提示）

## V1.4.1 (2026-08-08) - 修复推送开关不持久
- 根因：V1.4 发版未升级 SW 缓存版本，旧缓存一直提供旧版 app.js（无开关初始化逻辑）
- 修复：SW 缓存升级 qingliao-v17，强制清旧缓存重建（重开后若见"发现新版本"提示请点刷新）

## V1.4 (2026-08-08) - 微信推送
- 微信接力推送：回复完成时若你已离开 App（≥30 秒未查看），自动发微信通知 + 内容摘要
- 设置页新增"微信推送"开关（默认关，开启后生效）
- 实现：流完成 → Hermes webhook deliver-only 直发微信（零 AI 成本、微信系统级通知稳定到达）

## V1.3 (2026-08-08) - 秒开 + 渲染加速
- 启动秒开：HTML 导航改 stale-while-revalidate（缓存优先即时显示、后台更新）——启动彻底不碰网络等待，离线也能秒开
- 新版刷新通道：点击"刷新生效"先清缓存再刷新（SWR 缓存优先下不清缓存会一直拿旧版）
- markdown 渲染内存缓存：同一内容不重复解析（会话切换/重复消息提速，LRU 上限 300 条）
- 流式轮询自适应：有增量 500ms 提速、连续 3 次无内容降 2000ms（省电、NAS 请求减半）
- SW 缓存升级 qingliao-v16

## V1.2 (2026-08-08) - 冷启动提速 + 体验优化
- 冷启动质变：主 JS（128KB）从内联抽离为 /app.js，由 Service Worker 缓存 —— 二次启动零下载、解析走缓存，配合依赖自托管实现"即点即开"
- SW 更新提示：新版就绪后提示"发现新版本，点击刷新生效"（首次安装不打扰，杀后台重开仍直接拿新版）
- 流式轮询去重：send/recover 两条重复实现合并为共享工厂 createStreamPoller（修一处即两边生效）
- 消息图片懒加载（loading=lazy + async 解码），长会话滚动到才加载
- 会话存储容量保护：超 3.5MB 自动归档最旧的非当前会话（防 localStorage 写满）
- SW 缓存升级 qingliao-v15 + /app.js 预缓存

## V1.1.2 (2026-08-08) - 气泡更紧凑
- 聊天气泡高度调低约 1/3：竖向内边距 6px→3px、行高 1.4→1.2、消息间距 8px→6px（微信同款紧凑感）

## V1.1.1 (2026-08-08) - 修复看门狗误报
- 修复：打开侧栏时频繁弹"已自动清除界面残留: sidebarMask"
- 根因：侧栏滑入动画窗口（transition 0.3s，蒙板立即显示、侧栏从 -393px 滑入）内，看门狗 tick 命中时 left < -50 把刚打开的侧栏误判为"蒙板残留"→ 强制关闭 + 弹提示
- 修复：看门狗跳过侧栏打开后 600ms 动画窗口的残留判定（sbOpenedAt 记录打开时刻）

## V1.1 (2026-08-08) - 性能优化版
- 流式渲染优化：聊天过程中只增量显示纯文本（零 markdown 解析），输出完成后一次性渲染格式 —— 长消息从"每 0.8s 全量解析"降为"全程只解析 1 次"
- 定时器省电：键盘兜底轮询只在输入框聚焦时运行，看门狗非聊天页且无抽屉/蒙板时快速返回（待机零空转）
- 轮询故障保护：连续 10 次拉取失败自动停止并提示（不再无限重试打服务器）
- 依赖自托管：marked/DOMPurify/highlight 样式从 CDN 迁到 NAS /libs/（PWA 冷启动更快、离线可用、不再依赖外网）
- 会话落盘节流：流式期间 localStorage 写入从每增量一次降为 ≥2s 一次
- SW 缓存升级（qingliao-v14）+ libs 预缓存

## V1.0 (2026-08-08) - 正式版
- 移动端键盘适配架构定稿（微信式，18 版迭代验证）：
  - 输入框 position:fixed 贴底（z-index 1050）；抽屉(1100)/蒙板(1090)最上，打开时盖住输入框（标准抽屉行为）
  - 键盘弹出：bottom = 实时 innerHeight - 实时 visualViewport.height，输入框跟随键盘浮起
  - 键盘"真在"判定 = 视口明显小于聚焦会话峰值(≥60px)；收起即贴底归位（无悬空留白）
  - 消息区底部留白随键盘同步（76+抬升高度），最后一条消息始终可滚到输入框上方
  - 兼容 iOS 布局视口压缩（innerHeight 793→410）与"完成"按钮收键盘两种随机行为
- 抽屉防误触（水平主导滑动）+ 残留看门狗 + 聚焦自动收侧栏（微信式）
- 诊断上报保留事件型（page-load/watchdog-fixed），移除 5s 周期上报
- 注：Safari 标签页打开时底部留白为浏览器工具栏区域，请从主屏幕图标（独立模式）打开获得全屏体验
`;;
    function renderReleaseNotes() {
      const versionEl = document.getElementById('webuiVersion');
      const notesEl = document.getElementById('releaseNotes');
      if (versionEl) versionEl.textContent = WEBUI_VERSION || '--';
    const aboutV = document.getElementById('aboutVersion');
    if (aboutV) aboutV.textContent = WEBUI_VERSION || '--';
      if (!notesEl) return;
      if (!RELEASE_NOTES.trim()) {
        notesEl.innerHTML = '<div style="color:var(--text-muted);">暂无更新日志</div>';
        return;
      }
      const lines = RELEASE_NOTES.split('\n');
      let html = '';
      let versionCount = 0;   // 已渲染的版本块数
      let inVersionBlock = false;
      const MAX_VERSIONS = 5; // 最多显示 5 个版本（从新到旧）
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        if (trimmed.startsWith('## ')) {
          versionCount++;
          if (versionCount > MAX_VERSIONS) break;   // 超过 5 个版本不再渲染
          inVersionBlock = true;
          html += '<div style="font-weight:600;margin-top:10px;color:var(--text);">' + escapeHtml(trimmed.slice(3)) + '</div>';
        } else if (trimmed.startsWith('# ')) {
          // 总标题只在第一个版本前显示
          if (versionCount === 0) html += '<div style="font-weight:600;margin-top:10px;">' + escapeHtml(trimmed.slice(2)) + '</div>';
        } else if (trimmed.startsWith('- ') && inVersionBlock) {
          html += '<div style="padding-left:14px;position:relative;">' + escapeHtml(trimmed.slice(2)) + '</div>';
        } else if (inVersionBlock) {
          html += '<div>' + escapeHtml(trimmed) + '</div>';
        }
      }
      notesEl.innerHTML = html;
    }

    // Initialize header with model name
    updateModelName(CURRENT_MODEL);
    // V1.5：模型列表点击委托（设为当前）
    (function () {
      const box = document.getElementById('quickModelsList');
      if (box) {
        box.addEventListener('click', (e) => {
          const btn = e.target.closest('.qm-btn');
          if (btn) {
            const row = btn.closest('.qm-row');
            if (row) setCurrentModel(row.dataset.model, row.dataset.name, row.dataset.provider);
            return;
          }
          const dot = e.target.closest('.qm-dot');
          if (dot) {
            const grp = dot.dataset.group;
            const g = (QUICK_MODELS || []).find(x => x.group === grp);
            if (g) { deleteFromGroupStatus(grp); checkGroup(g); }
            return;
          }
          const syncBtn = e.target.closest('.qm-sync-btn');
          if (syncBtn) {
            const grp = syncBtn.dataset.group;
            const g = (QUICK_MODELS || []).find(x => x.group === grp);
            if (g) syncModels(g);
          }
        });
      }
    })();
    renderQuickModels();

    renderReleaseNotes();

    // Version card toggle
    const versionCardTitle = document.getElementById('versionCardTitle');
    const releaseNotesEl = document.getElementById('releaseNotes');
    const versionToggleIcon = document.getElementById('versionToggleIcon');
    if (versionCardTitle && releaseNotesEl) {
      versionCardTitle.addEventListener('click', () => {
        const isHidden = releaseNotesEl.style.display === 'none';
        releaseNotesEl.style.display = isHidden ? 'block' : 'none';
        if (versionToggleIcon) versionToggleIcon.textContent = isHidden ? '▲' : '▼';
      });
    }

    showPage('chat');

// V1.8.4 必须登录门禁：无 token 显示登录层（后端各 API 已要求 token）
if (!getToken()) { setTimeout(showLogin, 60); }
// V1.8.4 设置页显示当前服务器/用户
(function initServerInfo() {
  const cs = document.getElementById('currentServer');
  if (cs) cs.textContent = getApiBase() || location.origin;
  const si = document.getElementById('serverInput');
  if (si && !si.value) si.value = getApiBase() || location.origin;
  const cu = document.getElementById('currentUser');
  if (cu && getToken()) {
    fetch('/api/auth/status').then(r => r.json()).then(d => {
      if (d.ok && d.username) cu.textContent = d.username;
    }).catch(() => {});
  }
})();
