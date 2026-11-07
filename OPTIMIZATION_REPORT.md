# 91Download Mobile v1.0.5.409 优化报告

## 优化概述

本次优化分为两轮代码审查，对 Flutter 应用进行了全面的代码质量和性能改进，涵盖 10 个核心文件的代码重构和最佳实践升级。

---

## 第一轮优化

### 1. API 迁移 - WillPopScope → PopScope
**文件**: `lib/pages/main_page.dart`

**问题**: 使用了已废弃的 `WillPopScope` API
**优化**:
- 迁移到新的 `PopScope` API
- 使用 `onPopInvokedWithResult` 回调替代 `onWillPop`
- 提升了代码的向前兼容性

### 2. Duration const 优化（第一轮）
**文件**: `lib/pages/search_page.dart`, `lib/pages/batch_page.dart`, `lib/pages/download_page.dart`, `lib/pages/main_page.dart`

**问题**: 多次创建相同的 Duration 实例
**优化**:
- 将 14 处 `Duration(...)` 改为 `const Duration(...)`
- 减少了运行时对象创建开销

**具体位置**:
- `search_page.dart`: 5处
- `batch_page.dart`: 4处
- `download_page.dart`: 5处
- `main_page.dart`: 1处

### 3. 代码结构改进 - AppState
**文件**: `lib/services/app_state.dart`

**优化内容**:
- 新增 `ThemeModeType` 枚举类，消除魔法数字
- 新增 `DownloadConfig` 常量类，统一管理下载配置
- 重构 `_loadSettings()` 和 `_saveSettings()` 方法
- 优化权限请求逻辑，抽取 `_requestStoragePermission()` 私有方法
- 使用 `Future.wait()` 批量操作提升设置保存性能
- 添加更详细的类型注释

### 4. 性能优化 - DownloadManager
**文件**: `lib/services/download_manager.dart`

**优化内容**:
- 新增 `FormatUtils` 工具类，将格式化方法抽取为静态方法
- 避免了每次创建 `DownloadTask` 实例时的重复方法定义
- 提升了代码的可维护性和性能

---

## 第二轮深度优化

### 5. 未使用 import 清理
**文件**: `lib/pages/search_page.dart`, `lib/pages/batch_page.dart`

**问题**: 导入了未使用的 `dart:ui` 包
**优化**: 删除冗余 import，减少编译依赖

### 6. Duration const 补充优化
**文件**: `lib/pages/followed_page.dart`, `lib/crawler/crawler_core.dart`, `lib/services/floating_video_service.dart`

**新增优化**:
- `followed_page.dart`: 1处 Duration 改为 const
- `crawler_core.dart`: 1处 Duration 改为 const
- `floating_video_service.dart`: 1处 Duration 改为 const

**累计**: 17处 Duration 优化为 const

### 7. EdgeInsets const 批量优化
**文件**: `lib/pages/download_page.dart`, `lib/pages/batch_page.dart`, `lib/pages/followed_page.dart`

**问题**: 大量 `EdgeInsets` 实例未使用 const，每次构建都会创建新对象
**优化**: 批量添加 const 关键字

**统计**:
- `download_page.dart`: ~55处 EdgeInsets 优化
- `batch_page.dart`: ~25处 EdgeInsets 优化
- `followed_page.dart`: ~4处 EdgeInsets 优化

**累计**: ~84处 EdgeInsets 优化为 const

### 8. RegExp 静态常量提取
**文件**: `lib/crawler/config.dart`, `lib/crawler/crawler_core.dart`, `lib/services/download_manager.dart`

**问题**: 高频使用的正则表达式在循环内重复编译，造成性能浪费
**优化**:
- `config.dart`: 新增 `htmlTagPattern`、`htmlEntityPattern`、`whitespacePattern` 三个静态常量
- `crawler_core.dart`: 将所有内联 `RegExp(r'<[^>]*>')`、`RegExp(r'&[a-z]+;')`、`RegExp(r'[\s　]+')` 替换为对应的 CrawlerConfig 常量引用
- `download_manager.dart`: 新增 `_taskIdRegExp` 静态常量

**效果**: 正则表达式仅在类加载时编译一次，避免每次解析时重复编译

### 9. AppState Crawler Getter 优化
**文件**: `lib/services/app_state.dart`

**问题**: `crawler` getter 每次调用都会重新设置所有配置属性并调用 `setup()`，造成不必要的性能开销
**优化**:
- 只在 `_crawler` 新建时才执行 setup 操作
- 避免每次 getter 调用时重复配置

### 10. DownloadManager 并发任务跟踪修复
**文件**: `lib/services/download_manager.dart`

**问题**: `_activeTaskId` 是单个 String?，无法正确跟踪多个并发下载任务
**优化**:
- 将 `_activeTaskId` 改为 `Set<String> _activeTaskIds`
- 下载开始时 add taskId，完成或取消时 remove
- `cancelTask()` 中使用 `_activeTaskIds` 正确判断任务是否活跃

---

## 优化效果总结

| 优化项 | 影响文件数 | 优化处数 | 优化效果 |
|--------|-----------|---------|----------|
| API 迁移 | 1 | 1 | 消除废弃 API 警告 |
| Duration const | 7 | 17 | 减少运行时对象创建 |
| EdgeInsets const | 3 | ~84 | 大幅减少运行时对象创建 |
| 代码结构 | 1 | - | 提升可维护性 |
| 下载管理器 | 1 | - | 减少内存分配，修复并发跟踪 |
| 正则优化 | 3 | - | 避免重复编译，提升解析性能 |
| 未使用 import | 2 | 2 | 减少编译依赖 |
| Crawler Getter | 1 | 1 | 减少重复 setup 调用 |

---

## 文件变更清单（共 10 个文件）

1. `lib/pages/main_page.dart`
2. `lib/pages/search_page.dart`
3. `lib/pages/batch_page.dart`
4. `lib/pages/download_page.dart`
5. `lib/pages/followed_page.dart`
6. `lib/services/app_state.dart`
7. `lib/services/download_manager.dart`
8. `lib/crawler/crawler_core.dart`
9. `lib/crawler/config.dart`
10. `lib/services/floating_video_service.dart`

---

## 新增代码示例

### ThemeModeType 枚举
```dart
enum ThemeModeType {
  light(0, '日间'),
  dark(1, '夜间'),
  auto(2, '跟随系统');

  final int value;
  final String label;
  const ThemeModeType(this.value, this.label);
}
```

### DownloadConfig 常量类
```dart
class DownloadConfig {
  static const int minConcurrentTasks = 1;
  static const int maxConcurrentTasksLimit = 5;
  static const int defaultConcurrentTasks = 2;
  static const int minConcurrentSegments = 1;
  static const int maxConcurrentSegmentsLimit = 64;
  static const int defaultConcurrentSegments = 32;
}
```

### CrawlerConfig 新增正则常量
```dart
class CrawlerConfig {
  static final RegExp htmlTagPattern = RegExp(r'<[^>]*>');
  static final RegExp htmlEntityPattern = RegExp(r'&[a-z]+;');
  static final RegExp whitespacePattern = RegExp(r'[\s　]+');
}
```

### FormatUtils 工具类
```dart
class FormatUtils {
  static String formatDuration(Duration duration) {
    // 格式化时长为 HH:MM:SS
  }

  static String formatFileSize(int bytes) {
    // 格式化文件大小为 KB/MB/GB
  }
}
```

---

## 后续建议

1. **Flutter 升级**: 考虑升级到 Flutter 3.x 以获取更好的性能和新特性
2. **单元测试**: 添加更多单元测试覆盖核心业务逻辑（下载管理、爬虫解析等）
3. **数据类优化**: 考虑使用 `freezed` 或 `equatable` 来简化数据类的实现
4. **图片缓存**: 优化图片加载性能，考虑使用缓存策略
5. **静态分析**: 定期使用 `flutter analyze` 检查代码质量和未使用代码
6. **正则优化**: 继续将 `crawler_core.dart` 中剩余的 `RegExp` 提取为静态常量
7. **空安全**: 检查并完善空安全处理，减少潜在的 NullPointerException
