#!/usr/bin/env node
/**
 * 从 NAS 工作副本同步最新前端到 www/
 * 源：/opt/data/ql_work/real_*（与线上部署 md5 一致的工作副本）
 * 目标：本工程 www/
 * 用法：node scripts/sync-web.js
 */
const fs = require('fs');
const path = require('path');

const SRC = '/opt/data/ql_work';
const LIBS_SRC = '/opt/data/轻聊';
const DEST = path.join(__dirname, '..', 'www');

function copy(from, to) {
  fs.mkdirSync(path.dirname(to), { recursive: true });
  fs.copyFileSync(from, to);
  console.log(`  ${path.basename(from)} → www/${path.relative(path.join(__dirname, '..', 'www'), to)}`);
}

console.log('同步轻聊前端到 www/:');
copy(path.join(SRC, 'real_index.html'), path.join(DEST, 'index.html'));
copy(path.join(SRC, 'real_app.js'), path.join(DEST, 'app.js'));
copy(path.join(SRC, 'real_sw.js'), path.join(DEST, 'sw.js'));

// 未改动的静态资源从部署目录复制
for (const f of ['manifest.json']) {
  copy(path.join(LIBS_SRC, f), path.join(DEST, f));
}
for (const f of ['icon-192.png', 'icon-512.png', 'icon-maskable-512.png']) {
  copy(path.join(LIBS_SRC, 'icons', f), path.join(DEST, 'icons', f));
}
copy(path.join(LIBS_SRC, 'apple-touch-icon.png'), path.join(DEST, 'apple-touch-icon.png'));

// libs（自托管依赖）
const libs = fs.readdirSync(path.join(LIBS_SRC, 'libs'));
for (const f of libs) {
  copy(path.join(LIBS_SRC, 'libs', f), path.join(DEST, 'libs', f));
}

// iOS 图标（@capacitor/assets 约定：工程根 resources/）
fs.mkdirSync(path.join(__dirname, '..', 'resources'), { recursive: true });
copy('/opt/data/ql_ipa_res/icon.png', path.join(__dirname, '..', 'resources', 'icon.png'));

console.log('\n完成。检查 www/:');
for (const f of fs.readdirSync(DEST)) {
  const st = fs.statSync(path.join(DEST, f));
  console.log(`  ${f}${st.isDirectory() ? '/' : ''} (${st.isDirectory() ? '' : st.size + 'B'})`);
}
