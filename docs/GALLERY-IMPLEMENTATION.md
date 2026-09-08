# 图库加载与显示

## 数据与分页

`BridgeModel.scan()` 在后台读取 PhotoKit 全库元数据，按拍摄时间倒序建立 `LibraryItem` 索引及媒体分类数组。索引包含稳定 ID、日期、媒体类型及修改时间，不包含照片原件。首次会建立完整索引，因此当前是展示分页，不是 PhotoKit 查询分页。

`PhotoGrid` 使用 `NSViewRepresentable` 承载 `NSScrollView + NSCollectionView`。首次向 collection 提供 200 个项目，距已加载内容底部 800 pt 内时追加 200 个项目。使用 `insertItems`，不为了翻页重建整个列表。筛选类型时重新从 200 项开始；全部加载后显示完成文案。照片库变更通知、手动刷新及十分钟兜底扫描更新索引。

## Cell 复用

- 注册 `PhotoCell`，通过 `makeItem(withIdentifier:for:)` 由 AppKit 创建或复用 cell。
- `configure` 取消前一个请求、清空图像、绑定新的 asset ID，再请求缩略图。
- `didEndDisplaying` 取消不再可见单元的任务及 PhotoKit 请求；`prepareForReuse` 再清理图片与身份。
- 请求回调同时检查 ticket 是否已取消和 cell 的 asset ID，防止滚动复用时旧照片回调覆盖新照片。
- 图片直接交给 `CALayer` 做 aspect-fill 显示；更新内容时关闭隐式动画。
- 状态变化只更新可见 cell 的图标/标签，不调用 `reloadData`，也不重新下载缩略图。

## 缩略图策略

1. 以 asset ID 和尺寸档位查 `NSCache`。照片图像缓存的 countLimit 为 500，totalCostLimit 为 128 MiB；PHAsset 对象缓存 countLimit 为 1,200。它们是 NSCache 回收参考值，不是 App 总内存的硬上限，也没有承诺严格 LRU。
2. 未命中时，后台取得 PHAsset，再向共享 `PHCachingImageManager` 请求缩略图。
3. 根据传入 tileSize × 屏幕缩放比例选择宽 320 或 640 像素两档，高度为宽度 / 1.37；`.aspectFill` 裁剪填充。
4. `.opportunistic` 允许先返回快速低清结果，再返回本地更清晰结果；`.fast` resize 允许近似目标大小。只有非 degraded 结果放入图像缓存。后续空结果不会清除已显示预览。
5. `isNetworkAccessAllowed = false`：浏览图库不触发 iCloud 原件下载。本地没有可用缩略图时保留占位。备份原件下载由独立流程负责。
6. `ThumbnailTicket.cancel()` 取消 Swift Task 和 PhotoKit request，失效回调不能更新复用后的 cell。

当前尚未主动调用 `startCachingImages` 做视口前后预热，也没有合并同一照片的并发请求。图库 revision 改变或图库视图重建时会整体清空缩略图缓存；这比逐个失效简单，但切换页面或图库更新后会损失一部分缓存命中。元数据索引和已加载项目布局仍会随图库/浏览深度增长，因此不能把 cell 复用理解成所有内存和布局开销都为常量。

## 图标与偏好

默认只显示 SF Symbols。普通静态照片不加类型标记；动图为 `livephoto`，视频为 `play.fill`。

| 状态 | SF Symbol |
|---|---|
| 未传输 | `clock` |
| 正在处理 | `arrow.triangle.2.circlepath` |
| 已加入重试 | `arrow.clockwise` |
| 失败、等待重试 | `exclamationmark.circle.fill` |
| 已传到 Pixel | `checkmark.circle.fill` |
| 已有云端确认记录 | `checkmark.icloud.fill` |

图标形状和颜色共同表达状态，类型在左上角，状态在右下角。悬停与 VoiceOver 保留完整语义。“偏好设置 → 显示图标文字”通过 AppStorage 持久保存，即时生效，不重新加载图片或修改备份队列。云图标只用于已有云端确认的记录；传到 Pixel 不会显示成云端已完成。App 不会自动核验云端备份。
