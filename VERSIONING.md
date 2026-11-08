# 版本与提交规范

本项目的版本号只有一个真实来源：`pubspec.yaml` 的 `version` 字段，形如 `1.0.7+7`。

```
version: MAJOR.MINOR.PATCH+BUILD
            │     │     │      └── 构建号，CI 自动覆写为 GitHub run_number
            │     │     └───────── 修复类更新 +1
            │     └─────────────── 新功能 +1，同时把 PATCH 归零
            └───────────────────── 架构级/不兼容改动 +1，MINOR、PATCH 归零
```

## 一、每次更新都要动版本号

**任何会进入 Release 的改动都必须改 `pubspec.yaml` 的 `version`**，tag 与 APK 内嵌版本都由它派生：

| 位置 | 形式 | 由谁决定 |
|:--|:--|:--|
| `pubspec.yaml` | `1.0.7+7` | 开发者手动维护（每次更新递增） |
| APK 内嵌版本 | versionName=1.0.7 / versionCode=N | 由 pubspec 生成 |
| GitHub Release tag | `v1.0.7.<run_number>` | CI 拼接 |

CI 只把 `+N` 换成 run_number（见 `.github/workflows/build.yml` 的 *Sync version with CI run_number*），
**不会**改 MAJOR.MINOR.PATCH。所以：

- 改了功能却没改 MAJOR.MINOR.PATCH → 应用内「检查更新」比较的是语义化版本，用户永远收不到更新提示。
- 改 MAJOR.MINOR.PATCH 时顺手把 `+N` 也 +1，保持本地开发版本自洽（CI 会覆写，但本地 `flutter build` 需要它）。

递增速查：

```
修复 bug、文案、样式           1.0.7+7  →  1.0.8+8
新增功能                       1.0.7+7  →  1.1.0+8
架构调整 / 不兼容变更           1.0.7+7  →  2.0.0+8
```

## 二、提交信息规范（Conventional Commits）

```
<type>(<scope>): <一句话说明>
```

`type` 取值与 Release 说明的生成有关——CI 取**最后一次提交的首行**、剥掉 `type(scope):` 前缀后
作为 Release 更新说明，所以：

- 首行要能直接当更新日志读，写人话，不要写「update code」；
- 详细实现写在提交正文（body），正文不会进 Release 说明。

| type | 含义 | 是否进 Release 说明 |
|:--|:--|:--|
| `feat` | 新功能 | 是 |
| `fix` | 修复缺陷 | 是 |
| `perf` | 性能优化 | 是 |
| `refactor` | 重构（不改行为） | 是 |
| `docs` / `style` / `test` / `build` / `ci` / `chore` | 文档、格式、测试、构建、CI、杂务 | 是（但一般不该单独发版） |

示例：

```
fix(download): 修复下载进度条不动 / 暂停无效
feat(crawler): 支持 jiuse 站点（91porny / jiuse.icu）
chore(release): 发布 1.0.7
```

## 三、一次更新 = 一串提交 + 一个版本提交

1. 按功能拆分提交，一个提交只做一件事（便于回滚与 review）；
2. 收尾时单独提交一个 `chore(release): 发布 X.Y.Z`，只改 `pubspec.yaml` 的版本号；
3. 打 tag（与 CI 生成的 tag 前缀一致）：

```bash
git tag -a v1.0.7 -m "发布 1.0.7"
```

4. push 到 `main`，CI 构建 Release APK，tag 为 `v1.0.7.<run_number>`。

## 四、发布前自检

```bash
flutter analyze          # 0 error（warning/info 允许存量）
```

运行逻辑（列表/详情/播放地址解析）如需回归，用项目外的本地样本与 mock 服务验证；
用例目录已从仓库移除，不进版本库、也不参与 CI 构建。

本地可直接出包：

```bash
flutter build apk --debug     # 产物：build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --release
```

## 五、分支约定

当前仓库主干为 `main`，CI 在 push `main` 时发布。较大的功能建议开分支：

```bash
git switch -c feat/jiuse-site
# ... 开发、提交 ...
git switch main && git merge --no-ff feat/jiuse-site
```
