# VPN-Splitter 品牌资源

品牌形象：**紫色猫头鹰**。

## 文件

| 文件 | 风格 | 用途 |
| --- | --- | --- |
| `mascot-owl.webp` | 扁平风格品牌吉祥物 | 软件内品牌展示（About/欢迎页/空状态）、README 与项目文档、未来官网与宣传 |
| `mascot-owl-macos.webp` | 紫色渐变、柔和立体的 macOS 原生风格圆角方形图标 | 正式 macOS App Icon 的唯一设计源（Dock / Finder / Launchpad / 应用切换器 / 安装包与发布页） |

两种风格共存，互不替换：扁平猫头鹰不用于 App Icon，立体图标不用于内页插画。

## 使用约定

- App Icon 的 PNG 资源不放在本目录，而是生成到各 Xcode 工程实际使用的
  Asset Catalog：
  - `apps/macos/App/Assets.xcassets/AppIcon.appiconset`（正式应用，全套
    macOS 尺寸 16–512pt 含 @2x）
  - `apps/macos/LocalDev/Assets.xcassets/AppIcon.appiconset`（开发版，同主体
    叠加 DEV 徽标，必须与正式应用可区分）
- 重新生成（例如源图更新后）：

  ```sh
  python3 tools/branding/generate_appicons.py
  ```

  该脚本负责：白边/圆角外的页面背景清理、四角与边缘的合成补全
  （调和填充 + 羽化）、1024×1024 主图放大、全部尺寸派生、LocalDev 的
  DEV 徽标，以及 `BrandMascot.imageset`（内页使用的扁平猫头鹰 PNG）。
- 应用内引用：`Image("BrandMascot")`（主应用 Assets.xcassets）。

## 源图清晰度说明（重要）

当前仓库只有 256×256 的 WebP 优化版。已知存在更高清的原始设计图，
但尚未进入仓库；本机检索也未找到。因此现有 AppIcon 是以 256×256 为源、
经高质量放大与边缘合成生成的**派生产物**，不能当作高清原图使用。

取得高清原图后：替换对应 WebP（保持文件名），重新运行上述脚本即可全量
刷新两个工程的图标，无需手改任何 Xcode 配置。
