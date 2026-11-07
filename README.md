# 91Download Mobile

一款简洁易用的视频下载工具移动端，基于 Flutter 开发。

> ⚠️ **声明**：本项目代码由 AI（Claude）辅助编写，仅供学习交流使用，请勿用于非法用途。

## 功能特性

- 🎬 **视频浏览** - 多种分类浏览，支持大图/列表模式
- 🔍 **智能搜索** - 关键词搜索视频和作者
- ⬇️ **批量下载** - M3U8自动解析、并发下载
- 📜 **下载管理** - 本地数据库记录，断点续传
- 🔒 **应用锁** - PIN码保护隐私
- 🎨 **深色主题** - Material 3 设计，护眼模式
- 📱 **良好适配** - 支持Android 7.0+
- 🌐 **多站点** - 91porn / 91porny / jiuse 站点切换，支持自定义站点；按家族分组展示并内置测速，最快线路自动打标
- 🚀 **播放线路** - 内置多条视频 CDN 节点，可测速后手动选择
- 🧹 **干净标题** - 自动剔除标题/作者中的隐形字符，搜索与文件名不再踩坑

## 截图

| 批量页面 | 搜索页面 | 下载历史 | 设置页面 |
|:---:|:---:|:---:|:---:|
| 批量爬取 | 关键词搜索 | 本地记录 | 个性化配置 |

## 下载安装

前往 [Releases](https://github.com/BiliNico-com/91Download-Mobile/releases) 页面下载最新版本APK。

## 使用说明

1. **首次使用** - 进入设置页面选择站点
2. **浏览视频** - 在批量页面浏览分类内容
3. **搜索视频** - 输入关键词搜索感兴趣的内容
4. **下载视频** - 点击视频卡片开始下载
5. **查看历史** - 在已下载页面管理下载记录

## 技术栈

- Flutter 3.16+
- Dart
- SQLite (sqflite)
- Dio (HTTP客户端)
- Provider (状态管理)

## 版本与提交规范

版本号、提交信息与发布流程见 [VERSIONING.md](VERSIONING.md)。一句话概括：
每次更新都要递增 `pubspec.yaml` 里的 `version`，CI 只会把 `+N` 换成 run_number。

## 编译构建

```bash
# 克隆项目
git clone https://github.com/BiliNico-com/91Download-Mobile.git

# 安装依赖
flutter pub get

# 运行调试
flutter run

# 构建APK
flutter build apk --release

# 静态检查与用例
flutter analyze
flutter test
```

本仓库已补入完整的 Android 构建配置（gradle wrapper、gradle.properties、
启动主题与自适应图标），clone 后配置好 `android/local.properties` 即可直接构建。

## 项目结构

```
lib/
├── crawler/          # 数据获取核心
├── models/           # 数据模型
├── pages/            # 页面UI
│   ├── batch_page.dart
│   ├── search_page.dart
│   ├── history_page.dart
│   └── settings_page.dart
├── services/         # 服务层
└── utils/            # 工具类
```

## License

MIT License
