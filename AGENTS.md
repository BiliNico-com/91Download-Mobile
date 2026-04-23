## 项目概述
91Download Mobile - 简洁易用的视频下载工具移动端，基于 Flutter 开发，支持 Android 7.0+。

## 技术栈
- Flutter 3.16+
- Dart 3.x
- SQLite (sqflite) - 本地数据库
- Dio - HTTP 客户端
- Provider - 状态管理

## 目录结构
```
/workspace/projects/
├── lib/                    # Flutter 源码
│   ├── crawler/           # 数据爬取核心
│   ├── models/            # 数据模型
│   ├── pages/             # 页面 UI
│   ├── services/           # 服务层
│   └── utils/              # 工具类
├── android/                # Android 原生代码
│   └── app/src/main/kotlin/com/bilinico/download_91/
│       ├── MainActivity.kt
│       ├── FloatingWindowService.kt
│       └── PipPlugin.kt
├── pubspec.yaml            # Flutter 依赖配置
├── version.json            # 版本信息
└── .coze                   # Coze 项目配置
```

## 关键入口
- Flutter 入口: `lib/main.dart`
- Android 入口: `android/app/src/main/kotlin/com/bilinico/download_91/MainActivity.kt`

## 运行与构建
```bash
# 安装依赖
flutter pub get

# 调试运行
flutter run

# 构建 APK
flutter build apk --release
```

## 用户偏好与长期约束
- 项目使用原生悬浮窗替代 Flutter 悬浮窗方案
- 固定 APK 签名配置（release.keystore）
- 支持多站点视频下载

## 常见问题和预防
- 首次使用需在设置页面选择站点
- Android 权限需手动授权（存储、悬浮窗等）
