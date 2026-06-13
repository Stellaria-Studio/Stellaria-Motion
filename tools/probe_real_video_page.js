#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

function argValue(name, fallback = "") {
  const index = process.argv.indexOf(name);
  if (index >= 0 && index + 1 < process.argv.length) {
    return process.argv[index + 1];
  }
  return fallback;
}

function hasArg(name) {
  return process.argv.includes(name);
}

function percentile(values, p) {
  if (!values.length) {
    return 0;
  }
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[index];
}

function summarizeGaps(gaps) {
  const usable = gaps.filter((value) => Number.isFinite(value) && value > 0 && value < 1000);
  const avg = usable.length ? usable.reduce((sum, value) => sum + value, 0) / usable.length : 0;
  return {
    samples: usable.length,
    avgMs: avg,
    p50Ms: percentile(usable, 50),
    p95Ms: percentile(usable, 95),
    p99Ms: percentile(usable, 99),
    maxMs: usable.length ? Math.max(...usable) : 0,
    fpsFromAvg: avg > 0 ? 1000 / avg : 0
  };
}

async function collect(page, seconds) {
  await page.evaluate(() => {
    const video = document.querySelector("video");
    window.__stellariaRealProbe = {
      startedAt: performance.now(),
      rafTimes: [],
      videoTimes: [],
      mediaTimes: [],
      presentedFrames: [],
      playErrors: []
    };
    const probe = window.__stellariaRealProbe;
    let lastRaf = performance.now();
    const rafLoop = (now) => {
      probe.rafTimes.push(now - lastRaf);
      lastRaf = now;
      if (performance.now() - probe.startedAt < 120000) {
        requestAnimationFrame(rafLoop);
      }
    };
    requestAnimationFrame(rafLoop);
    if (!video) {
      return;
    }
    video.muted = true;
    video.playsInline = true;
    video.play?.().catch((error) => {
      probe.playErrors.push(String(error?.message || error || ""));
    });
    if (typeof video.requestVideoFrameCallback === "function") {
      let lastVideoNow = performance.now();
      const onFrame = (now, metadata) => {
        probe.videoTimes.push(now - lastVideoNow);
        lastVideoNow = now;
        probe.mediaTimes.push(Number(metadata?.mediaTime || video.currentTime || 0));
        probe.presentedFrames.push(Number(metadata?.presentedFrames || 0));
        if (performance.now() - probe.startedAt < 120000) {
          video.requestVideoFrameCallback(onFrame);
        }
      };
      video.requestVideoFrameCallback(onFrame);
    }
  });
  await page.waitForTimeout(seconds * 1000);
  return page.evaluate(() => {
    const video = document.querySelector("video");
    const probe = window.__stellariaRealProbe || {};
    const metricsNode = document.getElementById("stellaria-motion-real-page-metrics");
    let stellaria = null;
    if (metricsNode?.textContent) {
      try {
        stellaria = JSON.parse(metricsNode.textContent);
      } catch (_) {
        stellaria = { parseError: true, rawLength: metricsNode.textContent.length };
      }
    }
    let quality = null;
    try {
      quality = video?.getVideoPlaybackQuality?.() || null;
    } catch (_) {
      quality = null;
    }
    return {
      href: location.href,
      title: document.title,
      elapsedMs: performance.now() - Number(probe.startedAt || performance.now()),
      video: video ? {
        paused: video.paused,
        ended: video.ended,
        readyState: video.readyState,
        currentTime: video.currentTime,
        duration: video.duration,
        playbackRate: video.playbackRate,
        videoWidth: video.videoWidth,
        videoHeight: video.videoHeight,
        currentSrcKind: String(video.currentSrc || video.src || "").startsWith("blob:") ? "blob" : "url",
        quality
      } : null,
      raw: {
        rafGaps: probe.rafTimes || [],
        videoGaps: probe.videoTimes || [],
        mediaTimes: probe.mediaTimes || [],
        presentedFrames: probe.presentedFrames || [],
        playErrors: probe.playErrors || []
      },
      stellaria
    };
  });
}

async function main() {
  const url = argValue("--url", "");
  if (!url) {
    console.error("Usage: probe_real_video_page.js --url <video page url> [--seconds 20] [--headed] [--extension-dir Sources/BrowserAgent/extension] [--user-data-dir /tmp/stellaria-motion-probe]");
    process.exit(2);
  }
  const seconds = Math.max(3, Number(argValue("--seconds", "15")) || 15);
  const extensionDir = argValue("--extension-dir", "");
  const browserExecutable = argValue("--browser-executable", "");
  const userDataDir = argValue("--user-data-dir", path.join(process.cwd(), ".probe-real-video-profile"));
  const headed = hasArg("--headed") || Boolean(extensionDir);
  const args = [
    "--autoplay-policy=no-user-gesture-required",
    "--disable-background-timer-throttling",
    "--disable-renderer-backgrounding",
    "--disable-features=DisableLoadExtensionCommandLineSwitch",
    "--no-first-run"
  ];
  if (extensionDir) {
    if (!fs.existsSync(extensionDir)) {
      throw new Error(`Extension dir not found: ${extensionDir}`);
    }
    args.push(`--disable-extensions-except=${extensionDir}`);
    args.push(`--load-extension=${extensionDir}`);
  }

  let browser = null;
  let context = null;
  try {
    if (extensionDir) {
      context = await chromium.launchPersistentContext(userDataDir, {
        headless: false,
        executablePath: browserExecutable || undefined,
        args
      });
    } else {
      browser = await chromium.launch({
        headless: !headed,
        executablePath: browserExecutable || undefined,
        args
      });
      context = await browser.newContext({
        viewport: { width: 1440, height: 1000 },
        deviceScaleFactor: 1
      });
    }
    const page = context.pages()[0] || await context.newPage();
    page.setDefaultTimeout(30000);
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 45000 });
    await page.waitForSelector("video", { state: "attached", timeout: 30000 });
    const data = await collect(page, seconds);
    const mediaTimes = data.raw.mediaTimes || [];
    const mediaDelta = mediaTimes.slice(1).map((value, index) => (value - mediaTimes[index]) * 1000);
    const videoSource = {
      raf: summarizeGaps(data.raw.rafGaps || []),
      videoCallback: summarizeGaps(data.raw.videoGaps || []),
      mediaDelta: summarizeGaps(mediaDelta),
      currentTimeProgressSec: data.video?.currentTime || 0,
      droppedVideoFrames: data.video?.quality?.droppedVideoFrames ?? null,
      totalVideoFrames: data.video?.quality?.totalVideoFrames ?? null,
      playErrors: data.raw.playErrors || []
    };
    const result = {
      url: data.href,
      title: data.title,
      seconds,
      video: data.video,
      videoSource,
      stellaria: data.stellaria,
      pass: {
        sourceP95Under50ms: videoSource.videoCallback.p95Ms > 0 && videoSource.videoCallback.p95Ms <= 50,
        sourceProgressed: Boolean(data.video && data.video.currentTime > 0 && !data.video.paused),
        extensionMetricsDetected: Boolean(data.stellaria)
      }
    };
    console.log(JSON.stringify(result, null, 2));
  } finally {
    await context?.close().catch(() => {});
    await browser?.close().catch(() => {});
  }
}

main().catch((error) => {
  console.error(error?.stack || String(error));
  process.exit(1);
});
