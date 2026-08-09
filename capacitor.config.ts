import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.qingliao.app',
  appName: '轻聊',
  webDir: 'www',
  backgroundColor: '#f2f2f7',
  ios: {
    contentInset: 'always',
    // 允许 http 明文（内网 NAS 场景，ATS 例外在 Info.plist 配置）
    preferredContentMode: 'mobile',
  },
  server: {
    // 关键：默认加载本地 www（capacitor://localhost），API 服务器地址由应用内 qingliao_server 配置
    androidScheme: 'https',
    iosScheme: 'capacitor',
  }
};

export default config;
