# 轻聊 iOS IPA 壳工程

轻聊前端（NAS PWA）用 Capacitor 8 打包成 iOS App。
GitHub Actions 编译产出 **unsigned IPA**，手机 SideStore 导入后用 Apple ID 签名安装。

## 目录结构
```
www/                     轻聊静态文件（index.html / app.js / sw.js / libs / icons）
capacitor.config.ts      Capacitor 配置（appId: com.qingliao.app）
resources/icon.png       iOS 图标（1024x1024）
exportOptions.plist      无签名导出配置
.github/workflows/       GitHub Actions 构建 workflow
```

## 构建流程（GitHub Actions，macos runner）
1. `npm ci` 安装 Capacitor
2. `npx cap add ios` 生成 Xcode 工程
3. `npx cap sync ios` 同步 www → ios 工程
4. Info.plist 加 ATS 例外（允许 http 内网 NAS）
5. `xcodebuild archive`（CODE_SIGNING_ALLOWED=NO，不签名）
6. 导出 unsigned IPA → artifact 下载

## 安装（SideStore）
1. Actions 页下载 qingliao-unsigned-ipa artifact（.ipa）
2. 手机 SideStore → My Apps → + → 选择 IPA
3. SideStore 用 Apple ID 签名安装（自动刷新防 7 天过期）

## 首次打开配置
- 登录页**必须填写服务器地址**（如 `http://192.168.31.40:8080` 或外网 `http://webui.889174.xyz:16666`）
- 默认账号 qingliao / qingliao2026
- 地址会保存，之后免填

## 本地开发
```bash
npm install
node scripts/sync-web.js   # 从 NAS 拉最新前端到 www/
npx cap add ios            # 首次
npx cap sync ios           # 同步
npx cap open ios           # Xcode 打开（需 Mac）
```

## 前端更新流程
1. NAS 上改 ql_work/real_*.js（PWA 与 IPA 共用）
2. `node scripts/sync-web.js` 拉取到 www/
3. 推送仓库 → 手动触发 workflow → 下载新 IPA → SideStore 更新
