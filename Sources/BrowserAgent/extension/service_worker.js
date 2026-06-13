let nativePort = null;
let lastVideoTabId = 0;
let nativeStatus = {
  connected: false,
  error: ""
};
let bridgeSocket = null;
let bridgeTabId = 0;
let bridgeConnecting = false;
let bridgeConnected = false;
let bridgeFramesSent = 0;
let bridgeFramesReceived = 0;
let bridgeLastError = "";
let bridgePendingFrame = null;
let bridgePendingOutputIds = [];
let bridgePendingProcessedMeta = null;

function isWebTab(tab) {
  return /^https?:\/\//i.test(tab?.url || "");
}

function refreshWebTabs(reason) {
  chrome.tabs.query({}, (tabs) => {
    const error = chrome.runtime.lastError;
    if (error) {
      return;
    }
    for (const tab of tabs) {
      if (!isWebTab(tab) || typeof tab.id !== "number") {
        continue;
      }
      chrome.tabs.reload(tab.id, { bypassCache: false }, () => {
        try {
          void chrome.runtime.lastError;
        } catch (_) {
        }
      });
    }
  });
  nativeStatus = {
    ...nativeStatus,
    lastLifecycleRefresh: reason,
    refreshedAtMs: Date.now()
  };
}

chrome.runtime.onInstalled.addListener((details) => {
  if (details.reason === "install" || details.reason === "update") {
    refreshWebTabs(details.reason);
  }
});

chrome.runtime.onStartup.addListener(() => {
  refreshWebTabs("startup");
});

function rememberNativeError(error) {
  let message = "native host unavailable";
  try {
    message = String(error?.message || error || chrome.runtime?.lastError?.message || message);
  } catch (_) {
    message = "native host unavailable";
  }
  nativePort = null;
  nativeStatus = {
    connected: false,
    error: message
  };
}

function connectNative() {
  if (nativePort) {
    return nativePort;
  }

  try {
    nativePort = chrome.runtime.connectNative("studio.stellaria.motion");
    nativeStatus = {
      connected: true,
      error: ""
    };
  } catch (error) {
    rememberNativeError(error);
    return null;
  }

  nativePort.onDisconnect.addListener(() => {
    try {
      rememberNativeError(chrome.runtime.lastError);
    } catch (error) {
      rememberNativeError(error);
    }
  });
  nativePort.onMessage.addListener((message) => {
    const tabId = Number(message?.tabId || lastVideoTabId || 0);
    if (!tabId) {
      return;
    }
    chrome.tabs.sendMessage(tabId, {
      type: "stellaria_motion_native_status",
      payload: message
    }, () => {
      try {
        void chrome.runtime.lastError;
      } catch (_) {
      }
    });
  });
  return nativePort;
}

function bytesToBase64(bytes) {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

function base64ToBytes(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function postToVideoTab(message) {
  const tabId = Number(bridgeTabId || lastVideoTabId || 0);
  if (!tabId) {
    return;
  }
  chrome.tabs.sendMessage(tabId, message, () => {
    try {
      void chrome.runtime.lastError;
    } catch (_) {
    }
  });
}

function bridgeStatus(extra = {}) {
  return {
    type: "stellaria_motion_bridge_status",
    connected: bridgeConnected,
    connecting: bridgeConnecting,
    framesSent: bridgeFramesSent,
    framesReceived: bridgeFramesReceived,
    error: bridgeLastError,
    ...extra
  };
}

function connectBridge(tabId, port = 38577) {
  bridgeTabId = tabId || bridgeTabId || lastVideoTabId || 0;
  if (bridgeSocket &&
      (bridgeSocket.readyState === WebSocket.OPEN || bridgeSocket.readyState === WebSocket.CONNECTING)) {
    return;
  }

  bridgeConnecting = true;
  bridgeConnected = false;
  bridgeLastError = "";
  bridgeFramesSent = 0;
  bridgeFramesReceived = 0;
  bridgePendingOutputIds = [];
  try {
    bridgeSocket = new WebSocket(`ws://127.0.0.1:${port}/stellaria-motion-stream`);
    bridgeSocket.binaryType = "arraybuffer";
  } catch (error) {
    bridgeConnecting = false;
    bridgeConnected = false;
    bridgeLastError = String(error?.message || error || "bridge unavailable");
    postToVideoTab(bridgeStatus());
    return;
  }

  bridgeSocket.addEventListener("open", () => {
    bridgeConnecting = false;
    bridgeConnected = true;
    bridgeLastError = "";
    try {
      bridgeSocket.send(JSON.stringify({
        type: "hello",
        via: "extension_service_worker",
        sentAtMs: Date.now()
      }));
    } catch (_) {
    }
    flushPendingBridgeFrame();
    postToVideoTab(bridgeStatus());
  });

  function deliverBridgeBinary(data) {
    const bytes = new Uint8Array(data);
    const frameId = bridgePendingOutputIds.length ? bridgePendingOutputIds.shift() : 0;
    const meta = bridgePendingProcessedMeta || {};
    bridgeFramesReceived += 1;
    if (meta.outputPayloadKind === "webcodecs_video_chunk") {
      postToVideoTab({
        type: "stellaria_motion_processed_chunk",
        base64: bytesToBase64(bytes),
        nativePayload: meta,
        framesReceived: bridgeFramesReceived,
        frameId: Number(meta.frameId || frameId || 0)
      });
      return;
    }
    postToVideoTab({
      type: "stellaria_motion_processed_frame",
      mime: "image/jpeg",
      base64: bytesToBase64(bytes),
      nativePayload: meta,
      framesReceived: bridgeFramesReceived,
      frameId: Number(meta.frameId || frameId || 0)
    });
  }

  bridgeSocket.addEventListener("message", (event) => {
    if (typeof event.data === "string") {
      let parsed = null;
      try {
        parsed = JSON.parse(event.data);
      } catch (_) {
      }
      if (parsed?.type === "processed_frame") {
        bridgePendingProcessedMeta = parsed;
      }
      const snapshot = parsed?.snapshot || parsed || {};
      bridgeFramesReceived = Number(snapshot.processedFrames || snapshot.receivedFrames || bridgeFramesReceived || 0);
      postToVideoTab(bridgeStatus({
        nativePayload: parsed
      }));
      return;
    }

    if (event.data instanceof Blob) {
      event.data.arrayBuffer()
        .then(deliverBridgeBinary)
        .catch((error) => {
          bridgeLastError = String(error?.message || error || "bridge binary decode failed");
          postToVideoTab(bridgeStatus());
        });
      return;
    }
    deliverBridgeBinary(event.data);
  });

  bridgeSocket.addEventListener("close", () => {
    bridgeSocket = null;
    bridgeConnecting = false;
    bridgeConnected = false;
    bridgeLastError = "bridge disconnected";
    postToVideoTab(bridgeStatus());
  });

  bridgeSocket.addEventListener("error", () => {
    bridgeConnecting = false;
    bridgeConnected = false;
    bridgeLastError = "bridge offline";
    postToVideoTab(bridgeStatus());
  });
}

function disconnectBridge(reason = "bridge stopped") {
  bridgePendingFrame = null;
  bridgePendingOutputIds = [];
  bridgeConnecting = false;
  bridgeConnected = false;
  bridgeLastError = reason;
  if (bridgeSocket) {
    try {
      bridgeSocket.close();
    } catch (_) {
    }
  }
  bridgeSocket = null;
  postToVideoTab(bridgeStatus());
}

function sendBridgeFramePayload(payload) {
  if (bridgeSocket?.readyState !== WebSocket.OPEN) {
    return false;
  }
  bridgeSocket.send(JSON.stringify(payload.meta || { type: "frame_meta", sentAtMs: Date.now() }));
  const dataUrl = String(payload.dataUrl || "");
  const comma = dataUrl.indexOf(",");
  const base64 = comma >= 0 ? dataUrl.slice(comma + 1) : dataUrl;
  bridgeSocket.send(base64ToBytes(base64));
  bridgePendingOutputIds.push(Number(payload.meta?.frameId || 0));
  if (bridgePendingOutputIds.length > 12) {
    bridgePendingOutputIds = bridgePendingOutputIds.slice(-12);
  }
  bridgeFramesSent += 1;
  return true;
}

function flushPendingBridgeFrame() {
  if (!bridgePendingFrame || bridgeSocket?.readyState !== WebSocket.OPEN) {
    return false;
  }
  const payload = bridgePendingFrame;
  bridgePendingFrame = null;
  try {
    return sendBridgeFramePayload(payload);
  } catch (error) {
    bridgeLastError = String(error?.message || error || "bridge pending frame failed");
    postToVideoTab(bridgeStatus());
    return false;
  }
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === "bridge_disconnect") {
    disconnectBridge(String(message.reason || "bridge stopped"));
    sendResponse?.(bridgeStatus({ disconnected: true }));
    return true;
  }

  if (message?.type === "bridge_connect") {
    const tabId = sender.tab?.id || lastVideoTabId || 0;
    connectBridge(tabId, Number(message.port || 38577));
    sendResponse?.(bridgeStatus());
    return true;
  }

  if (message?.type === "bridge_frame") {
    const tabId = sender.tab?.id || lastVideoTabId || 0;
    connectBridge(tabId, Number(message.port || 38577));
    if (bridgeSocket?.readyState !== WebSocket.OPEN) {
      bridgePendingFrame = {
        meta: message.meta || { type: "frame_meta", sentAtMs: Date.now() },
        dataUrl: String(message.dataUrl || "")
      };
      sendResponse?.(bridgeStatus({ accepted: false, queued: true }));
      return true;
    }
    try {
      sendBridgeFramePayload(message);
      sendResponse?.(bridgeStatus({ accepted: true }));
    } catch (error) {
      bridgeLastError = String(error?.message || error || "bridge send failed");
      sendResponse?.(bridgeStatus({ accepted: false }));
    }
    return true;
  }

  if (message?.type !== "video_state") {
    return false;
  }

  message.tabId = sender.tab?.id || 0;
  lastVideoTabId = message.tabId || lastVideoTabId;
  const port = connectNative();
  if (!port) {
    return;
  }

  try {
    port.postMessage({
      ...message,
      nativeStatus
    });
  } catch (error) {
    rememberNativeError(error);
  }
});
