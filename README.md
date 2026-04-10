# 91Download Mobile

91Download 移动端视频下载器，基于 Flutter 开发。

> ⚠️ **声明**：本项目代码由 AI（Claude）辅助编写，仅供学习交流使用。

## 功能特性

- 🎬 **视频列表浏览**：支持多种分类（视频、最热、原创等）
- 🔍 **关键词搜索**：搜索视频和作者
- ⬇️ **批量下载**：M3U8解析、TS切片并发下载
- 📜 **下载历史**：本地数据库管理
- 🎨 **深色主题**：Material 3 设计

## 技术栈

- Flutter 3.16+
- Dart
- SQLite (sqflite)
- Dio (HTTP客户端)

## 开始使用

```bash
# 安装依赖
flutter pub get

# 运行调试
flutter run

# 构建 APK
flutter build apk --release
```

## 项目结构

```
lib/
├── crawler/          # 爬虫核心
│   ├── config.dart   # 配置（与Python版一致）
│   └── crawler_core.dart
├── models/           # 数据模型
├── pages/            # 页面
│   ├── batch_page.dart    # 批量爬取
│   ├── search_page.dart   # 搜索
│   ├── history_page.dart  # 下载历史
│   └── settings_page.dart # 设置
└── services/         # 服务
```

## 注意事项

- 站点选择在**设置页面**
- 爬虫逻辑与 PC 端 Python 版本保持一致
- 需要存储权限才能下载视频

## License

MIT License
