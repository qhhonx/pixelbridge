# PixelBridge

[English](README.md) · [下载](https://github.com/qhhonx/pixelbridge/releases) · [官网](https://pixelbridge-app.vercel.app)

通过 Mac 将 Apple 照片原件传到 Google Pixel，再由 Google Photos 完成第二份备份。

**Beta 验证阶段。需要 Apple Silicon Mac、macOS 14 或更高版本。**

源码已按 MIT 协议开放。可从 Releases 下载最新发布的测试版，或按照下方说明自行构建。 安装包使用临时签名，**未经 Apple 公证**。

## 解决什么问题

保留 Apple 照片和 iCloud 的日常使用方式，同时持续建立 Google Photos 备份。支持 iCloud“优化 Mac 存储空间”、新增照片发现、批量传输、失败重试、断点续传和本地缓存回收。支持的动图会封装为包含照片与视频的一个动态照片文件；图库以图标表示类型和传输状态。界面支持中英文，默认跟随系统语言。

照片路径：**Apple 照片 / iCloud → Mac → Pixel → Google Photos**。PixelBridge 不提供接收照片的云端服务器。

## 安装与使用

1. 从 [Releases](https://github.com/qhhonx/pixelbridge/releases) 下载 `PixelBridge-…-arm64.zip`，解压后将 App 移到“应用程序”。
2. 尝试打开。若 macOS 拦截且你信任下载来源，前往 **系统设置 → 隐私与安全 → 仍要打开**并确认。参阅 [Apple 官方说明](https://support.apple.com/en-us/102445)。不要关闭系统整体安全保护。受管理的 Mac 可能限制此操作；更新后可能需要重新允许打开或授予照片权限。
3. 允许读取照片库，通过 USB 连接 Pixel，启用 USB 调试并在手机上授权。没有 ADB 时，可通过 App 引导安装；需自行接受 Google 的工具条款。
4. 在 Pixel 上登录 Google Photos 并启用备份，核对账号存储权益与备份画质。
5. 先备份少量照片，检查手机和网页上的照片与动态播放效果，再启用自动备份。

传输期间需要 Mac 保持唤醒、Pixel 保持连接，并保证网络可用。关闭窗口后 App 仍在菜单栏运行，退出 App 则停止调度。旧手机应保持通风并注意电池状况。

## 状态、空间与限制

- **已传到 Pixel，不等于已备份到 Google Photos。** Google Photos 独立上传，动态视频也可能稍后才完成处理。
- Mac 缓存回收会先保存进度，再重新校验 Pixel 上的对应文件；不删除照片库原件、手机文件或 State 进度。
- 可在实验功能中启用自动释放 Pixel 空间。程序调用 Google Photos 的“释放此设备的空间”，由 Google Photos 筛选已安全备份的文件，无需等待全部上传完成。清理期间暂停新增传输，确认清理结束且空间足够后再恢复；不会直接删除照片目录。
- 读取的是未修改原件。支持的 JPEG／HEIC 连拍会在独立传输副本中添加分组和封面信息，不重新编码图像像素，也不修改 Apple 原件。不同步相册结构、编辑效果或删除操作，也不保证覆盖所有媒体格式。
- 不同照片库的标识可能不同，换图库可能重复传输；不要删除 State 目录。大型图库长期无人值守运行仍属于 Beta 验证范围。
- Pixel 存储权益以[官方政策](https://support.google.com/pixelphone/answer/6220791)和实际账号为准。

## 自动更新

菜单 **PixelBridge → 检查更新…**、菜单栏或偏好设置中均可检查更新。默认自动检查，安装时由你决定。更新重启前会暂停备份并等待当前任务收尾。

Sparkle 使用独立的 Ed25519 签名校验更新包，**这不是 Apple 公证**。Beta 会接收后续完整发布的版本，包括新的 Beta。更新服务不可用时仍可从 Releases 手动下载；不会发送系统分析信息。

## 开发与发布

构建与测试见 [English README](README.md#build-from-source)。构建固定依赖版本并校验摘要，不依赖个人电脑的实验目录。推送 main 后自动检查并打包；公开仓库并明确启用发布后，递增版本号和构建号再推送，才会自动发布对应版本并更新下载与升级入口。官网由 Vercel Git 集成部署。

项目代码采用 MIT 许可证，第三方组件保留各自许可证。详见[第三方声明](THIRD_PARTY_NOTICES.md)、[发布说明](docs/RELEASING.md)、[隐私说明](docs/PRIVACY.md)。项目与 Apple 或 Google 无关联。

## 实况照片与连拍

实况照片保留动态，连拍保留整组瞬间。PixelBridge 将支持的实况照片封装为动态照片，并为连拍副本保留分组与代表帧信息。每帧独立传输与校验，Apple 原件保持不变。JPEG 分组已在 Pixel 和 Google Photos 网页验证，HEIC 云端效果仍待验证。
