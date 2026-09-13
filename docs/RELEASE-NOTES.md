PixelBridge 0.1.0-beta.17 — 避免单张照片阻塞备份。

- 单张处理停滞时延后重试，继续备份其他照片，并保留已完成进度。
- 新增“卡住时自动重启”设置，默认关闭。开启后，仅在取消无效时恢复应用，最多每小时一次。
- 增加处理阶段记录，便于定位卡顿。

Stalled photos now retry later without blocking the remaining queue. Optional automatic restart recovery is off by default, limited to once per hour, and preserves completed transfers. Processing stages are recorded for diagnostics.

Apple Silicon · macOS 14+. Use **Check for Updates** in PixelBridge or download the arm64 ZIP. Free beta, ad hoc signed and not notarized by Apple.
