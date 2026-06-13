# Stellaria Motion 技术报告

更新时间：2026-06-09

本文档描述 Stellaria Motion 当前真实实现状态。它不是产品宣传稿，也不是未来路线图的集合；所有“已实现”描述均对应当前仓库中的代码路径。仍处于实验或预览状态的能力会明确标注。

## 1. 项目定位

Stellaria Motion 是面向 Apple Silicon 的本地视频实时插帧与离线导出原型。当前优先级已经从早期的浏览器视频回推，转向本地视频导入后的实时增强播放器体验。

当前核心目标有三个：

1. 本地视频导入后，播放器画面本身被插帧结果替换。
2. 在 60fps 目标下，把实时链路延迟控制在 16.67ms 预算内。
3. 通过手写 Metal、INT4 量化与 Stellaria SP4 SDK 后端，在可控延迟内验证低比特推理和画面稳定性。

当前主路径不是 Python、PyTorch 或外部推理服务，而是 macOS 原生媒体栈：

```text
AVFoundation / VideoToolbox / ScreenCaptureKit
-> CVPixelBuffer / IOSurface
-> CVMetalTextureCache
-> Metal / MPSGraph / Core ML / SP4 runner
-> CAMetalLayer / VideoToolbox encoder / AVAssetWriter
```

## 2. 当前产品界面分层

App 当前分为三栏：

1. 播放器
   - 本地视频导入。
   - AVPlayer 控制与自定义播放器控制。
   - 实时插帧输出覆盖播放器画面。
   - 支持播放/暂停、进度拖动、音量、倍速、循环、前后跳转。

2. 离线导出
   - AVAssetReader 读本地视频。
   - Metal kernel 生成中间帧或增强帧。
   - AVAssetWriter 输出文件。
   - 离线参数与实时播放参数分离。

3. 设置
   - 浏览器回推相关设置已经归入设置页。
   - 后端选项集中在模型与回传区域。
   - 当前后端命名为：
     - 基础插帧
     - RIFE兼容
     - RIFE加速
     - RIFE加速增强

UI 中刻意减少了内部性能壁垒和实现细节的展示。面向用户的界面不再强调 INT4、kernel 数量、pipeline 细节或具体 ms 门槛；这些内容保留在开发日志、测试输出和本文档中。

## 3. 四个实时后端

设置页中的四个后端对应不同的 runtime payload。

| UI 名称 | runtime backend | 当前实现 | 主要用途 |
| --- | --- | --- | --- |
| 基础插帧 | `fused_basic` | 手写 Metal 差帧/运动搜索/边缘保护 | 最低依赖、低功耗 fallback |
| RIFE兼容 | `mpsgraph_fp16_target` | RIFE safetensors 经 MPSGraph 固定形状推理 | 兼容参考模型路径 |
| RIFE加速 | `metal_int4_experimental` | 手写 Metal INT4 量化 flow/mask + warp/blend | 追求低延迟实时路径 |
| RIFE加速增强 | `stellaria_sp4_a1p` | Stellaria SP4 SDK `.sp4` asset + Metal SP4 flow/mask + residual refine | 默认增强后端，首个 SP4 SDK 参与项目 |

默认后端已经迁移到 `RIFE加速增强`。代码中对应设置位于 `currentRuntimeSettingsPayload`，本地播放器通过 `startLocalPlaybackWithPlayer:item:... modelMode:` 传入 `SMMotionOnlineProcessor`。

## 4. 本地播放器实时链路

本地播放链路是当前第一优先级。

```text
用户导入本地视频
-> AVPlayer / AVPlayerItem
-> AVPlayerItemVideoOutput
-> copyPixelBufferForItemTime
-> CVMetalTextureCacheCreateTextureFromImage
-> previous/current BGRA texture
-> 后端生成中间帧
-> CAMetalLayer 显示增强画面
```

### 4.1 为什么使用 AVPlayerItemVideoOutput

早期如果只使用 `AVPlayerView`，播放器展示的是 AVFoundation 自己渲染出的原始视频画面。即使旁路里有插帧推理，也只能在外部预览层看到结果，不能严格说“播放器画面本身被插帧替换”。

当前实现将 `AVPlayerItemVideoOutput` 接入 `AVPlayerItem`，并请求 BGRA、Metal compatibility 与 IOSurface：

```text
kCVPixelFormatType_32BGRA
kCVPixelBufferMetalCompatibilityKey = YES
kCVPixelBufferIOSurfacePropertiesKey = {}
```

这样每个视频帧都能转换成 `id<MTLTexture>`，进入同一套后端处理链路。播放器区域上方有专用 `CAMetalLayer`，插帧结果写入这个 layer，原始 `AVPlayerView` 的显示仅作为解码、时间轴和控制来源。

### 4.2 首帧与闪烁控制

本地视频第一次打开时容易出现抽搐或闪烁，原因通常不是模型本身，而是显示层和输出层启动顺序不稳定：

1. `AVPlayerView` 已经开始显示原始帧。
2. `AVPlayerItemVideoOutput` 还没有稳定产出新 pixel buffer。
3. Metal overlay 尚未拿到第一张增强帧。
4. 两个显示源短时间内交替可见。

当前处理方式：

- `AVPlayerItemVideoOutput` 先挂到 item。
- `CAMetalLayer` 初始化为 opaque black，避免透明闪烁。
- overlay 初始隐藏。
- 只有当 `rifeFrames > 0`，也就是真实后端已经产出增强帧后，才把增强画面作为有效播放状态展示。
- 切设置再回来后正常的现象，本质上说明第二次进入时 layer / output / model cache 已经热起来；现在启动顺序已经按这个规律做了收敛。

### 4.3 帧调度

本地播放器有两类 timer：

1. local frame timer
   - 通过 `itemTimeForHostTime` 查询当前播放时间。
   - 使用 `hasNewPixelBufferForItemTime` 避免重复取同一帧。
   - 拉取新的 `CVPixelBuffer` 后进入 `consumePixelBuffer`。

2. display timer
   - 按目标 FPS 驱动 `CAMetalLayer` 呈现。
   - 在一对源帧之间维护 current / mid / next 三张 texture。
   - 当 phase 进入中间区间时显示插帧结果，接近末尾时推进到下一源帧。

这套逻辑把“解码帧到达节奏”和“显示器刷新节奏”分开处理。后端只需要对相邻源帧生成中间帧，呈现层负责稳定替换播放器画面。

## 5. Metal INT4 后端

`RIFEMetal4BitRunner` 是当前低延迟 RIFE 加速路径。

### 5.1 模型加载

运行时读取 `Models/RIFE-safetensors/flownet.safetensors`，解析 safetensors header，按 RIFE block 中的卷积权重生成量化数据：

```text
F32 weight tensor
-> per-output-channel maxAbs
-> scale = maxAbs / 7
-> signed int4 weight packing
-> q4WeightPool / scalePool / biasPool / layerDescBuffer
```

当前打包方式是运行时加载阶段完成，不依赖 Python。权重池上传到 Metal private buffer，推理阶段不再读取原始 F32 权重。

### 5.2 shader 路径

INT4 后端使用两个主要 kernel：

```text
rife_metal4_int4_flow_mask
-> 低分辨率模型空间估计 flow + mask

rife_metal4_blend_flow_bgra
-> 将 flow/mask 双线性采样回源分辨率
-> previous/current 反向采样
-> mask blend
-> 少量 native blend 稳定细节
```

其中 `rife_metal4_int4_flow_mask` 执行手写 int4 unpack、scale restore 与简化 IFBlock 风格特征提取。它不是完整通用神经网络运行时，而是为 RIFE 视频插帧任务定制的 Metal ALU 路径。

### 5.3 尺寸策略

实时 INT4 路径不会直接在 1080p/4K 上做完整模型计算，而是选择较低模型高度：

```text
预算 <= 8ms       -> 144p 级模型高度
预算 <= 16.67ms   -> 192p 级模型高度
更高预算          -> 216p 级模型高度
```

模型宽度按源视频比例对齐到 16 的倍数。输出仍然是源分辨率，flow/mask 通过 shader 采样回源尺寸。

这种设计牺牲了部分复杂运动场景的模型细节，但换来极低的模型计算成本和稳定的实时预算。

## 6. Stellaria SP4 SDK 后端

SP4，全称 Stellaria Split Precision 4，是 Stellaria 面向实时视觉推理设计的 4-bit 分离精度量化体系。当前仓库已经从早期 `INT4 + heuristic residual refine` 预览，推进到正式接入 `/Users/minsawa/Documents/Stellaria SP4` SDK 的 `.sp4` 资产运行路径。Stellaria Motion 是这个 SDK 的首个参与项目。

### 6.1 SP4 的核心思想

SP4 不等同于普通 INT4，也不是单纯 weight-only quantization。它的目标是把低精度推理拆成两部分：

```text
INT4 / INT8 主路径：
  负责主要计算量、主要压缩率和主要运行效率。

FP16 校正路径：
  负责动态范围恢复、敏感区域保护、残差修正和时序稳定。
```

理论表示可以写成：

```text
Y ~= scale_w_fp16 * scale_a_fp16 * dot(Qw_int4, Qa_int8)
   + residual_correction_fp16
```

当前 A1P 版本已经具备 SDK 工具链参与：

```text
Stellaria SP4 SDK
-> build/rife_sp4_a1p.sp4
-> sp4::LoadAsset
-> qweight / scaleFp16 / mode / aux / residual table
-> Metal private buffers
-> rife_sp4_sdk_flow_mask
-> rife_metal4_blend_flow_bgra
-> rife_sp4_a1p_residual_refine_bgra
-> 输出增强帧
```

### 6.2 当前 SP4 A1P 实现

`RIFESP4Runner` 当前直接链接 SDK target `sp4sdk`，并包含：

1. `sp4/SP4Runtime.h`
   - 使用 `sp4::LoadAsset` 读取 `.sp4` container。
   - 读取 manifest、layer desc、qweight、scale、mode、aux、sparse residual。

2. `sp4/SP4Compiler.h`
   - 如果传入的是 safetensors 且本地没有 `.sp4`，可以调用 `sp4::CompileSafetensorsToSp4` 生成 `Models/RIFE-SP4/rife_sp4_a1p.sp4`。

3. CMake SDK 接入
   - `STELLARIA_SP4_SDK_DIR` 默认指向 `/Users/minsawa/Documents/Stellaria SP4`。
   - 若 SDK 存在，则 `add_subdirectory(... EXCLUDE_FROM_ALL)` 引入 `sp4sdk`。
   - App bundle 会复制 `rife_sp4_a1p.sp4` 到 `Contents/Resources/Models/RIFE-SP4/`。

4. Runtime buffer 上传
   - `qweightBuffer`
   - `scaleBuffer`
   - `modeBuffer`
   - `auxBuffer`
   - `residualIndexBuffer`
   - `residualValueBuffer`
   - `residualTableBuffer`
   - `layerPlanBuffer`

5. Metal kernel
   - `rife_sp4_sdk_flow_mask` 按 SDK layer plan 解码 SP4 block。
   - 支持 signed int4、zero point、codebook、learned codebook 与 sparse FP16 residual。
   - 输出与 INT4 runner 相同布局的 flow/mask buffer，因此能复用 `rife_metal4_blend_flow_bgra`。
   - `RunTexturesAtT(..., t)` 已经把 `t` 传入 flow/mask 和 refine pass，可参与 24fps 到 60fps 的多 t presentation。

residual refine shader 仍会读取：

```text
previousFrame
currentFrame
sp4Frame
```

然后计算：

- previous/current/main 的局部亮度边缘。
- main 与 native midpoint 的亮度偏差。
- previous/current 的运动幅度。
- overshoot / undershoot guard。

敏感度越高，residual 权重越高，但上限受控。它的作用不是把结果退回普通线性混合，而是在可能产生边缘错误、亮度跳变或时序不稳的位置做小幅修正。

### 6.3 当前 SDK 资产

当前接入的 SDK 资产为：

```text
/Users/minsawa/Documents/Stellaria SP4/build/rife_sp4_a1p.sp4
```

`sp4inspect-cpp` 读取到的资产摘要：

```text
adapter=rife version=A1P layers=42
qweight_bytes=1136880
scale_count=35907
mode_count=35907
residual_entries=60996
first_layer=block0.conv0.0.0.weight
blocks=140 block_size=32
```

这说明当前路径已经不再是“仅有 SP4 名称的 refine pass”，而是实际使用 SDK container、block mode 和 sparse residual metadata。

### 6.4 当前性能边界

SDK 后端已经接入，并已针对 Stellaria Motion 的 RIFE 实时工况增加第一轮高性能调度：

- SDK 新增 `PrepareRuntimeCache`，把热点层的 SP4 block、codebook、zero-point 和 sparse residual 预展开为连续 FP16 dequant cache。
- Motion 新增 `rife_sp4_prepared_flow_mask`，运行时优先走 prepared cache，避免每个像素重复解码相同权重。
- SP4 runner 新增 `RunTexturesAtTValues`，24fps 到 60/120fps 的多个 t 子帧会复用第一次 flow，并在同一个 command buffer 中顺序编码，批尾只同步一次。
- SP4 presentation 已将 flow blend、edge/temporal guard 和 residual refine 合成单个 `rife_sp4_a1p_blend_refine_flow_bgra` kernel，避免满分辨率中间纹理写回。
- 旧的 `.sp4` 直接解码路径仍保留为 fallback。

在 `/Users/minsawa/Downloads/test.mov` 复制到 `Tests/Media/test.mov` 后，完整视频 CLI 的实测边界为：

| 模型高度 | 模型尺寸 | 典型 median | 结论 |
| --- | --- | ---: | --- |
| 360 multi-t / 60fps | 864x368 | 6.86ms | 安静档实时兜底 |
| 432 multi-t / 60fps | 1008x432 | 8.87ms | 均衡档默认 |
| 544 multi-t / 60fps | 1280x544 | 12.01ms | 质量档默认 |
| 360 multi-t / 120fps | 864x368 | 7.16ms | 120fps 均衡档 |
| 432 multi-t / 120fps | 1008x432 | 8.62ms | 120fps 质量档边界 |

最新完整视频测试中，SP4 544p 60fps multi-t 在 `Tests/Media/test.mov` 上生成 480 个插帧，median 12.01ms，p95 14.19ms，`enhanced_media_fps` 为 59.85。SP4 432p 120fps multi-t 会为 24fps 源帧对生成 4 个 t 输出，median 8.62ms，p95 10.35ms，`enhanced_media_fps` 为 119.60。播放器 UI 因此改为固定 60/120fps 选择，且 120fps 仅在 `RIFE加速增强` 后端可用；旧的目标 FPS、帧生成倍率和动态多帧开关不再暴露。

### 6.5 下一步 SP4 executor

本轮已经完成：

- block 级 dequant cache，避免热点层在每个像素重复解码。
- sparse residual 预折叠到 prepared FP16 cache。
- 多 t presentation 共享第一次 SP4 flow，24fps 到 120fps 时可输出 4 个 t 子帧。
- 多 t 输出进入同一个 command buffer，减少 CPU/GPU 同步边界。
- blend/refine/guard 合并到单个 presentation kernel。

后续要让 SP4 SDK 后端稳定覆盖更高质量的 720p flow，还需要继续推进：

- 将 prepared cache 从前三个热点层扩展为真正的 graph/tile executor。
- 将 flow rescale 与 presentation 在后续 executor 中进一步合并，减少第二个子帧的 command encoder。
- 把 command-buffer batch 从 Motion runner 上升为 SP4 backend scheduler 的默认执行策略。
- 建立 backend scheduler，根据模型高度、目标 FPS、p95 长尾和电源状态自动选择 prepared/direct/fallback。
- 对 SP4/INT4 的首帧加载、steady-state、p95/p99 长尾分别记录。
## 7. RIFE 兼容后端

`RIFE兼容` 使用 `RIFEMPSGraphRunner`，保留参考 RIFE safetensors 的兼容推理能力。

链路如下：

```text
previous/current BGRA texture
-> pack_bgra_pair_to_rife_input
-> MPSGraph RunWithBuffers
-> unpack_rife_output_to_bgra
-> output texture
```

这个路径的优势是模型语义更接近参考 RIFE。缺点是固定输入形状、图执行和 buffer/tensor 边界会带来较明显同步成本。它更适合作为质量参考、兼容 fallback 和调试基线，而不是当前默认实时路径。

## 8. Core ML / ANE 路径

仓库中仍保留 Core ML runner：

- `RIFECoreMLRunner`
- `RIFECoreMLFlowMaskRunner`
- `RIFECoreMLBlockRunner`

这些 runner 使用 NHWC MultiArray 输入输出，并通过 `MLPredictionOptions.outputBackings` 尽量让 Core ML 输出写入预分配 backing，减少推理后 CPU copy。此前浏览器路径出现卡顿和闪烁时，一个关键原因就是推理输出回读或同步边界过重；因此 Core ML 路径的优化重点一直是 output backing 和呈现同步。

当前默认实时播放器不优先走 Core ML/ANE 路径。它仍作为实验后端资产和浏览器桥中的备用能力存在。

## 9. 浏览器回推链路

虽然当前优先级转向本地播放器，浏览器回推仍保留。

```text
Google Chrome content script
-> captureStream / WebCodecs / WebSocket
-> native stream bridge
-> VideoToolbox decode
-> Metal / RIFE / SP4
-> VideoToolbox encode
-> browser canvas overlay
```

浏览器 JavaScript 只负责：

- 发现主视频元素。
- 同步播放、暂停、进度、尺寸和可见区域。
- 发送视频帧或 metadata。
- 接收增强帧并绘制覆盖层。

本地 bridge 负责：

- 解码 H.264/HEVC。
- 创建 Metal texture。
- 调用后端。
- 硬编输出。
- 管理 direct source reader 与回推时钟。

当前 browser bridge 已经支持 `stellaria_sp4_a1p`，并维护独立的 SP4 runner cache。若 SP4 失败，会尝试回退到 INT4，再回退到兼容路径或 fused。

## 10. 离线导出链路

离线导出仍然是独立页面和独立设置。当前稳定链路是：

```text
AVAssetReader
-> BGRA CVPixelBuffer
-> CVMetalTextureCache
-> fused_bgra_interpolate_lanczos_present
-> AVAssetWriterInputPixelBufferAdaptor
-> MP4
```

离线导出的定位与实时播放不同：

- 不需要严格受 16.67ms 单帧预算约束。
- 更适合未来接入高质量 RIFE / SP4 多 pass。
- 可以允许更高 flow height、更多 refine 和更强保护。

当前离线 smoke 已覆盖真实 AVAssetReader 到 AVAssetWriter 的 2x/60fps MP4 输出。后续应将 SP4/RIFE 后端接入离线路径，但不能破坏现有 fused export 的稳定性。

## 11. 呈现与时序策略

实时体验的关键不是单帧模型耗时，而是端到端时序稳定。

### 11.1 为什么只看 GPU 功耗不够

播放时 GPU 功耗只有 2W，并不能单独证明插帧没有运行。可能情况包括：

- 模型输入高度很低，INT4/SP4 shader 成本很小。
- 视频分辨率较低或运动较少。
- 当前只生成每对源帧的一张中间帧。
- Metal pass 很短，系统功耗采样窗口看起来不高。
- 后端已经命中 cache，没有模型加载长尾。

判断是否真的跑在插帧上，应看：

- `rifeFrames` 是否持续增长。
- `generatedFrames` 是否增长。
- overlay 是否在 `rifeFrames > 0` 后显示增强画面。
- `gpuMs` 是否有非零稳定值。
- `RIFESP4Smoke` / `RIFEMetal4BitPerfSmoke` 是否通过。
- Instruments Metal System Trace 中是否出现对应 compute kernel。

### 11.2 可变多 t presentation

当前实时后端会根据 `targetFPS * sourceFrameDuration` 自动决定每对源帧需要几个中间 t。

```text
30fps -> 60fps:   1 个 t，通常 t=0.5
24fps -> 60fps:   2 个 t，按 2/3 槽位交替呈现
30fps -> 120fps:  3 个 t，t=0.25/0.5/0.75
24fps -> 120fps:  4 个 t，t=0.2/0.4/0.6/0.8
```

SP4 runner 会把同一对源帧的多个 t 输出放进一个 command buffer，并复用第一次 flow。播放器 presentation 使用 generation-owned texture 数组，完成后再原子切换到显示端，避免部分帧集、闪烁和显示端/生成端纹理竞争。

### 11.3 fallback 顺序

本地 SP4 后端的 fallback 顺序：

```text
SP4 A1P
-> Metal INT4
-> MPSGraph RIFE
-> fused basic
```

这样做的原因是：默认后端可以更激进，但播放器不能因为模型或 shader 某一步失败而黑屏。

## 12. 质量保护

当前质量保护分为三层。

1. 模型侧保护
   - INT4 flow/mask 输出后做 native blend。
   - SP4 residual refine 对边缘、亮度误差和运动区域做小幅校正。

2. shader 侧保护
   - fused kernel 里有局部运动搜索和边缘回混。
   - unpack / blend 阶段避免过度依赖低分辨率模型输出。

3. 时序侧保护
   - 中间帧迟到时不回拨显示相位。
   - 缺少完整多帧集时不使用部分 multi-t 输出。
   - 暂停、seek、首次加载时优先保证原生播放器状态稳定。

## 13. 当前测试与验证

建议每次修改实时后端、Metal shader 或播放器路径后至少运行：

```bash
cmake -S . -B build-app
cmake --build build-app --target StellariaMotionApp RIFESP4Smoke RealtimeVFITestCLI -j 8
ctest --test-dir build-app -R 'RIFESP4Smoke|RealtimeVFITestCLI|RIFEMetal4BitSmoke|LocalPlayerVideoOutputSmoke|RealtimeVFIPacingSmoke' --output-on-failure
```

各测试覆盖：

- `LocalPlayerVideoOutputSmoke`
  - 验证 `AVPlayerItemVideoOutput` 可用于本地播放器帧流接入。

- `RIFEMetal4BitSmoke` / `RIFEMetal4BitPerfSmoke`
  - 验证 INT4 runner 能加载 safetensors、创建 Metal buffers、执行 flow/mask 和 blend。
  - perf smoke 会对 640x360、1080p、1440p 输出做基本 p95 约束。

- `RIFESP4Smoke`
  - 验证 SP4 runner 能链接 SDK、加载 `.sp4` asset、上传 SP4 buffers、执行一帧输出。

- `RealtimeVFIPacingSmoke`
  - 验证实时 VFI session 的 pacing 配置不会回退。

最近一次 SP4 smoke 的示例输出：

```text
RIFE SP4 smoke 256x144 -> 640x360 elapsed=2.89758ms
```

该数字只代表 smoke 场景，不代表所有视频、所有分辨率、所有系统功耗下的正式性能承诺。

## 14. 当前限制

1. SP4 SDK 已接入，但 executor 仍在扩大 graph 覆盖
   - 已有 `.sp4` container、SDK runtime、block mode、aux 与 sparse residual buffer 接入。
   - 540p 60fps 已进入实时可用区间；720p flow 仍需要 tiled/fused executor 继续优化。

2. 120fps 只开放给 `RIFE加速增强`
   - SP4 runner 支持 3/4 个 t 的 batch 输出。
   - INT4/MPSGraph/fused basic 不暴露 120fps UI 选项，避免非增强后端走到不可控功耗或长尾。

3. 模型尺寸仍是离散档
   - SP4 实时默认档位为 60fps: 安静 360p、均衡 432p、质量 540p；120fps: 安静 216p、均衡 360p、质量 432p。
   - 极复杂运动下可能出现 flow 不足或局部 artifact。

4. 浏览器原生全屏仍受平台限制
   - video top-layer 不保证 canvas 覆盖。
   - 浏览器路径需要旁路策略。

5. GPU 功耗观测不能直接等价于后端状态
   - 需要结合帧计数、kernel trace 和端到端显示验证。

6. 离线导出尚未接入 SP4
   - 当前离线稳定路径仍以 fused kernel 为主。
   - RIFE/SP4 离线高质量导出是后续工作。

## 15. 后续工程路线

### 15.1 本地播放器

- 进一步减少首帧启动闪烁。
- seek 后重置 previous/current 状态，避免跨时间点错误插帧。
- 增加更精确的 frame pacing 统计，但不在用户 UI 中暴露性能壁垒。
- 验证不同编码格式、HDR/SDR、旋转 metadata 和可变帧率视频。

### 15.2 SP4

- 将 Motion 侧 executor 从前三层 prepared cache 继续推进到 tiled/fused SP4 graph。
- 复用 `.sp4` layer metadata，扩大真实 SP4 图执行覆盖范围。
- 优化 mode / aux / sparse residual 在 GPU 上的访问布局。
- 将 flow rescale 与 presentation fusion 继续合并，减少 multi-t 后续子帧 encoder 数。
- 将 SDK sparse residual 与 Motion presentation refine 的职责拆清。
- 引入 block 级 sensitive fallback。
- 为 SP4E 预留矩阵加速器映射。

### 15.3 后端调度

- 将 command-buffer batch、presentation reuse、blend/refine fusion、tiled executor 写入 backend capability table。
- 根据视频分辨率、运动强度、目标 FPS 和电源状态选择后端。
- 对 SP4/INT4/MPSGraph 的首帧加载、steady-state 和长尾耗时分别统计。

### 15.4 离线导出

- 将 RIFE/SP4 接入 AVAssetReader -> Metal -> AVAssetWriter。
- 支持更高质量 flow height。
- 支持多中间帧导出。
- 保留 fused 导出作为稳定 fallback。

### 15.5 验证

- 用 Instruments Metal System Trace 验证 kernel 序列。
- 用 Power Profiler 做长时间功耗采样。
- 用 ffprobe / frame diff 验证输出帧节奏和插帧有效性。
- 建立本地播放器真实视频回归集。

## 16. 代码索引

关键路径：

- 本地实时播放器：`Sources/Video/MotionOnlineProcessor.mm`
- 本地视频 UI：`Sources/App/main.mm`
- Metal shader：`Sources/Metal/MotionKernels.metal`
- INT4 runner：`Sources/VFI/RIFEMetal4BitRunner.mm`
- SP4 runner：`Sources/VFI/RIFESP4Runner.mm`
- MPSGraph runner：`Sources/VFI/RIFEMPSGraphRunner.mm`
- Core ML runner：`Sources/VFI/RIFECoreMLRunner.mm`
- 浏览器 bridge：`Sources/BrowserAgent/stream_bridge/BrowserStreamBridge.mm`
- 浏览器 extension：`Sources/BrowserAgent/extension/content_script.js`
- 离线导出：`Sources/Video/MotionOfflineProcessor.mm`
- 构建与测试：`CMakeLists.txt`

对应测试：

- `Tests/LocalPlayerVideoOutputSmoke.mm`
- `Tests/RIFEMetal4BitSmoke.mm`
- `Tests/RIFEMetal4BitPerfSmoke.mm`
- `Tests/RIFESP4Smoke.mm`
- `Tests/RealtimeVFIPacingSmoke.cpp`
- `Tests/MotionOfflineProcessorSmoke.mm`
