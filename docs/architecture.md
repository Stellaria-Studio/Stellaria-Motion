# Stellaria Motion Architecture

更新时间：2026-06-14

本文档是架构速览。详细技术解析见 `docs/Stellaria Motion 技术报告.md`。

## 1. 模块分层

- `Sources/App`
  - macOS App 外壳、三栏 UI、播放器控制、设置持久化、离线导出入口。

- `Sources/Core`
  - 数据契约、RenderGraph、质量策略、实时 pacing 配置、浏览器协议解析、轻量 profiler。

- `Sources/Metal`
  - Metal shader 库与基础 runtime。
  - 关键 kernel 包括 fused 插帧、RIFE pack/unpack、INT4 flow/mask、INT4 blend、SP4 prepared flow/mask、SP4 blend/refine 与输出保护。

- `Sources/Video`
  - 本地播放器实时插帧。
  - 离线 AVAssetReader / AVAssetWriter 导出。
  - ScreenCaptureKit fallback。
  - CVPixelBuffer / IOSurface / CVMetalTextureCache 边界。

- `Sources/VFI`
  - 可替换插帧后端。
  - 当前包含 MPSGraph RIFE、Core ML RIFE、Metal INT4、Stellaria SP4 SDK A1P。

- `Sources/BrowserAgent`
  - Google Chrome extension 与 Native Messaging host。
  - 实验性浏览器桥接、状态同步和诊断入口。
  - 浏览器实时回推不是当前稳定产品主路径。

- `Tests`
  - Core 行为测试。
  - 本地播放器 AVPlayerItemVideoOutput smoke。
  - 离线导出 smoke。
  - MPSGraph / INT4 / SP4 GPU smoke。
  - 实时 pacing smoke。

## 2. 本地播放器实时路径

```text
Local video URL
  -> AVPlayerItem
  -> AVPlayerItemVideoOutput
  -> CVPixelBuffer BGRA
  -> CVMetalTextureCache
  -> previous/current MTLTexture
  -> selected VFI backend
  -> displayMid/displayNext texture queue
  -> CAMetalLayer
```

该路径是当前优先级最高的产品路径。它的关键点是：播放器画面不是额外预览窗口，而是由插帧后的 `CAMetalLayer` 覆盖播放器区域，从而让本地导入视频的主播放画面被增强结果替换。

## 3. 后端矩阵

| UI 名称 | backend id | 代码路径 | 说明 |
| --- | --- | --- | --- |
| 基础插帧 | `fused_basic` | `fused_bgra_interpolate_lanczos_present` | 低依赖 fallback |
| RIFE兼容 | `mpsgraph_fp16_target` | `RIFEMPSGraphRunner` | 参考 RIFE 兼容路径 |
| RIFE加速 | `metal_int4_experimental` | `RIFEMetal4BitRunner` | 手写 Metal INT4 flow/mask |
| RIFE加速增强 | `stellaria_sp4_a1p` | `RIFESP4Runner` | SP4 SDK `.sp4` asset + Metal flow/mask + residual refine |

本地播放器中的默认后端是 `stellaria_sp4_a1p`。SP4 失败时会退回 INT4，再退回 MPSGraph RIFE，最后可回到 fused basic。

## 4. INT4 / SP4 GPU 路径

INT4：

```text
safetensors F32 weights
  -> runtime Q4 packing
  -> q4WeightPool / scalePool / biasPool / layerDescBuffer
  -> rife_metal4_int4_flow_mask
  -> rife_metal4_blend_flow_bgra
```

SP4 SDK A1P：

```text
Stellaria SP4 SDK rife_sp4_a1p.sp4
  -> qweight / scaleFp16 / mode / aux / sparse residual
  -> PrepareRuntimeCache hot-layer FP16 cache
  -> rife_sp4_prepared_flow_mask
  -> rife_metal4_blend_flow_bgra
  -> rife_sp4_a1p_residual_refine_bgra
  -> output texture
```

当前 SP4 已经使用 SDK `.sp4` container 与 runtime metadata，并支持 single command-buffer 多 t presentation 复用第一次 flow。当前代码中的 SP4 实时档位为 60fps: 360p/432p/540p，120fps: 288p/360p/432p；更高 flow height 仅在 Ultimate 手动或离线/质量实验场景使用。

Motion 侧的 SP4 接入消费 Stellaria SP4 SDK 的 A1P asset、loader 与 runtime cache metadata；它不是另起一套独立的 Motion-only SP4 格式。公开源码不包含模型权重或本地 SDK 构建产物，发布包只在存在可用资源时打包对应资产。

## 5. 浏览器回推路径

```text
Browser video element
  -> Chrome extension / native host
  -> native bridge metadata or frame payload
  -> selected VFI backend
  -> experimental browser overlay / return path
```

浏览器路径仅作为 Chrome 兼容实验保留。开发过程中已经确认，直接从浏览器读帧、进 App 插帧、再回推到页面的链路容易受到浏览器 compositor、帧读取抖动、编码/回推队列和音画同步影响。当前稳定产品方向是本地/缓存媒体进入原生播放器后再插帧；浏览器桥主要用于诊断和兼容测试。

## 6. 离线导出路径

```text
AVAssetReader
  -> BGRA CVPixelBuffer / IOSurface
  -> CVMetalTextureCache
  -> RIFESP4Runner when SP4 assets are available
  -> fused_bgra_interpolate_lanczos_present fallback
  -> Core Image mix/upscale fallback
  -> AVAssetWriterInputPixelBufferAdaptor
  -> MP4
```

当前离线链路已经接入 `RIFESP4Runner`，优先复用实时播放的 SP4/RIFE 路径生成中间帧。若 SP4 asset、Metal texture cache 或 runtime 执行不可用，导出会降级到 fused Metal 插帧；如果 Metal 路径也不可用，则使用 Core Image 线性混合与上采样兜底。离线导出不承担实时功耗预算，因此是质量优先路径，同时保留可完成导出的稳定 fallback。

## 7. 运行时 pacing

实时路径把输入帧拉取和输出显示拆开：

- input side：从 AVPlayerItemVideoOutput 或浏览器 bridge 获取源帧。
- processing side：生成 `displayMid` 和 `displayNext`。
- output side：display timer 按目标 FPS 推进 `CAMetalLayer`；浏览器实验路径另行维护自己的 overlay/return 时钟。

这样可以避免模型输出迟到时回拨播放相位。插帧结果迟到时会被跳过或 fallback，而不是破坏播放器时间轴。

## 8. 验证入口

常用验证命令：

```bash
cmake -S . -B build-app
cmake --build build-app --target StellariaMotionApp MotionOfflineProcessorSmoke RealtimeVFITestCLI -j 8
ctest --test-dir build-app --output-on-failure
```

关键测试：

- `LocalPlayerVideoOutputSmoke`
- `RIFEMetal4BitSmoke`
- `RIFEMetal4BitPerfSmoke`
- `RIFESP4Smoke`
- `RealtimeVFIPacingSmoke`
- `MotionOfflineProcessorSmoke`
