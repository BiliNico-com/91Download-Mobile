# 91Download Mobile

一款简洁易用的视频下载工具移动端，基于 Flutter 开发。

> ⚠️ **声明**：本项目仅供学习交流使用，请勿用于非法用途。

## 功能特性

- 🎬 **视频浏览** - 多种分类浏览，支持大图/列表模式
- 🔍 **智能搜索** - 关键词搜索视频和作者
- ⬇️ **批量下载** - M3U8自动解析、并发下载
- 📜 **下载管理** - 本地数据库记录，断点续传
- 🔒 **应用锁** - PIN码保护隐私
- 🎨 **深色主题** - Material 3 设计，护眼模式
- 📱 **良好适配** - 支持Android 7.0+

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
```

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
