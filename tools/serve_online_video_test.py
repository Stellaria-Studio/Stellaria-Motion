#!/usr/bin/env python3
import argparse
import http.server
import socketserver
import subprocess
from pathlib import Path


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


def ensure_sync_fixture(root: Path):
    output = root / "browser_vfi_sync_fixture.mp4"
    if output.exists() and output.stat().st_size > 100_000:
        return
    width = 1920
    height = 1080
    fps = 24
    duration = 30
    bar_width = 56
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "-s",
        f"{width}x{height}",
        "-r",
        str(fps),
        "-i",
        "pipe:0",
        "-f",
        "lavfi",
        "-i",
        f"sine=frequency=880:sample_rate=48000:duration={duration}",
        "-t",
        str(duration),
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-preset",
        "veryfast",
        "-crf",
        "18",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-movflags",
        "+faststart",
        str(output),
    ]
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        assert proc.stdin is not None
        black_pixel = b"\x00\x00\x00"
        green_pixel = b"\x00\xff\x00"
        frame_count = fps * duration
        for frame_index in range(frame_count):
            phase = ((frame_index / fps) % 2.0) / 2.0
            x0 = int(round(phase * (width - bar_width)))
            row = bytearray(black_pixel * width)
            for x in range(x0, min(width, x0 + bar_width)):
                offset = x * 3
                row[offset:offset + 3] = green_pixel
            row_bytes = bytes(row)
            for _ in range(height):
                proc.stdin.write(row_bytes)
        proc.stdin.close()
        if proc.wait() != 0:
            raise subprocess.CalledProcessError(proc.returncode, cmd)
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"warning: could not generate {output.name}: {exc}", flush=True)


def main():
    parser = argparse.ArgumentParser(description="Serve the Stellaria browser VFI lab page.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    root = Path(__file__).resolve().parent
    ensure_sync_fixture(root)
    handler = lambda *a, **kw: QuietHandler(*a, directory=str(root), **kw)
    with ReusableTCPServer((args.host, args.port), handler) as httpd:
        print(f"http://{args.host}:{args.port}/online_video_test.html", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
