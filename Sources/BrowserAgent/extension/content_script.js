(() => {
  const AGENT_VERSION = "0.5.34";
  if (globalThis.__stellariaMotionAgentActive &&
      globalThis.__stellariaMotionAgentVersion !== AGENT_VERSION &&
      typeof globalThis.__stellariaMotionAgentShutdown === "function") {
    try {
      globalThis.__stellariaMotionAgentShutdown();
    } catch (_) {
    }
  }
  if (globalThis.__stellariaMotionAgentActive &&
      globalThis.__stellariaMotionAgentVersion === AGENT_VERSION) {
    return;
  }
  globalThis.__stellariaMotionAgentActive = true;
  globalThis.__stellariaMotionAgentVersion = AGENT_VERSION;

  const observed = new WeakMap();
  const videoActivity = new WeakMap();
  const encrypted = new WeakSet();
  const resizeObservers = new Set();
  let mutationObserver = null;
  let heartbeatTimer = null;
  let active = true;
  let badge = null;
  let badgeClosed = false;
  let streamOverlay = null;
  let streamBridgeSocket = null;
  let streamBridgeConnecting = false;
  let streamBridgeConnected = false;
  let streamBridgeViaServiceWorker = false;
  let streamBridgeFramesSent = 0;
  let streamBridgeBytesSent = 0;
  let streamBridgeFramesAcked = 0;
  let streamBridgeLastSendAt = 0;
  let streamBridgeFrameInFlight = false;
  let streamBridgeLastError = "";
  let streamBridgePendingProcessedMeta = null;
  let streamBridgePendingOutputIds = [];
  let streamBridgeSentFrameTimes = new Map();
  let streamBridgeDirectInFlight = 0;
  let streamBridgeStopRequested = false;
  let streamBridgeNextFrameId = 1;
  let streamBridgeEncoder = null;
  let streamBridgeEncoderKey = "";
  let streamBridgeEncoderInitializing = false;
  let streamBridgeEncoderAvailable = null;
  let streamBridgeEncoderCodec = "";
  let streamBridgeEncoderDisplayCodec = "";
  let streamBridgeEncodedFramesSent = 0;
  let streamBridgeEncodeFallbackReason = "";
  let streamBridgeEncoderFrameQueue = [];
  let streamBridgeInputEncodeLatencyMs = 0;
  let streamBridgeInputKeyframeNeeded = true;
  let streamBridgeOutputDecoder = null;
  let streamBridgeOutputDecoderKey = "";
  let streamBridgeOutputDecodeMetaByTimestamp = new Map();
  let streamBridgeOutputCodecDescriptionCache = new Map();
  let streamBridgeOutputDecodedFrames = 0;
  let streamBridgeOutputDecodeFallbackReason = "";
  let streamBridgeOutputDecodeErrors = 0;
  let streamBridgeOutputChunkTimestamp = 1;
  let streamBridgeReturnKeyframeNeeded = true;
  let streamBridgeLastSnapshot = null;
  let streamBridgeStableRIFEBackend = "";
  let streamBridgeStableRIFEHeight = 0;
  let streamBridgeNativeProcessedFPS = 0;
  let streamBridgeLastNativeProcessedFrames = 0;
  let streamBridgeLastNativeMetricsAt = 0;
  let realPageMetricsLastPublishedAt = 0;
  let lastOnlineStatus = null;
  let selectedVideo = null;
  let selectedVideoChangedAt = 0;
  let passiveBridgeOnline = false;
  const STREAM_CAPTURE_MAX_WIDTH = 2560;
  const STREAM_CAPTURE_MAX_HEIGHT = 1440;
  const STREAM_CAPTURE_MAX_PIXELS = 1920 * 1080;
  const STREAM_METRICS_INTERVAL_MS = 1000;
  const STREAM_BINARY_FRAME_MAGIC = 0x31464d53;
  const STREAM_BINARY_OUTPUT_MAGIC = 0x314f4d53;
  const STREAM_BINARY_FRAME_VERSION = 2;
  const STREAM_BINARY_OUTPUT_VERSION = 1;
  const STREAM_BINARY_FRAME_HEADER_BYTES = 92;
  const STREAM_BINARY_OUTPUT_HEADER_BYTES = 72;
  const STREAM_APP_BUFFER_SECONDS = 10;
  const STREAM_APP_MAX_PENDING_FRAMES = 1440;
  const STREAM_PRESENTATION_PREROLL_FRAMES = 22;
  const STREAM_PRESENTATION_TARGET_BUFFER_MS = 360;
  const STREAM_PRESENTATION_MAX_BUFFER_MS = 900;
  const STREAM_OUTPUT_STALL_RECOVER_MS = 700;
  const STREAM_DIRECT_TRACK_STALL_MS = 650;
  const STREAM_DIRECT_TRACK_WARMUP_MS = 900;
  const REAL_PAGE_METRICS_NODE_ID = "stellaria-motion-real-page-metrics";
  const STREAM_BINARY_FLAG_KEY = 1 << 0;
  const STREAM_BINARY_FLAG_FORCE_RETURN_KEY = 1 << 1;
  const STREAM_BINARY_FLAG_NO_CPU_READBACK = 1 << 2;
  const STREAM_BINARY_FLAG_UNLIMITED = 1 << 3;
  const STREAM_BINARY_FLAG_HEVC_MOTION_HINTS = 1 << 6;
  const STREAM_BINARY_FLAG_ROI_MOTION_BLOCKS = 1 << 7;
  const STREAM_BINARY_FLAG_DYNAMIC_MULTI_FRAME = 1 << 9;
  const STREAM_MAX_SENT_TIMES = 32;
  const STREAM_PRESENTATION_TARGET_FPS = 60;
  const STREAM_ENCODER_CANDIDATES = [
    {
      codec: "hvc1.1.6.L123.B0",
      label: "HEVC",
      payloadCodec: "hevc",
      extension: { hevc: { format: "annexb" } }
    },
    {
      codec: "avc1.64002a",
      label: "H.264",
      payloadCodec: "h264",
      extension: { avc: { format: "annexb" } }
    }
  ];

  function runtimeErrorText(error) {
    return String(error?.message || error || "");
  }

  function isRuntimeError(error) {
    return /extension context invalidated|receiving end does not exist|message port closed|runtime/i.test(runtimeErrorText(error));
  }

  function swallowRuntimeError(event) {
    const error = event?.error || event?.reason || event?.message;
    if (!isRuntimeError(error)) {
      return false;
    }
    event.preventDefault?.();
    event.stopImmediatePropagation?.();
    shutdown();
    return true;
  }

  function shutdown() {
    if (!active) {
      return;
    }
    active = false;
    globalThis.__stellariaMotionAgentActive = false;
    resizeObservers.forEach((observer) => observer.disconnect());
    resizeObservers.clear();
    if (heartbeatTimer !== null) {
      clearInterval(heartbeatTimer);
      heartbeatTimer = null;
    }
    badge?.remove();
    badge = null;
    stopStreamOverlay();
    closeStreamBridge();
    mutationObserver?.disconnect();
    window.removeEventListener("scroll", safeScan);
    window.removeEventListener("resize", safeScan);
    window.removeEventListener("scroll", markStreamOverlayLayoutDirty);
    window.removeEventListener("resize", markStreamOverlayLayoutDirty);
    document.removeEventListener("fullscreenchange", markStreamOverlayLayoutDirty);
    document.removeEventListener("webkitfullscreenchange", markStreamOverlayLayoutDirty);
    globalThis.removeEventListener("error", swallowRuntimeError, true);
    globalThis.removeEventListener("unhandledrejection", swallowRuntimeError, true);
  }
  globalThis.__stellariaMotionAgentShutdown = shutdown;

  function runtime() {
    if (!active || typeof chrome === "undefined") {
      return null;
    }
    try {
      if (typeof chrome.runtime?.sendMessage !== "function") {
        return null;
      }
      return chrome.runtime;
    } catch (error) {
      shutdown();
      return null;
    }
  }

  function videoScore(video) {
    try {
      const rect = video.getBoundingClientRect();
      if (rect.width <= 1 || rect.height <= 1) {
        return 0;
      }
      const visibleLeft = Math.max(rect.left, 0);
      const visibleTop = Math.max(rect.top, 0);
      const visibleRight = Math.min(rect.right, window.innerWidth);
      const visibleBottom = Math.min(rect.bottom, window.innerHeight);
      const visibleArea = Math.max(0, visibleRight - visibleLeft) * Math.max(0, visibleBottom - visibleTop);
      const activity = videoActivity.get(video) || {};
      const readiness = (video.readyState || 0) * 180000;
      const pixels = (video.videoWidth || 0) * (video.videoHeight || 0) > 0 ? 650000 : -60000;
      const playing = !video.paused && !video.ended ? 900000 : -40000;
      const timeMoving = activity.moving ? 500000 : 0;
      const fullscreenElement = document.fullscreenElement || document.webkitFullscreenElement || null;
      const fullscreenBoost = fullscreenElement && (fullscreenElement === video || fullscreenElement.contains(video)) ? 1400000 : 0;
      const centerX = rect.left + rect.width * 0.5;
      const centerY = rect.top + rect.height * 0.5;
      const viewportRadius = Math.max(1, Math.hypot(window.innerWidth, window.innerHeight) * 0.5);
      const centerDistance = Math.hypot(centerX - window.innerWidth * 0.5, centerY - window.innerHeight * 0.5);
      const centerBoost = Math.max(0, 1 - centerDistance / viewportRadius) * 240000;
      return visibleArea + readiness + pixels + playing + timeMoving + fullscreenBoost + centerBoost;
    } catch (error) {
      if (isRuntimeError(error)) {
        shutdown();
      }
      return 0;
    }
  }

  function primaryVideo() {
    try {
      const ranked = [...document.querySelectorAll("video")]
        .map((video) => ({ video, score: videoScore(video) }))
        .filter((item) => item.score > 4096)
        .sort((a, b) => b.score - a.score);
      const best = ranked[0] || null;
      if (!best) {
        selectedVideo = null;
        return null;
      }
      if (selectedVideo && document.contains(selectedVideo)) {
        const currentScore = videoScore(selectedVideo);
        const now = performance.now();
        const switchMargin = selectedVideo.paused || selectedVideo.ended ? 180000 : 420000;
        if (currentScore > 4096 && best.video !== selectedVideo && best.score < currentScore + switchMargin && now - selectedVideoChangedAt < 2500) {
          return selectedVideo;
        }
        if (best.video === selectedVideo || best.score < currentScore + switchMargin) {
          return selectedVideo;
        }
      }
      selectedVideo = best.video;
      selectedVideoChangedAt = performance.now();
      return selectedVideo;
    } catch (error) {
      if (isRuntimeError(error)) {
        shutdown();
      }
      return null;
    }
  }

  function videoState(video) {
    const rect = video.getBoundingClientRect();
    const visibleLeft = Math.max(rect.left, 0);
    const visibleTop = Math.max(rect.top, 0);
    const visibleRight = Math.min(rect.right, window.innerWidth);
    const visibleBottom = Math.min(rect.bottom, window.innerHeight);
    const visibleWidth = Math.max(0, visibleRight - visibleLeft);
    const visibleHeight = Math.max(0, visibleBottom - visibleTop);
    const src = video.currentSrc || video.src || "";
    const chromeInsetX = Math.max(0, (window.outerWidth - window.innerWidth) * 0.5);
    const chromeInsetY = Math.max(0, window.outerHeight - window.innerHeight - chromeInsetX);
    const protectedContent = Boolean(video.webkitKeys || video.mediaKeys) ||
      encrypted.has(video) ||
      src.includes("widevine") ||
      src.includes("fairplay") ||
      src.includes("playready");

    return {
      type: "video_state",
      tabId: 0,
      url: window.location.href,
      src,
      sentAtMs: Date.now(),
      currentTime: video.currentTime || 0,
      playbackRate: video.playbackRate || 1,
      paused: video.paused,
      readyState: video.readyState,
      videoWidth: video.videoWidth || 0,
      videoHeight: video.videoHeight || 0,
      rect: {
        x: visibleLeft + window.screenX + chromeInsetX,
        y: visibleTop + window.screenY + chromeInsetY,
        width: visibleWidth,
        height: visibleHeight
      },
      fullscreen: document.fullscreenElement === video || document.fullscreenElement?.contains(video) || false,
      protectedContent,
      encrypted: encrypted.has(video),
      agentDebug: {
        version: AGENT_VERSION,
        bridgeConnecting: streamBridgeConnecting,
        bridgeConnected: streamBridgeConnected,
        bridgeViaServiceWorker: streamBridgeViaServiceWorker,
        bridgeFramesSent: streamBridgeFramesSent,
        bridgeFramesAcked: streamBridgeFramesAcked,
        bridgeError: streamBridgeLastError,
        overlayRunning: Boolean(streamOverlay?.running),
        overlayDecodedFrames: streamOverlay?.decodedFrames || 0,
        overlayOutputFrames: streamOverlay?.outputFrames || 0,
        overlayProcessedFrames: streamOverlay?.processedFrames || 0,
        overlayDirectFrames: streamOverlay?.directFrames || 0,
        overlayEncodedFrames: streamBridgeEncodedFramesSent,
        overlayEncodeCodec: streamBridgeEncoderDisplayCodec || streamBridgeEncoderCodec,
        overlayEncodeFallbackReason: streamBridgeEncodeFallbackReason,
        overlayOutputDecodedFrames: streamBridgeOutputDecodedFrames,
        overlayOutputDecodeFallbackReason: streamBridgeOutputDecodeFallbackReason,
        overlayFrameSource: streamOverlay?.directFrameActive ? "track_processor" : "video_frame_callback",
        overlayDrawErrors: streamOverlay?.drawErrors || 0,
        overlayLastDrawError: streamOverlay?.lastDrawError || "",
        overlayInputFPS: streamOverlay?.inputFPS || 0,
        overlayOutputFPS: streamOverlay?.outputFPS || 0,
        overlayProcessedLatencyMs: streamOverlay?.processedLatencyMs || 0,
        overlayPresentationUnderflows: streamOverlay?.presentationUnderflows || 0,
        overlayLastPresentGapMs: streamOverlay?.lastPresentGapMs || 0,
        overlayMaxPresentGapMs: streamOverlay?.maxPresentGapMs || 0,
        overlayOutputQueueDepth: streamOverlay?.appOutputQueue?.length || 0
      }
    };
  }

  function buildRealPageMetrics(video = null) {
    const selected = video || primaryVideo();
    const snapshot = streamBridgeLastSnapshot || {};
    const rect = selected?.getBoundingClientRect?.();
    const overlay = streamOverlay;
    return {
      type: "stellaria_motion_real_page_metrics",
      version: AGENT_VERSION,
      updatedAtMs: Date.now(),
      href: window.location.href,
      title: document.title || "",
      visibility: document.visibilityState || "",
      running: Boolean(lastOnlineStatus?.running),
      browserDirect: Boolean(lastOnlineStatus?.browserDirect),
      bridge: {
        connecting: streamBridgeConnecting,
        connected: streamBridgeConnected,
        viaServiceWorker: streamBridgeViaServiceWorker,
        error: streamBridgeLastError || "",
        framesSent: streamBridgeFramesSent,
        framesAcked: streamBridgeFramesAcked,
        encodedFramesSent: streamBridgeEncodedFramesSent,
        encodedBytesSent: streamBridgeBytesSent,
        directInFlight: streamBridgeDirectInFlight,
        inputEncodeMs: Number(streamBridgeInputEncodeLatencyMs || 0),
        inputCodec: streamBridgeEncoderDisplayCodec || streamBridgeEncoderCodec || "",
        inputFallbackReason: streamBridgeEncodeFallbackReason || "",
        outputDecodedFrames: streamBridgeOutputDecodedFrames,
        outputDecodeErrors: streamBridgeOutputDecodeErrors,
        outputFallbackReason: streamBridgeOutputDecodeFallbackReason || ""
      },
      video: selected ? {
        paused: Boolean(selected.paused),
        ended: Boolean(selected.ended),
        readyState: Number(selected.readyState || 0),
        currentTime: Number(selected.currentTime || 0),
        duration: Number(selected.duration || 0),
        playbackRate: Number(selected.playbackRate || 1),
        muted: Boolean(selected.muted),
        videoWidth: Number(selected.videoWidth || 0),
        videoHeight: Number(selected.videoHeight || 0),
        rect: rect ? {
          x: Math.round(rect.left),
          y: Math.round(rect.top),
          width: Math.round(rect.width),
          height: Math.round(rect.height)
        } : null,
        srcKind: selected.currentSrc || selected.src ? (String(selected.currentSrc || selected.src).startsWith("blob:") ? "blob" : "url") : "none"
      } : null,
      overlay: overlay ? {
        running: Boolean(overlay.running),
        frameSource: overlay.directFrameActive ? "track_processor" : "video_frame_callback",
        fallbackActive: Boolean(overlay.videoFrameFallbackActive),
        directFrames: Number(overlay.directFrames || 0),
        directTrackStalls: Number(overlay.directTrackStalls || 0),
        decodedFrames: Number(overlay.decodedFrames || 0),
        outputFrames: Number(overlay.outputFrames || 0),
        processedFrames: Number(overlay.processedFrames || 0),
        inputFPS: Number(overlay.inputFPS || 0),
        outputFPS: Number(overlay.outputFPS || 0),
        processedFPS: Number(overlay.processedFPS || 0),
        sourceFPS: Number(sourceFPSForOverlay(overlay) || 0),
        processedLatencyMs: Number(overlay.processedLatencyMs || 0),
        queueDepth: Number(overlay.appOutputQueue?.length || 0),
        presentationUnderflows: Number(overlay.presentationUnderflows || 0),
        lastPresentGapMs: Number(overlay.lastPresentGapMs || 0),
        maxPresentGapMs: Number(overlay.maxPresentGapMs || 0),
        lastUnderflowAgeMs: overlay.lastUnderflowAt > 0 ? Math.max(0, performance.now() - overlay.lastUnderflowAt) : null,
        activeFrameId: Number(overlay.activeFrameId || 0),
        lastInputSendAgeMs: overlay.lastInputSendAt > 0 ? Math.max(0, performance.now() - overlay.lastInputSendAt) : null,
        lastDecodeAgeMs: overlay.lastDecodeAt > 0 ? Math.max(0, performance.now() - overlay.lastDecodeAt) : null,
        lastAppOutputAgeMs: overlay.lastAppOutputAt > 0 ? Math.max(0, performance.now() - overlay.lastAppOutputAt) : null,
        lastInputThrottleReason: overlay.lastInputThrottleReason || "",
        drawErrors: Number(overlay.drawErrors || 0),
        lastDrawError: overlay.lastDrawError || "",
        canvasVisible: overlay.canvas?.style?.display !== "none"
      } : null,
      native: {
        message: String(snapshot.message || ""),
        rifeBackend: String(snapshot.rifeBackend || streamBridgeStableRIFEBackend || ""),
        rifeModelHeight: Number(snapshot.rifeModelHeight || streamBridgeStableRIFEHeight || 0),
        receivedFrames: Number(snapshot.receivedFrames || 0),
        processedFrames: Number(snapshot.processedFrames || 0),
        outputQueuedFrames: Number(snapshot.outputQueuedFrames || 0),
        gpuMs: Number(snapshot.gpuMs || 0),
        decodeMs: Number(snapshot.decodeMs || 0),
        encodeMs: Number(snapshot.encodeMs || 0),
        nativeProcessedFPS: Number(streamBridgeNativeProcessedFPS || 0)
      },
      settings: {
        targetFPS: targetOutputFPS(overlay),
        flowInputHeight: appFlowInputHeight(),
        gpuBudgetMs: appGpuBudgetMs(),
        returnBitrateMbps: appReturnBitrateMbps(),
        directTrackProcessor: directTrackProcessorAllowed(),
        tier: appPowerTier(),
        powerMode: appPowerMode()
      }
    };
  }

  function publishRealPageMetrics(video = null, force = false) {
    const now = performance.now();
    if (!force && now - realPageMetricsLastPublishedAt < 500) {
      return;
    }
    realPageMetricsLastPublishedAt = now;
    try {
      const metrics = buildRealPageMetrics(video);
      let node = document.getElementById(REAL_PAGE_METRICS_NODE_ID);
      if (!node) {
        node = document.createElement("script");
        node.id = REAL_PAGE_METRICS_NODE_ID;
        node.type = "application/json";
        node.dataset.stellariaMotionMetrics = "true";
        (document.head || document.body || document.documentElement).appendChild(node);
      }
      node.textContent = JSON.stringify(metrics);
      document.documentElement.dataset.stellariaMotionAgentVersion = AGENT_VERSION;
      document.documentElement.dataset.stellariaMotionMetricsUpdatedAt = String(metrics.updatedAtMs);
    } catch (error) {
      if (isRuntimeError(error)) {
        shutdown();
      }
    }
  }

  function send(video) {
    const rt = runtime();
    if (!rt) {
      shutdown();
      return;
    }

    if (primaryVideo() !== video) {
      return;
    }
    publishRealPageMetrics(video);

    try {
      rt.sendMessage(videoState(video), () => {
        try {
          const lastError = chrome.runtime?.lastError;
          if (lastError && /extension context invalidated/i.test(runtimeErrorText(lastError))) {
            shutdown();
          }
        } catch (error) {
          shutdown();
        }
      });
    } catch (error) {
      if (isRuntimeError(error)) {
        shutdown();
        return;
      }
      shutdown();
    }
  }

  function safeSend(video) {
    try {
      send(video);
    } catch (error) {
      shutdown();
    }
  }

  function observe(video) {
    if (!active || observed.has(video)) {
      return;
    }
    observed.set(video, true);
    videoActivity.set(video, {
      lastTime: video.currentTime || 0,
      moving: false
    });

    ["play", "pause", "seeked", "ratechange", "loadedmetadata", "timeupdate"].forEach((eventName) => {
      video.addEventListener(eventName, () => {
        const activity = videoActivity.get(video) || {};
        const nowTime = video.currentTime || 0;
        activity.moving = Math.abs(nowTime - (activity.lastTime || 0)) > 0.02 || (!video.paused && video.readyState >= 2);
        activity.lastTime = nowTime;
        videoActivity.set(video, activity);
        active && safeSend(video);
      }, { passive: true });
    });
    video.addEventListener("encrypted", () => {
      encrypted.add(video);
      if (active) {
        safeSend(video);
      }
    }, { passive: true });

    const resizeObserver = new ResizeObserver(() => {
      markStreamOverlayLayoutDirty();
      safeSend(video);
    });
    resizeObserver.observe(video);
    resizeObservers.add(resizeObserver);

    safeSend(video);
  }

  function ensureBadge() {
    if (badge) {
      return badge;
    }
    badge = document.createElement("div");
    badge.style.cssText = [
      "position:fixed",
      "z-index:2147483647",
      "display:none",
      "align-items:center",
      "gap:8px",
      "height:28px",
      "width:min(720px,calc(100vw - 32px))",
      "max-width:calc(100vw - 32px)",
      "box-sizing:border-box",
      "padding:0 8px 0 10px",
      "border-radius:999px",
      "background:rgba(8,14,22,.74)",
      "border:1px solid rgba(136,190,255,.42)",
      "box-shadow:0 8px 24px rgba(0,0,0,.28)",
      "backdrop-filter:blur(12px) saturate(140%)",
      "color:#edf6ff",
      "font:600 12px -apple-system,BlinkMacSystemFont,'SF Pro Text','Helvetica Neue',sans-serif",
      "font-variant-numeric:tabular-nums",
      "letter-spacing:0",
      "pointer-events:auto"
    ].join(";");
    badge.innerHTML = `
      <span data-sm-dot style="width:7px;height:7px;border-radius:999px;background:#72f5d0;box-shadow:0 0 12px rgba(114,245,208,.9);display:inline-block"></span>
      <span data-sm-label style="display:block;flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">Stellaria 插帧中</span>
      <div data-sm-panel style="display:none;min-width:0;width:100%">
        <div data-sm-title style="font:700 12px -apple-system,BlinkMacSystemFont,'SF Pro Text','Helvetica Neue',sans-serif;color:#f4f8ff;line-height:1.2;padding-right:18px">Stellaria Motion 诊断</div>
        <div data-sm-fields style="display:grid;grid-template-columns:58px minmax(0,1fr);gap:5px 8px;margin-top:8px;font:500 11px -apple-system,BlinkMacSystemFont,'SF Pro Text','Helvetica Neue',sans-serif;color:#d5e3f3;line-height:1.25"></div>
      </div>
      <button data-sm-close aria-label="关闭插帧提示" style="all:unset;cursor:pointer;color:#b9c7d9;font-weight:700;font-size:13px;line-height:1;padding:0 2px">×</button>
    `;
    badge.querySelector("[data-sm-close]").addEventListener("click", (event) => {
      event.stopPropagation();
      badgeClosed = true;
      badge.style.display = "none";
    });
    document.documentElement.appendChild(badge);
    return badge;
  }

  function setBadgeDiagnosticMode(item, enabled) {
    const dot = item.querySelector("[data-sm-dot]");
    const label = item.querySelector("[data-sm-label]");
    const panel = item.querySelector("[data-sm-panel]");
    const close = item.querySelector("[data-sm-close]");
    if (enabled) {
      item.style.alignItems = "flex-start";
      item.style.height = "auto";
      item.style.width = "min(360px, calc(100vw - 32px))";
      item.style.padding = "10px 12px 11px";
      item.style.borderRadius = "8px";
      item.style.gap = "0";
      dot.style.display = "none";
      label.style.display = "none";
      panel.style.display = "block";
      close.style.position = "absolute";
      close.style.top = "8px";
      close.style.right = "10px";
      return;
    }
    item.style.alignItems = "center";
    item.style.height = "28px";
    item.style.width = "min(420px, calc(100vw - 32px))";
    item.style.padding = "0 8px 0 10px";
    item.style.borderRadius = "999px";
    item.style.gap = "8px";
    dot.style.display = "inline-block";
    label.style.display = "block";
    panel.style.display = "none";
    close.style.position = "";
    close.style.top = "";
    close.style.right = "";
  }

  function updateDiagnosticPanel(item, rows) {
    const fields = item.querySelector("[data-sm-fields]");
    if (!fields) {
      return;
    }
    fields.textContent = "";
    rows.forEach(([name, value]) => {
      const key = document.createElement("div");
      key.textContent = name;
      key.style.cssText = "color:#94a9bf;white-space:nowrap";
      const val = document.createElement("div");
      val.textContent = value;
      val.style.cssText = "min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#edf6ff;font-variant-numeric:tabular-nums";
      fields.appendChild(key);
      fields.appendChild(val);
    });
  }

  function updateBadge(online) {
    if (badgeClosed) {
      if (badge) {
        badge.style.display = "none";
      }
      return;
    }
    const selected = primaryVideo();
    if (!selected) {
      publishRealPageMetrics(null);
      return;
    }
    const rect = selected.getBoundingClientRect();
    if (rect.width <= 1 || rect.height <= 1) {
      publishRealPageMetrics(selected);
      return;
    }
    const item = ensureBadge();
    const now = performance.now();
    const diagnostics = detailedDiagnosticsEnabled();
    const textInterval = diagnostics ? 250 : 500;
    setBadgeDiagnosticMode(item, diagnostics);
    const canUpdateText = !streamOverlay || now - Number(streamOverlay.lastBadgeTextAt || 0) >= textInterval;
    if (streamOverlay && canUpdateText) {
      streamOverlay.lastBadgeTextAt = now;
    }
    const label = item.querySelector("[data-sm-label]");
    const dot = item.querySelector("[data-sm-dot]");
    if (!canUpdateText && item.style.display === "inline-flex") {
      if (now - Number(streamOverlay?.lastBadgeLayoutAt || 0) > 250 || streamOverlay?.layoutDirty) {
        if (streamOverlay) {
          streamOverlay.lastBadgeLayoutAt = now;
        }
        item.style.top = `${Math.max(8, rect.top + 10)}px`;
        item.style.right = `${Math.max(8, window.innerWidth - Math.min(rect.right, window.innerWidth) + 10)}px`;
      }
      return;
    }
    const fps = Number(online?.generatedFPS || 0);
    const mode = online?.browserDirect ? "浏览器直连" : "Stellaria";
    if (dot) {
      dot.style.background = online?.running ? "#72f5d0" : "#8da2bc";
      dot.style.boxShadow = online?.running ? "0 0 12px rgba(114,245,208,.9)" : "none";
    }
    const inputFPS = Number(streamOverlay?.inputFPS || online?.inputFPS || 0);
    const outputFPS = Number(streamOverlay?.outputFPS || 0);
    const bridge = online?.streamBridge || {};
    const decodedFPS = Number(streamOverlay?.processedFPS || streamBridgeNativeProcessedFPS || bridge.processedFPS || 0);
    const processedLatency = Number(streamOverlay?.processedLatencyMs || 0);
    const decodeHint = streamBridgeOutputDecodeFallbackReason ? ` · decode ${streamBridgeOutputDecodeFallbackReason}` : "";
    const nativeMessage = String(streamBridgeLastSnapshot?.message || "");
    const nativeHint = nativeMessage && decodedFPS <= 0 ? ` · native ${nativeMessage}` : "";
    const snapshot = streamBridgeLastSnapshot || {};
    const nativeReceivedFrames = Number(snapshot.receivedFrames || online?.streamBridge?.receivedFrames || 0);
    const nativeProcessedFrames = Number(snapshot.processedFrames || 0);
    const videoPaused = Boolean(selected.paused || selected.ended);
    label.textContent = online?.running
      ? (fps > 0
          ? `${mode}插帧中 · ${fps.toFixed(1)}fps`
          : (online?.browserDirect
              ? (videoPaused ? "已连接 · 视频暂停，播放后开始插帧" : `已连接 · 等待首帧 · in ${inputFPS.toFixed(1)}fps`)
              : `${mode}插帧启动中`))
      : `Stellaria Agent ${AGENT_VERSION} 就绪 · 请在 App 点启动`;
    if (online?.running && streamBridgeConnected) {
      const frameSource = streamBridgeEncodedFramesSent > 0
        ? `硬编 ${streamBridgeEncoderDisplayCodec || streamBridgeEncoderCodec || "H.264"}`
        : (streamOverlay?.directFrameActive ? "视频流" : "画面");
      const returnPath = streamBridgeOutputDecodedFrames > 0 ? "硬解回推" : "回推";
      if (!diagnostics) {
        if (videoPaused) {
          label.textContent = "Stellaria 已连接 · 视频暂停";
        } else if (nativeReceivedFrames <= 0) {
          label.textContent = `Stellaria 已连接 · 等待浏览器帧 · ${frameSource}`;
        } else {
          label.textContent = `Metal ${returnPath} · ${inputFPS.toFixed(1).padStart(5, " ")} -> ${outputFPS.toFixed(1).padStart(5, " ")}fps`;
        }
      } else {
        label.textContent = videoPaused
          ? `已连接 · 视频暂停 · ${frameSource}`
          : `Metal ${returnPath} · ${frameSource} · in ${inputFPS.toFixed(1).padStart(5, " ")} / app ${decodedFPS.toFixed(1).padStart(5, " ")} / out ${outputFPS.toFixed(1).padStart(5, " ")}fps`;
      }
      if (decodedFPS > 0 && diagnostics) {
        label.textContent += ` · rt ${Math.max(0, processedLatency).toFixed(0).padStart(4, " ")}ms`;
      }
      if (diagnostics) {
        const rifeBackend = String(streamBridgeLastSnapshot?.rifeBackend || "");
        if (rifeBackend) {
          label.textContent += ` · ${rifeBackend}`;
        }
        label.textContent += decodeHint || nativeHint;
      }
    } else if (online?.running && streamBridgeConnecting) {
      label.textContent = "App Bridge 连接中";
    } else if (streamBridgeLastError && !online?.browserDirect) {
      label.textContent = `Bridge 未连接 · ${streamBridgeLastError}`;
    } else if (online?.browserDirect) {
      label.textContent = streamBridgeLastError ? `浏览器直连 · ${streamBridgeLastError}` : label.textContent;
    }
    if (diagnostics) {
      const backend = String(snapshot.rifeBackend || streamBridgeStableRIFEBackend || "等待 RIFE");
      const sourceMode = streamOverlay?.directFrameActive ? "视频流直读" : "视频帧回调";
      const gpuMs = Number(snapshot.gpuMs || 0);
      const encodeMs = Number(snapshot.encodeMs || 0);
      const modelHeight = Number(snapshot.rifeModelHeight || streamBridgeStableRIFEHeight || runtimeNumberSetting("flowInputHeight", 540));
      const throttleReason = String(streamOverlay?.lastInputThrottleReason || "");
      const returnRecovering = !videoPaused &&
        nativeProcessedFrames > 0 &&
        outputFPS <= 0.1 &&
        (streamBridgeReturnKeyframeNeeded || streamBridgeOutputDecodeFallbackReason.length > 0);
      const action = videoPaused
        ? "点击网页播放按钮"
        : (nativeReceivedFrames <= 0
            ? "等待浏览器首帧"
            : (nativeProcessedFrames <= 0
                ? (String(snapshot.message || "等待 RIFE 输出"))
                : (returnRecovering
                    ? (streamBridgeOutputDecodeFallbackReason || "等待回推关键帧")
                    : (throttleReason || streamBridgeOutputDecodeFallbackReason || streamBridgeLastError || "正常回推"))));
      updateDiagnosticPanel(item, [
        ["状态", videoPaused ? "视频暂停" : (returnRecovering ? "回推恢复" : (nativeProcessedFrames > 0 ? "回推中" : "等待首帧"))],
        ["输入", `${sourceMode} · ${inputFPS.toFixed(1)}fps · 已收 ${nativeReceivedFrames}`],
        ["输出", `${outputFPS.toFixed(1)}fps · 已处理 ${nativeProcessedFrames}`],
        ["RIFE", `${backend} · ${modelHeight.toFixed(0)}p · ${Math.max(0, gpuMs).toFixed(1)}ms`],
        ["队列", `q ${Number(snapshot.outputQueuedFrames || 0)} · buf ${Number(streamOverlay?.appOutputQueue?.length || 0)} · uf ${Number(streamOverlay?.presentationUnderflows || 0)} · gap ${Number(streamOverlay?.lastPresentGapMs || 0).toFixed(1)}ms`],
        ["下一步", action]
      ]);
    }
    item.style.display = "inline-flex";
    if (now - Number(streamOverlay?.lastBadgeLayoutAt || 0) > 250 || streamOverlay?.layoutDirty) {
      if (streamOverlay) {
        streamOverlay.lastBadgeLayoutAt = now;
      }
      item.style.top = `${Math.max(8, rect.top + 10)}px`;
      item.style.right = `${Math.max(8, window.innerWidth - Math.min(rect.right, window.innerWidth) + 10)}px`;
    }
    publishRealPageMetrics(selected);
  }

  function streamBridgeURL(online) {
    const port = Number(online?.streamBridgePort || online?.streamBridge?.port || 38577);
    return `ws://127.0.0.1:${port}/stellaria-motion-stream`;
  }

  function closeStreamBridge() {
    closeStreamBridgeEncoder();
    const rt = runtime();
    if (rt) {
      try {
        rt.sendMessage({ type: "bridge_disconnect", reason: "html overlay stopped" }, () => {
          try {
            void chrome.runtime?.lastError;
          } catch (_) {
          }
        });
      } catch (_) {
      }
    }
    streamBridgeConnecting = false;
    streamBridgeConnected = false;
    streamBridgeViaServiceWorker = false;
    passiveBridgeOnline = false;
    streamBridgeFrameInFlight = false;
    streamBridgePendingOutputIds = [];
    streamBridgeSentFrameTimes.clear();
    streamBridgeDirectInFlight = 0;
    streamBridgeEncodedFramesSent = 0;
    streamBridgeStopRequested = true;
    if (streamBridgeSocket) {
      try {
        streamBridgeSocket.close();
      } catch (_) {
      }
    }
    streamBridgeSocket = null;
  }

  function ensureStreamBridge(online) {
    if (!online?.running || !online.browserDirect) {
      closeStreamBridge();
      return;
    }
    if (streamBridgeConnecting || streamBridgeConnected) {
      return;
    }
    streamBridgeConnecting = true;
    streamBridgeLastError = "";
    streamBridgeViaServiceWorker = false;
    streamBridgePendingOutputIds = [];
    streamBridgeSentFrameTimes.clear();
    streamBridgeDirectInFlight = 0;
    streamBridgeStopRequested = false;
    try {
      const socket = new WebSocket(streamBridgeURL(online));
      socket.binaryType = "arraybuffer";
      streamBridgeSocket = socket;
      socket.addEventListener("open", () => {
        streamBridgeConnecting = false;
        streamBridgeConnected = true;
        streamBridgeViaServiceWorker = false;
        passiveBridgeOnline = true;
        streamBridgeLastError = "";
        try {
          socket.send(JSON.stringify({ type: "hello", via: "content_script_direct", sentAtMs: Date.now() }));
          sendStreamBridgeConfig(streamOverlay);
        } catch (_) {
        }
        updateBadge(lastOnlineStatus || { running: true, browserDirect: true });
      });
      socket.addEventListener("message", (event) => {
        if (typeof event.data === "string") {
          try {
            const parsed = JSON.parse(event.data);
            streamBridgePendingProcessedMeta = parsed?.type === "processed_frame" ? parsed : streamBridgePendingProcessedMeta;
            const snapshot = parsed?.snapshot || parsed || {};
            consumeStreamBridgeSnapshot(snapshot);
            streamBridgeFramesAcked = Number(snapshot.processedFrames || snapshot.receivedFrames || streamBridgeFramesAcked || 0);
          } catch (_) {
          }
          updateBadge(lastOnlineStatus || { running: true, browserDirect: true });
          return;
        }
        const consume = event.data instanceof Blob ? event.data.arrayBuffer() : Promise.resolve(event.data);
        consume.then((buffer) => {
          const parsedOutput = parseStreamBinaryOutput(buffer);
          if (!parsedOutput) {
            const frameId = streamBridgePendingOutputIds.length ? Number(streamBridgePendingOutputIds[0] || 0) : 0;
            retireStreamBridgeInFlight(frameId);
            const meta = streamBridgePendingProcessedMeta || {};
            if (meta.outputPayloadKind === "webcodecs_video_chunk") {
              const outputFrameId = Number(meta.frameId || frameId || 0);
              applyProcessedVideoChunk(buffer, outputFrameId);
              return;
            }
            streamBridgeOutputDecodeFallbackReason = "unknown app output payload";
            return;
          }
          retireStreamBridgeInFlight(parsedOutput.meta.frameId);
          streamBridgePendingProcessedMeta = parsedOutput.meta;
          consumeStreamBridgeSnapshot(parsedOutput.meta);
          streamBridgeFramesAcked = Number(parsedOutput.meta.processedFrames || streamBridgeFramesAcked || 0);
          if (parsedOutput.meta.outputPayloadKind === "webcodecs_video_chunk") {
            applyProcessedVideoChunk(parsedOutput.payload, parsedOutput.meta.frameId, parsedOutput.meta);
          } else {
            streamBridgeOutputDecodeFallbackReason = "app output must be video chunk";
          }
        }).catch((error) => {
          streamBridgeOutputDecodeFallbackReason = runtimeErrorText(error) || "output binary decode failed";
        });
      });
      socket.addEventListener("close", () => {
        if (streamBridgeSocket === socket) {
          streamBridgeSocket = null;
        }
        streamBridgeConnected = false;
        streamBridgeConnecting = false;
        passiveBridgeOnline = false;
        if (streamBridgeStopRequested) {
          return;
        }
        streamBridgeLastError = "direct bridge disconnected";
        connectServiceWorkerBridge(online);
      });
      socket.addEventListener("error", () => {
        streamBridgeConnected = false;
        streamBridgeConnecting = false;
        if (streamBridgeStopRequested) {
          return;
        }
        streamBridgeLastError = "direct bridge unavailable";
        connectServiceWorkerBridge(online);
      });
      return;
    } catch (error) {
      streamBridgeLastError = runtimeErrorText(error) || "direct bridge unavailable";
      streamBridgeConnecting = false;
    }
    connectServiceWorkerBridge(online);
  }

  function connectServiceWorkerBridge(online) {
    if (!online?.running || !online.browserDirect || streamBridgeConnected || streamBridgeConnecting) {
      return;
    }
    streamBridgeConnecting = true;
    const rt = runtime();
    if (!rt) {
      streamBridgeConnecting = false;
      streamBridgeLastError = "runtime unavailable";
      return;
    }
    try {
      rt.sendMessage({
        type: "bridge_connect",
        port: Number(online?.streamBridgePort || online?.streamBridge?.port || 38577)
      }, (response) => {
        const lastError = chrome.runtime?.lastError;
        if (lastError) {
          streamBridgeConnecting = false;
          streamBridgeConnected = false;
          streamBridgeViaServiceWorker = false;
          streamBridgeLastError = runtimeErrorText(lastError) || "service worker unavailable";
          updateBadge(lastOnlineStatus || { running: true, browserDirect: true });
          return;
        }
        streamBridgeConnecting = Boolean(response?.connecting);
        streamBridgeConnected = Boolean(response?.connected);
        streamBridgeViaServiceWorker = streamBridgeConnected || streamBridgeConnecting;
        streamBridgeLastError = response?.error || (response ? "" : "service worker no response");
        passiveBridgeOnline = streamBridgeConnected || streamBridgeConnecting || passiveBridgeOnline;
        updateBadge(lastOnlineStatus || { running: true, browserDirect: true });
      });
    } catch (error) {
      streamBridgeConnecting = false;
      streamBridgeConnected = false;
      streamBridgeLastError = runtimeErrorText(error) || "bridge unavailable";
    }
  }

  function resizeCanvas(canvas, width, height) {
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
    }
  }

  function noteStreamBridgeFrameSent(frameId) {
    const id = Number(frameId || 0);
    if (!id) {
      return;
    }
    streamBridgeSentFrameTimes.set(id, performance.now());
    while (streamBridgeSentFrameTimes.size > STREAM_MAX_SENT_TIMES) {
      const first = streamBridgeSentFrameTimes.keys().next();
      if (first.done) {
        break;
      }
      streamBridgeSentFrameTimes.delete(first.value);
    }
  }

  function noteStreamBridgeFrameReturned(overlay, frameId) {
    const id = Number(frameId || 0);
    const sentAt = streamBridgeSentFrameTimes.get(id);
    if (!id || !Number.isFinite(sentAt)) {
      return;
    }
    streamBridgeSentFrameTimes.delete(id);
    const latency = performance.now() - sentAt;
    if (latency <= 0 || latency > 1000) {
      return;
    }
    overlay.processedLatencyMs = overlay.processedLatencyMs > 0
      ? overlay.processedLatencyMs * 0.82 + latency * 0.18
      : latency;
  }

  function retireStreamBridgeInFlight(returnedFrameId = 0) {
    const returned = Number(returnedFrameId || 0);
    let retired = 0;
    if (returned > 0) {
      while (streamBridgePendingOutputIds.length > 0 &&
             Number(streamBridgePendingOutputIds[0] || 0) <= returned) {
        const id = Number(streamBridgePendingOutputIds.shift() || 0);
        if (id > 0) {
          streamBridgeSentFrameTimes.delete(id);
        }
        retired += 1;
      }
    }
    if (retired === 0 && streamBridgePendingOutputIds.length > 0) {
      const id = Number(streamBridgePendingOutputIds.shift() || 0);
      if (id > 0) {
        streamBridgeSentFrameTimes.delete(id);
      }
      retired = 1;
    }
    if (retired === 0 && streamBridgeDirectInFlight > 0) {
      retired = 1;
    }
    streamBridgeDirectInFlight = Math.max(0, streamBridgeDirectInFlight - retired);
  }

  function pruneStaleStreamBridgeInFlight(now = performance.now()) {
    if (streamBridgePendingOutputIds.length === 0) {
      streamBridgeDirectInFlight = Math.max(0, Math.min(streamBridgeDirectInFlight, 1));
      return;
    }
    let retired = 0;
    while (streamBridgePendingOutputIds.length > 0) {
      const id = Number(streamBridgePendingOutputIds[0] || 0);
      const sentAt = streamBridgeSentFrameTimes.get(id) || 0;
      if (!sentAt || now - sentAt < 900) {
        break;
      }
      streamBridgePendingOutputIds.shift();
      streamBridgeSentFrameTimes.delete(id);
      retired += 1;
    }
    if (retired > 0) {
      streamBridgeDirectInFlight = Math.max(0, streamBridgeDirectInFlight - retired);
    }
  }

  function ackStreamBridgeProcessedFrame(meta, fallbackAck = 0) {
    const nativeProcessed = Number(meta?.processedFrames || 0);
    const ackValue = nativeProcessed > 0 ? nativeProcessed : Number(fallbackAck || 0);
    if (ackValue > 0) {
      streamBridgeFramesAcked = Math.max(streamBridgeFramesAcked, ackValue);
    }
  }

  function detailedDiagnosticsEnabled() {
    return runtimeBooleanSetting("diagnosticOverlay", false);
  }

  function markStreamOverlayLayoutDirty() {
    if (streamOverlay) {
      streamOverlay.layoutDirty = true;
    }
  }

  function base64ToUint8Array(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  }

  function mediaAspect(video) {
    const videoWidth = Number(video?.videoWidth || 0);
    const videoHeight = Number(video?.videoHeight || 0);
    return videoWidth > 1 && videoHeight > 1 ? videoWidth / videoHeight : 16 / 9;
  }

  function containRect(width, height, aspect) {
    const safeAspect = aspect > 0 ? aspect : 16 / 9;
    let outWidth = width;
    let outHeight = outWidth / safeAspect;
    if (outHeight > height) {
      outHeight = height;
      outWidth = outHeight * safeAspect;
    }
    return {
      x: Math.round((width - outWidth) * 0.5),
      y: Math.round((height - outHeight) * 0.5),
      width: Math.max(1, Math.round(outWidth)),
      height: Math.max(1, Math.round(outHeight))
    };
  }

  function evenDimension(value) {
    return Math.max(2, Math.round(Math.max(2, value) / 2) * 2);
  }

  function drawContain(ctx, source, overlay) {
    const rect = overlay.contentRect || containRect(ctx.canvas.width, ctx.canvas.height, overlay.mediaAspect || 16 / 9);
    ctx.drawImage(source, rect.x, rect.y, rect.width, rect.height);
  }

  function closeStreamBridgeEncoder() {
    const encoder = streamBridgeEncoder;
    streamBridgeEncoder = null;
    streamBridgeEncoderKey = "";
    streamBridgeEncoderInitializing = false;
    streamBridgeEncoderAvailable = null;
    streamBridgeEncoderCodec = "";
    streamBridgeEncoderDisplayCodec = "";
    streamBridgeEncoderFrameQueue = [];
    streamBridgeInputEncodeLatencyMs = 0;
    streamBridgeInputKeyframeNeeded = true;
    if (encoder) {
      try {
        encoder.close();
      } catch (_) {
      }
    }
  }

  function closeStreamBridgeOutputDecoder() {
    const decoder = streamBridgeOutputDecoder;
    streamBridgeOutputDecoder = null;
    streamBridgeOutputDecoderKey = "";
    streamBridgeOutputDecodeMetaByTimestamp.clear();
    streamBridgeOutputChunkTimestamp = 1;
    streamBridgeReturnKeyframeNeeded = true;
    streamBridgeOutputDecodedFrames = 0;
    if (decoder) {
      try {
        decoder.close();
      } catch (_) {
      }
    }
  }

  function clearAppOutputPresentation(overlay, resetBitmap = false) {
    if (!overlay) {
      return;
    }
    if (!resetBitmap && overlay.processedBitmap) {
      setStreamVideoCovered(overlay, true);
      overlay.canvas.style.display = "block";
      try {
        overlay.ctx?.clearRect(0, 0, overlay.canvas.width, overlay.canvas.height);
        overlay.ctx.globalAlpha = 1;
        drawContain(overlay.ctx, overlay.processedBitmap, overlay);
      } catch (_) {
      }
    } else {
      setStreamVideoCovered(overlay, false);
      overlay.canvas.style.display = "none";
    }
    try {
      overlay.appOutputCtx?.clearRect(0, 0, overlay.appOutputCanvas?.width || 0, overlay.appOutputCanvas?.height || 0);
    } catch (_) {
    }
    overlay.currentAppOutputMeta = null;
    overlay.lastAppOutputAt = 0;
    overlay.outputFPS = 0;
    if (Array.isArray(overlay.appOutputQueue)) {
      for (const item of overlay.appOutputQueue) {
        closeQueuedOutput(item);
      }
      overlay.appOutputQueue = [];
    }
    if (resetBitmap && overlay.processedBitmap) {
      try {
        overlay.processedBitmap.close?.();
      } catch (_) {
      }
      overlay.processedBitmap = null;
      overlay.appOutputStarted = false;
    }
  }

  function consumeStreamBridgeSnapshot(snapshot) {
    if (!snapshot || typeof snapshot !== "object") {
      return;
    }
    streamBridgeLastSnapshot = snapshot;
    const snapshotBackend = String(snapshot.rifeBackend || "");
    const snapshotModelHeight = Number(snapshot.rifeModelHeight || 0);
    if (snapshotBackend && snapshotModelHeight > 0) {
      streamBridgeStableRIFEBackend = snapshotBackend;
      streamBridgeStableRIFEHeight = snapshotModelHeight;
    }
    const message = String(snapshot.message || "");
    if (/Waiting for .*keyframe|decode failed|NAL parse failed|parameter sets/i.test(message)) {
      streamBridgeInputKeyframeNeeded = true;
    }
    const processed = Number(snapshot.processedFrames || 0);
    const now = performance.now();
    if (processed >= streamBridgeLastNativeProcessedFrames && streamBridgeLastNativeMetricsAt > 0) {
      const elapsedMs = now - streamBridgeLastNativeMetricsAt;
      if (elapsedMs >= 250) {
        const elapsed = elapsedMs / 1000;
        const instant = (processed - streamBridgeLastNativeProcessedFrames) / elapsed;
        const cap = Math.max(60, targetOutputFPS(streamOverlay) * 1.5);
        if (Number.isFinite(instant) && instant >= 0) {
          streamBridgeNativeProcessedFPS = Math.min(cap, instant);
        }
        streamBridgeLastNativeProcessedFrames = processed;
        streamBridgeLastNativeMetricsAt = now;
      }
      return;
    }
    streamBridgeLastNativeProcessedFrames = processed;
    streamBridgeLastNativeMetricsAt = now;
  }

  function streamBridgeCanSendDirectBinary() {
    return streamBridgeSocket?.readyState === WebSocket.OPEN && !streamBridgeViaServiceWorker;
  }

  function sendStreamPlaybackState(video, overlay, paused) {
    if (!streamBridgeCanSendDirectBinary() || !overlay) {
      return;
    }
    const state = Boolean(paused);
    if (overlay.lastPlaybackPaused === state) {
      return;
    }
    overlay.lastPlaybackPaused = state;
    if (state) {
      closeStreamBridgeOutputDecoder();
      streamBridgePendingOutputIds = [];
      streamBridgeDirectInFlight = 0;
      streamBridgeReturnKeyframeNeeded = true;
      clearAppOutputPresentation(overlay, true);
    } else {
      streamBridgeInputKeyframeNeeded = true;
      streamBridgeReturnKeyframeNeeded = true;
    }
    try {
      streamBridgeSocket.send(JSON.stringify({
        type: "playback_state",
        paused: state,
        currentTime: Number(video?.currentTime || 0),
        sentAtMs: Date.now()
      }));
    } catch (error) {
      streamBridgeLastError = runtimeErrorText(error) || "playback state send failed";
    }
  }

  function sendStreamBridgeConfig(overlay = null) {
    if (!streamBridgeCanSendDirectBinary()) {
      return false;
    }
    try {
      streamBridgeSocket.send(JSON.stringify({
        type: "bridge_config",
        targetFPS: targetOutputFPS(overlay || streamOverlay),
        flowInputHeight: appFlowInputHeight(),
        gpuBudgetMs: appGpuBudgetMs(),
        returnBitrateMbps: appReturnBitrateMbps(),
        rifeBackend: preferredRIFEBackend(),
        powerMode: appPowerMode(),
        powerTier: appPowerTier(),
        noCpuReadback: runtimeBooleanSetting("noCpuReadback", true),
        hevcMotionHints: runtimeBooleanSetting("hevcMotionHints", true),
        roiMotionBlocks: runtimeBooleanSetting("roiMotionBlocks", false),
        dynamicMultiFrame: shouldRequestMultiFrame(overlay || streamOverlay),
        sentAtMs: Date.now()
      }));
      return true;
    } catch (error) {
      streamBridgeLastError = runtimeErrorText(error) || "bridge config send failed";
      return false;
    }
  }

  function streamCodecId(codec) {
    const normalized = String(codec || "").toLowerCase();
    if (normalized.includes("hvc") || normalized.includes("hev")) {
      return 2;
    }
    if (normalized.includes("av1") || normalized.includes("av01")) {
      return 3;
    }
    return 1;
  }

  function streamCodecFromId(codec) {
    switch (Number(codec || 0)) {
      case 2: return "hvc1.1.6.L123.B0";
      case 3: return "av01.0.08M.08";
      case 1:
      default: return "avc1.64002a";
    }
  }

  function parseStreamBinaryOutput(buffer) {
    const arrayBuffer = buffer instanceof ArrayBuffer ? buffer : buffer?.buffer;
    const byteOffset = buffer instanceof Uint8Array ? buffer.byteOffset : 0;
    const byteLength = buffer instanceof Uint8Array ? buffer.byteLength : arrayBuffer?.byteLength;
    if (!arrayBuffer || byteLength < STREAM_BINARY_OUTPUT_HEADER_BYTES) {
      return null;
    }
    const view = new DataView(arrayBuffer, byteOffset, byteLength);
    if (view.getUint32(0, true) !== STREAM_BINARY_OUTPUT_MAGIC ||
        view.getUint16(4, true) !== STREAM_BINARY_OUTPUT_VERSION) {
      return null;
    }
    const flags = view.getUint16(6, true);
    const frameId = Number(view.getBigUint64(8, true));
    const duration = view.getFloat64(16, true);
    const gpuMs = view.getFloat64(24, true);
    const width = view.getUint32(32, true);
    const height = view.getUint32(36, true);
    const codec = view.getUint32(40, true);
    const payloadSize = view.getUint32(44, true);
    const codecDescriptionSize = view.getUint32(48, true);
    const processedFrames = Number(view.getBigUint64(52, true));
    const receivedFrames = Number(view.getBigUint64(60, true));
    const reserved = view.getUint32(68, true);
    const subIndex = reserved & 0xff;
    const subCount = (reserved >> 8) & 0xff;
    const payloadOffset = STREAM_BINARY_OUTPUT_HEADER_BYTES + codecDescriptionSize;
    if (payloadOffset + payloadSize > byteLength) {
      return null;
    }
    const bytes = new Uint8Array(arrayBuffer, byteOffset, byteLength);
    return {
      meta: {
        type: "processed_frame",
        outputPayloadKind: "webcodecs_video_chunk",
        outputCodec: streamCodecFromId(codec),
        codecDescription: codecDescriptionSize > 0
          ? Array.from(bytes.slice(STREAM_BINARY_OUTPUT_HEADER_BYTES, payloadOffset))
          : [],
        chunkType: (flags & STREAM_BINARY_FLAG_KEY) ? "key" : "delta",
        frameId,
        width,
        height,
        duration,
        gpuMs,
        processedFrames,
        receivedFrames,
        subIndex,
        subCount
      },
      payload: bytes.slice(payloadOffset, payloadOffset + payloadSize)
    };
  }

  function streamReturnCodecId(codec) {
    const normalized = String(codec || "").toLowerCase();
    if (normalized === "hevc" || normalized === "h265") {
      return 2;
    }
    return 1;
  }

  function streamPowerTierId() {
    const tier = appPowerTier().toLowerCase();
    if (tier.includes("静音") || tier.includes("效率") || tier.includes("silent") || tier.includes("quiet") || tier.includes("efficiency")) {
      return 0;
    }
    if (tier.includes("质量") || tier.includes("quality")) {
      return 2;
    }
    return 1;
  }

  function buildStreamBinaryFrame(meta, data) {
    if (!(data instanceof ArrayBuffer) && !(data instanceof Uint8Array)) {
      return null;
    }
    const payload = data instanceof Uint8Array ? data : new Uint8Array(data);
    const descriptionArray = Array.isArray(meta.codecDescription) ? meta.codecDescription : [];
    const description = new Uint8Array(descriptionArray.length);
    for (let i = 0; i < description.length; i += 1) {
      description[i] = Number(descriptionArray[i] || 0) & 0xff;
    }
    const out = new ArrayBuffer(STREAM_BINARY_FRAME_HEADER_BYTES + description.byteLength + payload.byteLength);
    const view = new DataView(out);
    let offset = 0;
    let flags = 0;
    if (meta.chunkType === "key") flags |= STREAM_BINARY_FLAG_KEY;
    if (meta.forceReturnKeyframe) flags |= STREAM_BINARY_FLAG_FORCE_RETURN_KEY;
    if (meta.noCpuReadback) flags |= STREAM_BINARY_FLAG_NO_CPU_READBACK;
    if (meta.powerMode === "unlimited") flags |= STREAM_BINARY_FLAG_UNLIMITED;
    if (meta.hevcMotionHints) flags |= STREAM_BINARY_FLAG_HEVC_MOTION_HINTS;
    if (meta.roiMotionBlocks) flags |= STREAM_BINARY_FLAG_ROI_MOTION_BLOCKS;
    if (meta.dynamicMultiFrame) flags |= STREAM_BINARY_FLAG_DYNAMIC_MULTI_FRAME;
    view.setUint32(offset, STREAM_BINARY_FRAME_MAGIC, true); offset += 4;
    view.setUint16(offset, STREAM_BINARY_FRAME_VERSION, true); offset += 2;
    view.setUint16(offset, flags, true); offset += 2;
    view.setBigUint64(offset, BigInt(Number(meta.frameId || 0)), true); offset += 8;
    view.setFloat64(offset, Number(meta.timestamp || 0), true); offset += 8;
    view.setFloat64(offset, Number(meta.duration || 0), true); offset += 8;
    view.setUint32(offset, Number(meta.width || 0), true); offset += 4;
    view.setUint32(offset, Number(meta.height || 0), true); offset += 4;
    view.setUint32(offset, streamCodecId(meta.payloadCodec || meta.codec), true); offset += 4;
    view.setUint32(offset, payload.byteLength, true); offset += 4;
    view.setFloat64(offset, Number(meta.targetFPS || targetOutputFPS()), true); offset += 8;
    view.setFloat64(offset, Number(meta.flowInputHeight || runtimeNumberSetting("flowInputHeight", 540)), true); offset += 8;
    view.setFloat64(offset, Number(meta.gpuBudgetMs || appGpuBudgetMs()), true); offset += 8;
    view.setUint32(offset, streamPowerTierId(), true); offset += 4;
    view.setUint32(offset, description.byteLength, true); offset += 4;
    view.setUint32(offset, streamReturnCodecId(meta.returnCodec || preferredReturnCodec()), true); offset += 4;
    view.setFloat64(offset, Number(meta.returnBitrateMbps || appReturnBitrateMbps()), true);
    const bytes = new Uint8Array(out);
    bytes.set(description, STREAM_BINARY_FRAME_HEADER_BYTES);
    bytes.set(payload, STREAM_BINARY_FRAME_HEADER_BYTES + description.byteLength);
    return out;
  }

  function sendStreamBridgeBinary(meta, data, frameId, byteLength) {
    if (!streamBridgeCanSendDirectBinary()) {
      return false;
    }
    const maxBufferedBytes = 8_000_000;
    if ((streamBridgeSocket?.bufferedAmount || 0) > maxBufferedBytes) {
      streamBridgeLastError = "input stream backpressured by app queue";
      return false;
    }
    try {
      const binaryFrame = meta?.payloadKind === "webcodecs_video_chunk"
        ? buildStreamBinaryFrame(meta, data)
        : null;
      if (binaryFrame) {
        streamBridgeSocket.send(binaryFrame);
      } else {
        streamBridgeSocket.send(JSON.stringify(meta));
        streamBridgeSocket.send(data);
      }
      streamBridgePendingOutputIds.push(frameId);
      const pendingLimit = Math.min(
        STREAM_APP_MAX_PENDING_FRAMES,
        Math.max(120, Math.ceil(targetOutputFPS(streamOverlay) * STREAM_APP_BUFFER_SECONDS * 1.25))
      );
      if (streamBridgePendingOutputIds.length > pendingLimit) {
        streamBridgePendingOutputIds = streamBridgePendingOutputIds.slice(-pendingLimit);
      }
      streamBridgeDirectInFlight += 1;
      noteStreamBridgeFrameSent(frameId);
      streamBridgeFramesSent += 1;
      streamBridgeBytesSent += byteLength || data?.byteLength || data?.size || 0;
      return true;
    } catch (error) {
      streamBridgeLastError = runtimeErrorText(error) || "direct frame send failed";
      streamBridgeConnected = false;
      connectServiceWorkerBridge(lastOnlineStatus || { running: true, browserDirect: true });
      return false;
    }
  }

  async function ensureStreamBridgeEncoder(video, overlay) {
    if (streamBridgeEncoder || streamBridgeEncoderInitializing) {
      return;
    }
    if (typeof VideoEncoder !== "function") {
      streamBridgeEncoderAvailable = false;
      streamBridgeEncodeFallbackReason = "WebCodecs VideoEncoder unavailable";
      return;
    }
    const width = overlay.curr.width;
    const height = overlay.curr.height;
    if (width < 16 || height < 16) {
      return;
    }
    streamBridgeEncoderInitializing = true;
    const sourceFPS = 1000 / Math.max(4, overlay.lastIntervalMs || 1000 / 30);
    const fps = Math.max(24, Math.min(240, sourceFPS > 1 ? sourceFPS : 30));
    const fpsCandidates = Array.from(new Set([Math.round(fps), 60, 30].filter((value) => value >= 24 && value <= 240)));
    try {
      let selected = null;
      let selectedConfig = null;
      let selectedFPS = fps;
      const unsupported = [];
      for (const candidate of STREAM_ENCODER_CANDIDATES) {
        for (const fpsCandidate of fpsCandidates) {
          const bitrate = Math.max(
            6_000_000,
            Math.min(48_000_000, Math.min(appReturnBitrateMbps() * 550_000, width * height * fpsCandidate * 0.22))
          );
          const config = {
            codec: candidate.codec,
            width,
            height,
            bitrate,
            framerate: fpsCandidate,
            latencyMode: "realtime",
            hardwareAcceleration: "prefer-hardware",
            ...candidate.extension
          };
          try {
            const support = await VideoEncoder.isConfigSupported(config);
            if (support?.supported) {
              selected = candidate;
              selectedConfig = support.config || config;
              selectedFPS = fpsCandidate;
              break;
            }
          } catch (error) {
            unsupported.push(`${candidate.label}@${fpsCandidate}: ${runtimeErrorText(error) || "unsupported"}`);
          }
        }
        if (selectedConfig) {
          break;
        }
      }
      if (!selected || !selectedConfig) {
        streamBridgeEncoderAvailable = false;
        streamBridgeEncodeFallbackReason = unsupported.length
          ? unsupported.join(" / ")
          : "WebCodecs hardware encoder config unsupported";
        return;
      }
      streamBridgeEncoder = new VideoEncoder({
        output: (chunk, metadata) => {
          const queued = streamBridgeEncoderFrameQueue.shift() || {};
          const encodeLatencyMs = queued.encodeStartedAt
            ? Math.max(0, performance.now() - queued.encodeStartedAt)
            : 0;
          if (encodeLatencyMs > 0) {
            streamBridgeInputEncodeLatencyMs = streamBridgeInputEncodeLatencyMs > 0
              ? streamBridgeInputEncodeLatencyMs * 0.82 + encodeLatencyMs * 0.18
              : encodeLatencyMs;
          }
          const data = new ArrayBuffer(chunk.byteLength);
          chunk.copyTo(data);
          const meta = {
            type: "frame_meta",
            payloadKind: "webcodecs_video_chunk",
            codec: selected.codec,
            payloadCodec: selected.payloadCodec,
            codecDescription: metadata?.decoderConfig?.description
              ? Array.from(new Uint8Array(metadata.decoderConfig.description))
              : undefined,
            bitstreamFormat: selected.extension.avc || selected.extension.hevc ? "annexb" : "config",
            frameId: queued.frameId || 0,
            sentAtMs: Date.now(),
            timestamp: Number(chunk.timestamp || queued.timestamp || 0),
            duration: Number(chunk.duration || queued.duration || 0),
            targetFPS: targetOutputFPS(overlay),
            returnCodec: preferredReturnCodec(),
            modelMode: preferredModelMode(),
            flowInputHeight: appFlowInputHeight(),
            gpuBudgetMs: appGpuBudgetMs(),
            returnBitrateMbps: appReturnBitrateMbps(),
            powerMode: appPowerMode(),
            powerTier: appPowerTier(),
            noCpuReadback: runtimeBooleanSetting("noCpuReadback", true),
            hevcMotionHints: runtimeBooleanSetting("hevcMotionHints", true),
            roiMotionBlocks: runtimeBooleanSetting("roiMotionBlocks", false),
            dynamicMultiFrame: shouldRequestMultiFrame(overlay),
            forceReturnKeyframe: forceReturnKeyframeNeeded(),
            chunkType: chunk.type,
            width,
            height,
            decodedFrames: overlay.decodedFrames,
            outputFrames: overlay.outputFrames
          };
          if (sendStreamBridgeBinary(meta, data, meta.frameId, chunk.byteLength)) {
            streamBridgeEncodedFramesSent += 1;
            streamBridgeEncoderCodec = selected.codec;
            streamBridgeEncoderDisplayCodec = selected.label;
            streamBridgeEncodeFallbackReason = "";
          }
        },
        error: (error) => {
          streamBridgeEncoderAvailable = false;
          streamBridgeEncodeFallbackReason = runtimeErrorText(error) || "WebCodecs encode failed";
          closeStreamBridgeEncoder();
        }
      });
      streamBridgeEncoder.configure(selectedConfig);
      streamBridgeEncoderKey = `${selected.codec}:${width}x${height}`;
      streamBridgeEncoderCodec = selected.codec;
      streamBridgeEncoderDisplayCodec = selected.label;
      streamBridgeEncodeFallbackReason = selectedFPS < targetOutputFPS(overlay)
        ? `input encoder configured ${selectedFPS}fps; output target ${targetOutputFPS(overlay)}fps`
        : "";
      streamBridgeEncoderAvailable = true;
    } catch (error) {
      streamBridgeEncoderAvailable = false;
      streamBridgeEncodeFallbackReason = runtimeErrorText(error) || "WebCodecs encoder init failed";
      closeStreamBridgeEncoder();
    } finally {
      streamBridgeEncoderInitializing = false;
    }
  }

  function sendEncodedVideoFrame(video, overlay, frameId, frame) {
    if (!frame || !streamBridgeCanSendDirectBinary()) {
      return false;
    }
    const keySuffix = `:${overlay.curr.width}x${overlay.curr.height}`;
    if (streamBridgeEncoderKey && !streamBridgeEncoderKey.endsWith(keySuffix)) {
      closeStreamBridgeEncoder();
    }
    if (!streamBridgeEncoder && streamBridgeEncoderAvailable !== false) {
      void ensureStreamBridgeEncoder(video, overlay);
      return false;
    }
    if (!streamBridgeEncoder || streamBridgeEncoder.encodeQueueSize > 2) {
      return false;
    }
    try {
      streamBridgeEncoderFrameQueue.push({
        frameId,
        encodeStartedAt: performance.now(),
        timestamp: Number(frame.timestamp || 0),
        duration: Number(frame.duration || 0)
      });
      if (streamBridgeEncoderFrameQueue.length > 16) {
        streamBridgeEncoderFrameQueue = streamBridgeEncoderFrameQueue.slice(-16);
      }
      const keyFrame = streamBridgeInputKeyframeNeeded || streamBridgeEncodedFramesSent === 0 || streamBridgeEncodedFramesSent % 60 === 0;
      if (keyFrame) {
        streamBridgeInputKeyframeNeeded = false;
      }
      streamBridgeEncoder.encode(frame, { keyFrame });
      return true;
    } catch (error) {
      streamBridgeEncoderAvailable = false;
      streamBridgeEncodeFallbackReason = runtimeErrorText(error) || "WebCodecs encode failed";
      closeStreamBridgeEncoder();
      return false;
    }
  }

  function streamInputThrottleReason(overlay, now) {
    if (!overlay || !streamBridgeCanSendDirectBinary()) {
      return "bridge unavailable";
    }
    pruneStaleStreamBridgeInFlight(now);
    const sourceFPS = sourceFPSForOverlay(overlay);
    if (streamBridgeEncoder?.encodeQueueSize > 1) {
      return "input encoder busy";
    }
    const appTargetFPS = targetOutputFPS(overlay);
    const capFPS = Math.min(120, Math.max(24, Math.min(appTargetFPS, sourceFPS || appTargetFPS)));
    const minIntervalMs = capFPS > 1 ? 1000 / capFPS : 16;
    if (now - Number(overlay.lastInputSendAt || 0) < minIntervalMs * 0.82) {
      return "input cadence limited";
    }
    return "";
  }

  function ensureStreamBridgeOutputDecoder(meta, overlay) {
    if (typeof VideoDecoder !== "function") {
      streamBridgeOutputDecodeFallbackReason = "WebCodecs VideoDecoder unavailable";
      return false;
    }
    const codec = String(meta?.outputCodec || meta?.codec || "avc1.64002a");
    const descriptionArray = Array.isArray(meta?.codecDescription) ? meta.codecDescription : [];
    const key = `${codec}:${meta?.width || overlay.curr.width}x${meta?.height || overlay.curr.height}`;
    if (descriptionArray.length > 0) {
      streamBridgeOutputCodecDescriptionCache.set(key, descriptionArray);
    }
    if (streamBridgeOutputDecoder && streamBridgeOutputDecoderKey === key) {
      return true;
    }
    closeStreamBridgeOutputDecoder();
    try {
      streamBridgeOutputDecoder = new VideoDecoder({
        output: (frame) => {
          const stamp = Number(frame?.timestamp || 0);
          const frameMeta = streamBridgeOutputDecodeMetaByTimestamp.get(stamp) || meta || {};
          streamBridgeOutputDecodeMetaByTimestamp.delete(stamp);
          let queuedOwnsFrame = false;
          queueAppOutputFrame(overlay, frame, frameMeta).then((queued) => {
            queuedOwnsFrame = queued === "direct";
            if (queued) {
              overlay.processedFrames = (overlay.processedFrames || 0) + 1;
              streamBridgeOutputDecodedFrames += 1;
              ackStreamBridgeProcessedFrame(frameMeta, overlay.processedFrames);
              streamBridgeOutputDecodeFallbackReason = "";
              streamBridgeReturnKeyframeNeeded = false;
            }
            updateBadge(lastOnlineStatus || { running: true, browserDirect: true });
          }).catch((error) => {
            streamBridgeOutputDecodeFallbackReason = runtimeErrorText(error) || "output queue failed";
          }).finally(() => {
            if (!queuedOwnsFrame) {
              closeVideoFrame(frame);
            }
          });
        },
        error: (error) => {
          const text = runtimeErrorText(error) || "output decode failed";
          streamBridgeOutputDecodeFallbackReason = text;
          streamBridgeOutputDecodeErrors += 1;
          streamBridgeReturnKeyframeNeeded = true;
          closeStreamBridgeOutputDecoder();
        }
      });
      const config = { codec };
      const cachedDescription = descriptionArray.length > 0
        ? descriptionArray
        : (streamBridgeOutputCodecDescriptionCache.get(key) || []);
      if (cachedDescription.length > 0) {
        config.description = new Uint8Array(cachedDescription);
      }
      streamBridgeOutputDecoder.configure(config);
      streamBridgeOutputDecoderKey = key;
      streamBridgeOutputDecodeFallbackReason = "";
      return true;
    } catch (error) {
      const text = runtimeErrorText(error) || "output decoder init failed";
      streamBridgeOutputDecodeFallbackReason = text;
      streamBridgeOutputDecodeErrors += 1;
      streamBridgeReturnKeyframeNeeded = true;
      closeStreamBridgeOutputDecoder();
      return false;
    }
  }

  function applyProcessedVideoChunk(data, frameId = 0, metaOverride = null) {
    const overlay = streamOverlay;
    const meta = metaOverride || streamBridgePendingProcessedMeta || {};
    if (!overlay || !data || !ensureStreamBridgeOutputDecoder(meta, overlay)) {
      return false;
    }
    try {
      const chunkType = meta.chunkType === "delta" ? "delta" : "key";
      if (chunkType === "delta" && (streamBridgeReturnKeyframeNeeded || streamBridgeOutputDecodedFrames === 0)) {
        streamBridgeOutputDecodeFallbackReason = "waiting for return keyframe";
        streamBridgeReturnKeyframeNeeded = true;
        clearAppOutputPresentation(overlay, false);
        return true;
      }
      const timestamp = streamBridgeOutputChunkTimestamp++;
      streamBridgeOutputDecodeMetaByTimestamp.set(timestamp, meta);
      if (streamBridgeOutputDecodeMetaByTimestamp.size > 192) {
        const first = streamBridgeOutputDecodeMetaByTimestamp.keys().next();
        if (!first.done) {
          streamBridgeOutputDecodeMetaByTimestamp.delete(first.value);
        }
      }
      const chunk = new EncodedVideoChunk({
        type: chunkType,
        timestamp,
        duration: Number(meta.duration || Math.round(1000000 / targetOutputFPS())),
        data: data instanceof ArrayBuffer ? new Uint8Array(data) : data
      });
      streamBridgeOutputDecoder.decode(chunk);
      return true;
    } catch (error) {
      const text = runtimeErrorText(error) || "output chunk decode failed";
      streamBridgeOutputDecodeFallbackReason = text;
      streamBridgeOutputDecodeErrors += 1;
      streamBridgeReturnKeyframeNeeded = true;
      closeStreamBridgeOutputDecoder();
      return false;
    }
  }

  function closeVideoFrame(frame) {
    try {
      frame?.close?.();
    } catch (_) {
    }
  }

  async function queueAppOutputFrame(overlay, source, meta = null) {
    if (!overlay || !source) {
      return false;
    }
    try {
      const video = overlay.video || primaryVideo();
      if (!video || streamBypassActive(video)) {
        if (video) {
          sendStreamPlaybackState(video, overlay, true);
        }
        clearAppOutputPresentation(overlay, false);
        return false;
      }
      if (video) {
        sizeStreamOverlay(video, overlay);
      }
      const sourceWidth = Number(source.displayWidth || source.videoWidth || source.width || meta?.width || overlay.curr.width || 0);
      const sourceHeight = Number(source.displayHeight || source.videoHeight || source.height || meta?.height || overlay.curr.height || 0);
      let queuedSource = null;
      let directVideoFrame = false;
      if (typeof VideoFrame === "function" && source instanceof VideoFrame) {
        queuedSource = source;
        directVideoFrame = true;
      } else if (typeof createImageBitmap === "function") {
        queuedSource = await createImageBitmap(source);
      } else {
        const canvas = document.createElement("canvas");
        const ctx = canvas.getContext("2d");
        resizeCanvas(canvas, Math.max(2, Math.round(sourceWidth)), Math.max(2, Math.round(sourceHeight)));
        ctx.drawImage(source, 0, 0, canvas.width, canvas.height);
        queuedSource = canvas;
      }
      overlay.appOutputQueue.push({
        source: queuedSource,
        meta: meta || null,
        queuedAt: performance.now(),
        width: sourceWidth,
        height: sourceHeight
      });
      trimAppOutputQueue(overlay, performance.now());
      overlay.lastAppOutputAt = performance.now();
      overlay.lastDrawError = "";
      return directVideoFrame ? "direct" : true;
    } catch (error) {
      overlay.drawErrors += 1;
      overlay.lastDrawError = runtimeErrorText(error) || "app output queue unavailable";
      return false;
    }
  }

  function closeQueuedOutput(item) {
    try {
      item?.source?.close?.();
    } catch (_) {
    }
  }

  function trimAppOutputQueue(overlay, now) {
    if (!overlay?.appOutputQueue) {
      return;
    }
    const targetFPS = targetOutputFPS(overlay);
    const maxFrames = Math.max(3, Math.ceil(targetFPS * STREAM_PRESENTATION_MAX_BUFFER_MS / 1000));
    while (overlay.appOutputQueue.length > maxFrames) {
      closeQueuedOutput(overlay.appOutputQueue.shift());
    }
    while (overlay.appOutputQueue.length > STREAM_PRESENTATION_PREROLL_FRAMES) {
      const oldest = overlay.appOutputQueue[0];
      if (!oldest || now - Number(oldest.queuedAt || now) <= STREAM_PRESENTATION_MAX_BUFFER_MS) {
        break;
      }
      closeQueuedOutput(overlay.appOutputQueue.shift());
    }
  }

  function drawAppOutputFrame(overlay, item, now) {
    if (!overlay || !item?.source) {
      return false;
    }
    try {
      setStreamVideoCovered(overlay, true);
      overlay.canvas.style.display = "block";
      overlay.ctx.clearRect(0, 0, overlay.canvas.width, overlay.canvas.height);
      overlay.ctx.imageSmoothingEnabled = true;
      overlay.ctx.imageSmoothingQuality = "high";
      overlay.ctx.globalAlpha = 1;
      const previous = overlay.processedBitmap;
      overlay.processedBitmap = item.source;
      drawContain(overlay.ctx, item.source, overlay);
      if (previous && previous !== item.source) {
        try {
          previous.close?.();
        } catch (_) {
        }
      }
      overlay.outputFrames += 1;
      overlay.appOutputStarted = true;
      if (overlay.lastPresentAt > 0) {
        const gap = now - Number(overlay.lastPresentAt || now);
        overlay.lastPresentGapMs = gap;
        overlay.maxPresentGapMs = Math.max(Number(overlay.maxPresentGapMs || 0), gap);
      }
      overlay.lastPresentAt = now;
      overlay.lastDrawError = "";
      overlay.currentAppOutputMeta = item.meta || null;
      return true;
    } catch (error) {
      overlay.drawErrors += 1;
      overlay.lastDrawError = runtimeErrorText(error) || "app output present unavailable";
      return false;
    }
  }

  function recoverStalledAppOutput(video, overlay, now, reason) {
    if (!overlay || !video || streamBypassActive(video)) {
      return false;
    }
    if (now - Number(overlay.lastOutputRecoverAt || 0) < STREAM_OUTPUT_STALL_RECOVER_MS) {
      return false;
    }
    overlay.lastOutputRecoverAt = now;
    overlay.lastDrawError = reason || "return decoder stalled; requesting keyframe";
    streamBridgeReturnKeyframeNeeded = true;
    streamBridgeInputKeyframeNeeded = true;
    streamBridgeOutputDecodeFallbackReason = overlay.lastDrawError;
    closeStreamBridgeOutputDecoder();
    clearAppOutputPresentation(overlay, false);
    setStreamVideoCovered(overlay, false);
    overlay.canvas.style.display = "none";
    overlay.appOutputStarted = false;
    overlay.lastPresentAt = now;
    sendStreamBridgeConfig(overlay);
    return true;
  }

  function ensureStreamOverlay() {
    if (streamOverlay) {
      return streamOverlay;
    }

    const canvas = document.createElement("canvas");
    canvas.dataset.stellariaMotionOutput = "true";
    canvas.style.cssText = [
      "position:absolute",
      "z-index:1",
      "display:none",
      "pointer-events:none",
      "background:#000",
      "object-fit:contain",
      "contain:strict"
    ].join(";");

    const prev = document.createElement("canvas");
    const curr = document.createElement("canvas");
    streamOverlay = {
      canvas,
      ctx: canvas.getContext("2d"),
      prev,
      prevCtx: prev.getContext("2d"),
      curr,
      currCtx: curr.getContext("2d"),
      host: null,
      hostPositionTouched: false,
      videoOriginalOpacity: "",
      videoOriginalVisibility: "",
      videoStyleHidden: false,
      lastPlaybackPaused: null,
      activeFrameId: 0,
      sequenceStartedAt: performance.now(),
      running: false,
      raf: 0,
      vfc: 0,
      decodedFrames: 0,
      outputFrames: 0,
      drawErrors: 0,
      lastDrawError: "",
      processedBitmap: null,
      appOutputCanvas: null,
      appOutputCtx: null,
      appOutputQueue: [],
      lastAppOutputAt: 0,
      lastOutputRecoverAt: 0,
      appOutputStarted: false,
      lastInputSendAt: 0,
      lastInputThrottleReason: "",
      processedFrames: 0,
      processedLatencyMs: 0,
      lastUsableCheckAt: 0,
      lastSourceUsable: true,
      directFrames: 0,
      directTrackStalls: 0,
      pendingVideoFrame: null,
      directFrameReader: null,
      directFrameTrack: null,
      directFrameActive: false,
      videoFrameFallbackActive: false,
      lastDecodeAt: performance.now(),
      lastMediaTime: 0,
      lastIntervalMs: 1000 / 24,
      lastPresentAt: performance.now(),
      lastPresentGapMs: 0,
      maxPresentGapMs: 0,
      presentationUnderflows: 0,
      lastUnderflowAt: 0,
      nextPresentAt: performance.now(),
      lastReportAt: performance.now(),
      lastMetricsAt: performance.now(),
      lastMetricsDecoded: 0,
      lastMetricsOutput: 0,
      lastMetricsProcessed: 0,
      inputFPS: 0,
      outputFPS: 0,
      processedFPS: 0,
      stableSourceFPS: 0,
      interpolationActive: true,
      mediaAspect: 16 / 9,
      contentRect: { x: 0, y: 0, width: 1, height: 1 },
      layoutDirty: true,
      lastLayoutAt: 0,
      lastBadgeLayoutAt: 0,
      lastBadgeTextAt: 0
    };
    return streamOverlay;
  }

  function sizeStreamOverlay(video, overlay) {
    const now = performance.now();
    if (!overlay.layoutDirty &&
        overlay.canvas.width > 1 &&
        overlay.canvas.height > 1 &&
        now - Number(overlay.lastLayoutAt || 0) < 250) {
      return;
    }
    overlay.lastLayoutAt = now;
    overlay.layoutDirty = false;
    const rect = video.getBoundingClientRect();
    const fullscreenElement = document.fullscreenElement || document.webkitFullscreenElement || null;
    const host = fullscreenElement && fullscreenElement !== video && fullscreenElement.contains(video)
      ? fullscreenElement
      : (video.parentElement || document.documentElement);
    if (overlay.host !== host) {
      overlay.layoutDirty = true;
      if (overlay.hostPositionTouched && overlay.host?.dataset?.stellariaMotionPositionTouched === "1") {
        overlay.host.style.position = "";
        delete overlay.host.dataset.stellariaMotionPositionTouched;
      }
      overlay.host = host;
      overlay.hostPositionTouched = false;
      const hostStyle = window.getComputedStyle(host);
      if (host !== document.documentElement && hostStyle.position === "static") {
        host.style.position = "relative";
        host.dataset.stellariaMotionPositionTouched = "1";
        overlay.hostPositionTouched = true;
      }
      host.appendChild(overlay.canvas);
    }
    const hostRect = host === document.documentElement
      ? { left: 0, top: 0 }
      : host.getBoundingClientRect();
    const left = Math.max(0, rect.left);
    const top = Math.max(0, rect.top);
    const right = Math.min(window.innerWidth, rect.right);
    const bottom = Math.min(window.innerHeight, rect.bottom);
    const width = Math.max(2, Math.round(right - left));
    const height = Math.max(2, Math.round(bottom - top));
    const dpr = Math.max(1, Math.min(2, Number(window.devicePixelRatio || 1)));
    const pixelWidth = Math.max(2, Math.round(width * dpr));
    const pixelHeight = Math.max(2, Math.round(height * dpr));
    const aspect = mediaAspect(video);
    const content = containRect(pixelWidth, pixelHeight, aspect);
    const sourceWidth = Math.max(2, Number(video.videoWidth || 0) || content.width);
    const sourceHeight = Math.max(2, Number(video.videoHeight || 0) || content.height);
    const maxFrameWidth = STREAM_CAPTURE_MAX_WIDTH;
    const maxFrameHeight = STREAM_CAPTURE_MAX_HEIGHT;
    const areaScale = Math.sqrt(STREAM_CAPTURE_MAX_PIXELS / Math.max(1, sourceWidth * sourceHeight));
    const scale = Math.min(1, maxFrameWidth / sourceWidth, maxFrameHeight / sourceHeight, areaScale);
    const frameWidth = evenDimension(sourceWidth * scale);
    const frameHeight = evenDimension(sourceHeight * scale);
    const contentChanged = !overlay.contentRect ||
      overlay.contentRect.x !== content.x ||
      overlay.contentRect.y !== content.y ||
      overlay.contentRect.width !== content.width ||
      overlay.contentRect.height !== content.height ||
      Math.abs((overlay.mediaAspect || 0) - aspect) > 0.001;
    overlay.mediaAspect = aspect;
    overlay.contentRect = content;

    overlay.canvas.style.left = `${Math.round(left - hostRect.left)}px`;
    overlay.canvas.style.top = `${Math.round(top - hostRect.top)}px`;
    overlay.canvas.style.width = `${width}px`;
    overlay.canvas.style.height = `${height}px`;

    const presentationChanged = overlay.canvas.width !== pixelWidth ||
      overlay.canvas.height !== pixelHeight ||
      contentChanged;
    const captureChanged = overlay.curr.width !== frameWidth ||
      overlay.curr.height !== frameHeight ||
      Math.abs((overlay.captureAspect || 0) - (sourceWidth / Math.max(1, sourceHeight))) > 0.001;
    if (presentationChanged) {
      overlay.canvas.width = pixelWidth;
      overlay.canvas.height = pixelHeight;
      if (overlay.processedBitmap) {
        try {
          overlay.ctx?.clearRect(0, 0, overlay.canvas.width, overlay.canvas.height);
          overlay.ctx.globalAlpha = 1;
          drawContain(overlay.ctx, overlay.processedBitmap, overlay);
        } catch (_) {
        }
      }
    }
    if (captureChanged) {
      overlay.prev.width = frameWidth;
      overlay.prev.height = frameHeight;
      overlay.curr.width = frameWidth;
      overlay.curr.height = frameHeight;
      overlay.captureAspect = sourceWidth / Math.max(1, sourceHeight);
      overlay.decodedFrames = 0;
      overlay.outputFrames = 0;
      overlay.processedFrames = 0;
      overlay.activeFrameId = 0;
      overlay.inputFPS = 0;
      overlay.outputFPS = 0;
      overlay.lastMetricsAt = performance.now();
      overlay.lastMetricsDecoded = 0;
      overlay.lastMetricsOutput = 0;
      overlay.lastMetricsProcessed = 0;
      overlay.lastMediaTime = 0;
      closeStreamBridgeEncoder();
      closeStreamBridgeOutputDecoder();
      clearAppOutputPresentation(overlay, true);
      overlay.processedLatencyMs = 0;
    }
  }

  function nativeVideoFullscreen(video) {
    const fullscreenElement = document.fullscreenElement || document.webkitFullscreenElement || null;
    return fullscreenElement === video || video.webkitDisplayingFullscreen === true;
  }

  function streamBypassActive(video) {
    return !video || video.paused || video.ended || nativeVideoFullscreen(video);
  }

  function setStreamVideoCovered(overlay, covered) {
    const video = overlay?.video;
    if (!video) {
      return;
    }
    if (covered) {
      if (!overlay.videoStyleHidden) {
        overlay.videoOriginalOpacity = video.style.opacity || "";
        overlay.videoOriginalVisibility = video.style.visibility || "";
      }
      video.style.opacity = "0";
      overlay.videoStyleHidden = true;
      return;
    }
    if (overlay.videoStyleHidden) {
      video.style.opacity = overlay.videoOriginalOpacity || "";
      if (overlay.videoOriginalVisibility) {
        video.style.visibility = overlay.videoOriginalVisibility;
      }
    }
    overlay.videoStyleHidden = false;
  }

  function stopDirectVideoFrames(overlay) {
    if (!overlay) {
      return;
    }
    overlay.directFrameActive = false;
    if (overlay.directFrameReader) {
      try {
        overlay.directFrameReader.cancel();
      } catch (_) {
      }
      overlay.directFrameReader = null;
    }
    if (overlay.directFrameTrack) {
      try {
        overlay.directFrameTrack.stop();
      } catch (_) {
      }
      overlay.directFrameTrack = null;
    }
    closeVideoFrame(overlay.pendingVideoFrame);
    overlay.pendingVideoFrame = null;
  }

  function ensureVideoFrameFallback(video, overlay) {
    if (!overlay?.running || overlay.video !== video || overlay.videoFrameFallbackActive) {
      return;
    }
    overlay.videoFrameFallbackActive = true;
    scheduleVideoFrame(video, overlay);
  }

  function startDirectVideoFrames(video, overlay) {
    const captureStream = video.captureStream || video.mozCaptureStream || video.webkitCaptureStream;
    if (typeof captureStream !== "function" || typeof MediaStreamTrackProcessor !== "function") {
      overlay.directFrameActive = false;
      return false;
    }
    try {
      const stream = captureStream.call(video);
      const track = stream?.getVideoTracks?.()[0];
      if (!track) {
        overlay.directFrameActive = false;
        return false;
      }
      const processor = new MediaStreamTrackProcessor({ track });
      const reader = processor.readable.getReader();
      overlay.directFrameTrack = track;
      overlay.directFrameReader = reader;
      overlay.directFrameActive = true;
      overlay.directFrames = 0;
      (async () => {
        try {
          while (overlay.running && overlay.video === video && overlay.directFrameActive) {
            const result = await reader.read();
            if (result.done || !result.value) {
              break;
            }
            closeVideoFrame(overlay.pendingVideoFrame);
            overlay.pendingVideoFrame = result.value;
            overlay.directFrames += 1;
            copyVideoFrame(video, overlay);
          }
          if (overlay.running && overlay.video === video && overlay.directFrameActive) {
            overlay.lastDrawError = "TrackProcessor ended; fallback to video callback";
            stopDirectVideoFrames(overlay);
            ensureVideoFrameFallback(video, overlay);
          }
        } catch (error) {
          if (overlay.running && overlay.video === video) {
            overlay.lastDrawError = `TrackProcessor: ${runtimeErrorText(error) || "unavailable"}`;
            stopDirectVideoFrames(overlay);
            ensureVideoFrameFallback(video, overlay);
          }
        }
      })();
      return true;
    } catch (error) {
      overlay.lastDrawError = `TrackProcessor: ${runtimeErrorText(error) || "unavailable"}`;
      overlay.directFrameActive = false;
      return false;
    }
  }

  function copyVideoFrame(video, overlay, metadata = null) {
    if (streamBypassActive(video)) {
      sendStreamPlaybackState(video, overlay, true);
      closeVideoFrame(overlay.pendingVideoFrame);
      overlay.pendingVideoFrame = null;
      overlay.activeFrameId = 0;
      return;
    }
    sendStreamPlaybackState(video, overlay, false);
    if (video.readyState < 2 ||
        (video.videoWidth || 0) < 2 ||
        (video.videoHeight || 0) < 2 ||
        overlay.curr.width < 2 ||
        overlay.curr.height < 2) {
      return;
    }
    const now = performance.now();
    const mediaTime = Number(metadata?.mediaTime ?? video.currentTime ?? 0);
    const mediaDeltaMs = mediaTime > 0 && Number(overlay.lastMediaTime || 0) > 0
      ? (mediaTime - Number(overlay.lastMediaTime || 0)) * 1000
      : 0;
    const callbackInterval = now - overlay.lastDecodeAt;
    const interval = mediaDeltaMs > 4 && mediaDeltaMs < 1000 ? mediaDeltaMs : callbackInterval;
    if (interval > 4 && interval < 1000) {
      overlay.lastIntervalMs = interval;
      const instantFPS = 1000 / Math.max(4, interval);
      overlay.stableSourceFPS = overlay.stableSourceFPS > 0
        ? overlay.stableSourceFPS * 0.92 + instantFPS * 0.08
        : instantFPS;
    }
    if (mediaTime > 0) {
      overlay.lastMediaTime = mediaTime;
    }
    const frameId = streamBridgeNextFrameId++;
    try {
      const throttleReason = streamInputThrottleReason(overlay, now);
      if (throttleReason) {
        overlay.lastInputThrottleReason = throttleReason;
        closeVideoFrame(overlay.pendingVideoFrame);
        overlay.pendingVideoFrame = null;
        overlay.lastDecodeAt = now;
        return;
      }
      const directFrame = overlay.pendingVideoFrame;
      const source = directFrame || video;
      overlay.pendingVideoFrame = null;
      if (!directFrame) {
        overlay.currCtx.clearRect(0, 0, overlay.curr.width, overlay.curr.height);
        overlay.currCtx.imageSmoothingEnabled = true;
        overlay.currCtx.imageSmoothingQuality = "high";
        overlay.currCtx.drawImage(source, 0, 0, overlay.curr.width, overlay.curr.height);
      }
      overlay.lastDrawError = "";
      let encodeFrame = directFrame;
      let canvasFrame = null;
      if (!encodeFrame && typeof VideoFrame === "function") {
        const timestamp = mediaTime > 0
          ? Math.round(mediaTime * 1000000)
          : Math.round(now * 1000);
        const duration = Number.isFinite(interval) && interval > 4
          ? Math.round(interval * 1000)
          : Math.round(1000000 / Math.max(1, sourceFPSForOverlay(overlay) || 24));
        canvasFrame = new VideoFrame(overlay.curr, {
          timestamp,
          duration
        });
        encodeFrame = canvasFrame;
      }
      const encodedSent = sendEncodedVideoFrame(video, overlay, frameId, encodeFrame);
      if (encodedSent) {
        overlay.lastInputSendAt = now;
        overlay.lastInputThrottleReason = "";
      }
      closeVideoFrame(canvasFrame);
      closeVideoFrame(directFrame);
      if (!encodedSent && streamBridgeEncoderAvailable === false) {
        streamBridgeLastError = streamBridgeEncodeFallbackReason || "input hardware encoder unavailable";
      }
    } catch (error) {
      closeVideoFrame(overlay.pendingVideoFrame);
      overlay.pendingVideoFrame = null;
      overlay.drawErrors += 1;
      overlay.lastDrawError = runtimeErrorText(error) || "drawImage unavailable";
      return;
    }
    overlay.lastDecodeAt = now;
    overlay.decodedFrames += 1;
  }

  function scheduleVideoFrame(video, overlay) {
    if (!overlay.running) {
      return;
    }
    if (typeof video.requestVideoFrameCallback === "function") {
      overlay.vfc = video.requestVideoFrameCallback((_, metadata) => {
        try {
          copyVideoFrame(video, overlay, metadata);
        } catch (error) {
          overlay.drawErrors += 1;
          overlay.lastDrawError = runtimeErrorText(error) || "video callback unavailable";
        } finally {
          scheduleVideoFrame(video, overlay);
        }
      });
      return;
    }
    setTimeout(() => {
      try {
        copyVideoFrame(video, overlay);
      } catch (error) {
        overlay.drawErrors += 1;
        overlay.lastDrawError = runtimeErrorText(error) || "timer capture unavailable";
      } finally {
        scheduleVideoFrame(video, overlay);
      }
    }, 1000 / 30);
  }

  function targetOutputFPS(overlay = null) {
    (void overlay);
    const target = Number(lastOnlineStatus?.targetFPS || lastOnlineStatus?.runtimeSettings?.targetFps || 0);
    const requested = Number.isFinite(target) && target > 0 ? target : STREAM_PRESENTATION_TARGET_FPS;
    const capped = lastOnlineStatus?.browserDirect ? Math.min(60, requested) : requested;
    return Math.max(24, Math.min(240, capped));
  }

  function shouldRequestMultiFrame(overlay = null) {
    (void overlay);
    if (lastOnlineStatus?.browserDirect) {
      return true;
    }
    return runtimeBooleanSetting("dynamicMultiFrame", false);
  }

  function runtimeBooleanSetting(key, fallback) {
    const value = lastOnlineStatus?.runtimeSettings?.[key];
    return typeof value === "boolean" ? value : fallback;
  }

  function runtimeNumberSetting(key, fallback) {
    const value = Number(lastOnlineStatus?.runtimeSettings?.[key]);
    return Number.isFinite(value) && value > 0 ? value : fallback;
  }

  function preferredReturnCodec() {
    const runtimeCodec = String(lastOnlineStatus?.runtimeSettings?.preferredReturnCodec || "").toLowerCase();
    if (runtimeCodec === "hevc" || runtimeCodec === "h265") {
      return "hevc";
    }
    if (runtimeCodec === "h264" || runtimeCodec === "avc") {
      return "h264";
    }
    return "h264";
  }

  function forceReturnKeyframeNeeded() {
    return streamBridgeReturnKeyframeNeeded ||
      !streamBridgeOutputDecoder ||
      streamBridgeOutputDecodeFallbackReason.length > 0 ||
      streamBridgeOutputDecodedFrames === 0;
  }

  function preferredModelMode() {
    return "rife";
  }

  function preferredRIFEBackend() {
    const backend = String(lastOnlineStatus?.runtimeSettings?.rifeBackend || "").toLowerCase();
    if (backend === "stellaria_sp4_a1p" ||
        backend === "metal_int4_experimental" ||
        backend === "mpsgraph_fp32_debug" ||
        backend === "mpsgraph_fp16_target") {
      return backend;
    }
    return "stellaria_sp4_a1p";
  }

  function directTrackProcessorAllowed() {
    return runtimeBooleanSetting("browserDirectTrackProcessor", false);
  }

  function appPowerMode() {
    if (lastOnlineStatus?.browserDirect) {
      return "adaptive";
    }
    const explicit = String(lastOnlineStatus?.runtimeSettings?.powerMode || "").toLowerCase();
    if (explicit === "unlimited") {
      return explicit;
    }
    return "adaptive";
  }

  function appPowerTier() {
    const tier = String(lastOnlineStatus?.runtimeSettings?.powerTier || "均衡");
    if (lastOnlineStatus?.browserDirect && /质量|quality|ultimate/i.test(tier)) {
      return "均衡";
    }
    return tier;
  }

  function appFlowInputHeight() {
    const requested = runtimeNumberSetting("flowInputHeight", 432);
    if (!lastOnlineStatus?.browserDirect) {
      return requested;
    }
    const tier = appPowerTier();
    const browserCap = /静音|quiet/i.test(tier) ? 288 : 360;
    return Math.max(128, Math.min(browserCap, requested));
  }

  function appGpuBudgetMs() {
    const explicit = Number(lastOnlineStatus?.runtimeSettings?.gpuBudgetMs);
    if (lastOnlineStatus?.browserDirect) {
      return Math.min(16.67, Number.isFinite(explicit) && explicit > 0 ? explicit : 16.67);
    }
    if (Number.isFinite(explicit) && explicit > 0) {
      return explicit;
    }
    return 16.67;
  }

  function appReturnBitrateMbps() {
    const explicit = Number(lastOnlineStatus?.runtimeSettings?.returnBitrateMbps);
    return Math.max(12, Math.min(120, Number.isFinite(explicit) && explicit > 0 ? explicit : 60));
  }

  function sourceFPSForOverlay(overlay) {
    const stable = Number(overlay?.stableSourceFPS || 0);
    if (stable > 0) {
      return stable;
    }
    const interval = Number(overlay?.lastIntervalMs || 0);
    return interval > 0 ? 1000 / Math.max(4, interval) : 0;
  }

  function scheduleStreamRender(video, overlay) {
    if (!overlay.running) {
      return;
    }
    overlay.raf = requestAnimationFrame(() => renderStreamOverlay(video, overlay));
  }

  function renderStreamOverlay(video, overlay) {
    if (!overlay.running) {
      return;
    }
    if (video.ended) {
      sendStreamPlaybackState(video, overlay, true);
      clearAppOutputPresentation(overlay, true);
      scheduleStreamRender(video, overlay);
      return;
    }

    sizeStreamOverlay(video, overlay);
    if (streamBypassActive(video)) {
      sendStreamPlaybackState(video, overlay, true);
      clearAppOutputPresentation(overlay, true);
      overlay.activeFrameId = 0;
      overlay.outputFPS = 0;
      overlay.lastPresentAt = performance.now();
      overlay.raf = requestAnimationFrame(() => renderStreamOverlay(video, overlay));
      return;
    }
    sendStreamPlaybackState(video, overlay, false);
    const now = performance.now();
    if (overlay.directFrameActive &&
        !overlay.videoFrameFallbackActive &&
        now - Number(overlay.sequenceStartedAt || now) >= STREAM_DIRECT_TRACK_WARMUP_MS &&
        now - Number(overlay.lastDecodeAt || now) >= STREAM_DIRECT_TRACK_STALL_MS) {
      overlay.directTrackStalls = Number(overlay.directTrackStalls || 0) + 1;
      overlay.lastDrawError = "TrackProcessor stalled; fallback to video callback";
      stopDirectVideoFrames(overlay);
      ensureVideoFrameFallback(video, overlay);
    }
    trimAppOutputQueue(overlay, now);
    const nativeProcessedFrames = Number(streamBridgeLastSnapshot?.processedFrames || 0);
    const appIsProducing = nativeProcessedFrames > Number(overlay.processedFrames || 0) + 2 ||
      streamBridgeNativeProcessedFPS > 1 ||
      Number(streamBridgeLastSnapshot?.realtimeOutputFPS || 0) > 1;
    const outputIdleForMs = now - Number(overlay.lastAppOutputAt || overlay.lastPresentAt || now);
    if (overlay.appOutputStarted &&
        appIsProducing &&
        outputIdleForMs > STREAM_OUTPUT_STALL_RECOVER_MS &&
        overlay.appOutputQueue.length === 0) {
      if (recoverStalledAppOutput(video, overlay, now, `return output stalled ${Math.round(outputIdleForMs)}ms; requesting keyframe`)) {
        scheduleStreamRender(video, overlay);
        return;
      }
    }
    const targetFPS = targetOutputFPS(overlay);
    const frameIntervalMs = 1000 / Math.max(1, targetFPS);
    const queueReady = overlay.appOutputQueue.length >= STREAM_PRESENTATION_PREROLL_FRAMES ||
      (overlay.appOutputQueue.length > 0 &&
        now - Number(overlay.appOutputQueue[0]?.queuedAt || now) >= STREAM_PRESENTATION_TARGET_BUFFER_MS);
    try {
      if (queueReady && now + 1 >= Number(overlay.nextPresentAt || 0)) {
        const item = overlay.appOutputQueue.shift();
        drawAppOutputFrame(overlay, item, now);
        overlay.nextPresentAt = Math.max(now + frameIntervalMs, Number(overlay.nextPresentAt || now) + frameIntervalMs);
      } else if (overlay.appOutputStarted && overlay.processedBitmap) {
        if (!overlay.appOutputQueue.length && now + 1 >= Number(overlay.nextPresentAt || 0)) {
          overlay.presentationUnderflows = Number(overlay.presentationUnderflows || 0) + 1;
          overlay.lastUnderflowAt = now;
          overlay.nextPresentAt = now + frameIntervalMs;
        }
        setStreamVideoCovered(overlay, true);
        overlay.canvas.style.display = "block";
      } else if (!overlay.appOutputQueue.length) {
        setStreamVideoCovered(overlay, false);
        overlay.canvas.style.display = "none";
      }
      overlay.lastDrawError = "";
    } catch (error) {
      overlay.drawErrors += 1;
      overlay.lastDrawError = runtimeErrorText(error) || "present unavailable";
    }

    if (now - overlay.lastMetricsAt > 1000) {
      const elapsed = Math.max(1, now - overlay.lastMetricsAt) / 1000;
      overlay.inputFPS = (overlay.decodedFrames - overlay.lastMetricsDecoded) / elapsed;
      overlay.outputFPS = (overlay.outputFrames - overlay.lastMetricsOutput) / elapsed;
      overlay.processedFPS = ((overlay.processedFrames || 0) - (overlay.lastMetricsProcessed || 0)) / elapsed;
      overlay.lastMetricsAt = now;
      overlay.lastMetricsDecoded = overlay.decodedFrames;
      overlay.lastMetricsOutput = overlay.outputFrames;
      overlay.lastMetricsProcessed = overlay.processedFrames || 0;
    }
    if (now - overlay.lastReportAt > 500) {
      overlay.lastReportAt = now;
      const selected = primaryVideo();
      if (selected) {
        safeSend(selected);
      }
    }
    scheduleStreamRender(video, overlay);
  }

  function startStreamOverlay(video) {
    if (!video) {
      return;
    }
    const overlay = ensureStreamOverlay();
    if (overlay.running && overlay.video === video) {
      sizeStreamOverlay(video, overlay);
      return;
    }

    stopStreamOverlay();
    const fresh = ensureStreamOverlay();
    fresh.video = video;
    fresh.running = true;
    fresh.decodedFrames = 0;
    fresh.outputFrames = 0;
    fresh.drawErrors = 0;
    fresh.lastDrawError = "";
    fresh.processedFrames = 0;
    fresh.processedLatencyMs = 0;
    fresh.directFrames = 0;
    fresh.directTrackStalls = 0;
    fresh.directFrameActive = false;
    fresh.videoFrameFallbackActive = false;
    fresh.lastPlaybackPaused = null;
    fresh.lastAppOutputAt = 0;
    fresh.lastOutputRecoverAt = 0;
    closeVideoFrame(fresh.pendingVideoFrame);
    fresh.pendingVideoFrame = null;
    clearAppOutputPresentation(fresh, true);
    fresh.lastDecodeAt = performance.now();
    fresh.lastMediaTime = 0;
    fresh.lastReportAt = performance.now();
    fresh.lastMetricsAt = performance.now();
    fresh.lastMetricsDecoded = 0;
    fresh.lastMetricsOutput = 0;
    fresh.lastMetricsProcessed = 0;
    fresh.inputFPS = 0;
    fresh.outputFPS = 0;
    fresh.processedFPS = 0;
    fresh.activeFrameId = 0;
    fresh.sequenceStartedAt = performance.now();
    fresh.nextPresentAt = performance.now();
    fresh.lastPresentGapMs = 0;
    fresh.maxPresentGapMs = 0;
    fresh.presentationUnderflows = 0;
    fresh.lastUnderflowAt = 0;
    fresh.layoutDirty = true;
    sizeStreamOverlay(video, fresh);
    fresh.videoOriginalOpacity = video.style.opacity || "";
    fresh.videoOriginalVisibility = video.style.visibility || "";
    fresh.videoStyleHidden = false;
    setStreamVideoCovered(fresh, false);
    sendStreamPlaybackState(video, fresh, streamBypassActive(video));
    sendStreamBridgeConfig(fresh);
    try {
      copyVideoFrame(video, fresh);
    } catch (_) {
    }
    if (!directTrackProcessorAllowed() || !startDirectVideoFrames(video, fresh)) {
      ensureVideoFrameFallback(video, fresh);
    }
    fresh.lastPresentAt = performance.now();
    scheduleStreamRender(video, fresh);
  }

  function stopStreamOverlay() {
    if (!streamOverlay) {
      return;
    }
    closeStreamBridgeEncoder();
    closeStreamBridgeOutputDecoder();
    streamOverlay.running = false;
    if (streamOverlay.raf) {
      cancelAnimationFrame(streamOverlay.raf);
      clearTimeout(streamOverlay.raf);
    }
    if (streamOverlay.vfc && streamOverlay.video?.cancelVideoFrameCallback) {
      streamOverlay.video.cancelVideoFrameCallback(streamOverlay.vfc);
    }
    streamOverlay.videoFrameFallbackActive = false;
    stopDirectVideoFrames(streamOverlay);
    if (streamOverlay.videoStyleHidden && streamOverlay.video) {
      streamOverlay.video.style.opacity = streamOverlay.videoOriginalOpacity || "";
      if (streamOverlay.videoOriginalVisibility) {
        streamOverlay.video.style.visibility = streamOverlay.videoOriginalVisibility;
      }
    }
    streamOverlay.videoStyleHidden = false;
    streamOverlay.videoOriginalOpacity = "";
    streamOverlay.videoOriginalVisibility = "";
    streamOverlay.canvas.style.display = "none";
    if (streamOverlay.hostPositionTouched && streamOverlay.host?.dataset?.stellariaMotionPositionTouched === "1") {
      streamOverlay.host.style.position = "";
      delete streamOverlay.host.dataset.stellariaMotionPositionTouched;
    }
    streamOverlay.hostPositionTouched = false;
    streamOverlay.host = null;
    try {
      streamOverlay.canvas.remove();
    } catch (_) {
    }
    if (streamOverlay.processedBitmap) {
      try {
        streamOverlay.processedBitmap.close?.();
      } catch (_) {
      }
      streamOverlay.processedBitmap = null;
    }
    if (Array.isArray(streamOverlay.appOutputQueue)) {
      for (const item of streamOverlay.appOutputQueue) {
        closeQueuedOutput(item);
      }
      streamOverlay.appOutputQueue = [];
    }
  }

  function updateStreamOverlay(online) {
    if (online?.appOverlay || (online?.running && !online.browserDirect)) {
      passiveBridgeOnline = false;
      stopStreamOverlay();
      closeStreamBridge();
      lastOnlineStatus = online || null;
      updateBadge(online);
      return;
    }
    const effectiveOnline = (online?.running && online.browserDirect)
        ? {
            ...(online || {}),
            running: true,
            browserDirect: true,
            streamBridgePort: online?.streamBridgePort || online?.streamBridge?.port || 38577
          }
        : (online || null);
    lastOnlineStatus = effectiveOnline;
    if (!effectiveOnline?.running || !effectiveOnline.browserDirect) {
      stopStreamOverlay();
      closeStreamBridge();
      return;
    }
    const selected = primaryVideo();
    if (!selected) {
      stopStreamOverlay();
      return;
    }
    ensureStreamBridge(effectiveOnline);
    startStreamOverlay(selected);
  }

  function handleNativeStatus(message) {
    if (message?.type === "stellaria_motion_processed_chunk") {
      streamBridgeConnected = true;
      streamBridgeConnecting = false;
      passiveBridgeOnline = true;
      streamBridgeFramesAcked = Number(message.framesReceived || streamBridgeFramesAcked || 0);
      streamBridgePendingProcessedMeta = message.nativePayload || streamBridgePendingProcessedMeta || {};
      const binary = base64ToUint8Array(String(message.base64 || ""));
      const frameId = Number(message.frameId || streamBridgePendingProcessedMeta?.frameId || 0);
      retireStreamBridgeInFlight(frameId);
      if (!applyProcessedVideoChunk(binary, frameId)) {
        streamBridgeLastError = streamBridgeOutputDecodeFallbackReason || "processed chunk decode failed";
      }
      return;
    }
    if (message?.type === "stellaria_motion_bridge_status") {
      streamBridgeConnected = Boolean(message.connected);
      streamBridgeConnecting = Boolean(message.connecting);
      streamBridgeLastError = message.error || "";
      const payload = message.nativePayload || {};
      const snapshot = payload.snapshot || payload;
      consumeStreamBridgeSnapshot(snapshot);
      streamBridgeFramesAcked = Number(snapshot.processedFrames || snapshot.receivedFrames || streamBridgeFramesAcked || 0);
      updateBadge(lastOnlineStatus || { running: false, browserDirect: false });
      return;
    }
    if (message?.type !== "stellaria_motion_native_status") {
      return;
    }
    const online = message.payload?.online;
    updateStreamOverlay(online);
    updateBadge(lastOnlineStatus || online);
  }

  function scan() {
    if (!active) {
      return;
    }
    document.querySelectorAll("video").forEach(observe);
  }

  function safeScan() {
    try {
      scan();
    } catch (error) {
      shutdown();
    }
  }

  globalThis.addEventListener("error", swallowRuntimeError, true);
  globalThis.addEventListener("unhandledrejection", swallowRuntimeError, true);

  mutationObserver = new MutationObserver(safeScan);
  mutationObserver.observe(document.documentElement, {
    subtree: true,
    childList: true
  });

  window.addEventListener("scroll", safeScan, { passive: true });
  window.addEventListener("resize", safeScan, { passive: true });
  window.addEventListener("scroll", markStreamOverlayLayoutDirty, { passive: true });
  window.addEventListener("resize", markStreamOverlayLayoutDirty, { passive: true });
  document.addEventListener("fullscreenchange", markStreamOverlayLayoutDirty, { passive: true });
  document.addEventListener("webkitfullscreenchange", markStreamOverlayLayoutDirty, { passive: true });
  runtime()?.onMessage?.addListener(handleNativeStatus);
  heartbeatTimer = setInterval(() => {
    const selected = primaryVideo();
    if (selected) {
      safeSend(selected);
      if (!lastOnlineStatus?.running) {
        updateBadge({ running: false, browserDirect: false });
      }
    } else {
      publishRealPageMetrics(null);
      safeScan();
    }
  }, 500);
  safeScan();
})();
