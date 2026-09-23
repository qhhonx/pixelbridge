PixelBridge 0.1.0-beta.22 — 恢复部分损坏 HEVC 实况照片的视频。

Apple 转换器拒绝 HEVC 配对视频时，安装了 FFmpeg 的 Mac 会尝试容错恢复。只有照片与视频配对标识一致、至少 80% 的帧可恢复且生成的视频完整可解码，才会合成动态照片并传输。拍摄时间取自原始配对视频；静态照片和 PhotoKit 原件不变。恢复过程可能略过无法解码的帧。

已上传的文件不会自动重传。PixelBridge 的“已传到 Pixel”仍表示设备端文件校验通过，Google Photos 云端备份由 Google Photos 独立完成。
