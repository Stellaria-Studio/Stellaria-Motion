#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
from pathlib import Path


GPU_RE = re.compile(r"gpu_ms median=([0-9.]+) p95=([0-9.]+) p99=([0-9.]+) avg=([0-9.]+)")
MODEL_RE = re.compile(r"model=([0-9]+)x([0-9]+)")


def parse_args():
    parser = argparse.ArgumentParser(description="Sweep realtime RIFE heights and report p95/p99 against browser playback budgets.")
    parser.add_argument("--cli", default="build-app/RealtimeVFITestCLI")
    parser.add_argument("--backend", default="sp4", choices=["sp4", "int4"])
    parser.add_argument("--target-fps", type=float, default=120.0)
    parser.add_argument("--source-fps", type=float, default=60.0, help="Browser source fps assumption used for per-pair realtime budget.")
    parser.add_argument("--frames", type=int, default=72)
    parser.add_argument("--heights", default="216,288,360,432,540")
    parser.add_argument("--video", default="")
    parser.add_argument("--multi-t", action="store_true")
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def run_case(args, height):
    cmd = [
        str(Path(args.cli)),
        "--backend", args.backend,
        "--frames", str(args.frames),
        "--model-height", str(height),
        "--target-fps", str(args.target_fps),
    ]
    if args.video:
        cmd += ["--video", args.video]
    if args.multi_t:
        cmd.append("--multi-t")
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = proc.stdout
    gpu = GPU_RE.search(output)
    model = MODEL_RE.search(output)
    if not gpu:
        return {
            "height": height,
            "ok": False,
            "error": "gpu_ms line missing",
            "returncode": proc.returncode,
            "output": output,
        }
    median, p95, p99, avg = [float(gpu.group(i)) for i in range(1, 5)]
    return {
        "height": height,
        "model": f"{model.group(1)}x{model.group(2)}" if model else f"?x{height}",
        "median_ms": median,
        "p95_ms": p95,
        "p99_ms": p99,
        "avg_ms": avg,
        "ok": proc.returncode == 0,
        "returncode": proc.returncode,
    }


def main():
    args = parse_args()
    cli = Path(args.cli)
    if not cli.exists():
        raise SystemExit(f"missing {cli}; build RealtimeVFITestCLI first")
    heights = [int(x.strip()) for x in args.heights.split(",") if x.strip()]
    pair_budget_ms = 1000.0 / max(1.0, args.source_fps)
    frame_budget_ms = 1000.0 / max(1.0, args.target_fps)
    results = []
    for height in heights:
        row = run_case(args, height)
        row["pair_budget_ms"] = pair_budget_ms
        row["frame_budget_ms"] = frame_budget_ms
        row["p95_pair_pass"] = row.get("p95_ms", 1e9) <= pair_budget_ms
        row["p99_pair_pass"] = row.get("p99_ms", 1e9) <= pair_budget_ms
        results.append(row)

    if args.json:
        print(json.dumps({
            "backend": args.backend,
            "target_fps": args.target_fps,
            "source_fps_assumption": args.source_fps,
            "pair_budget_ms": pair_budget_ms,
            "frame_budget_ms": frame_budget_ms,
            "results": results,
        }, indent=2))
        return

    print(f"backend={args.backend} target={args.target_fps:g}fps source_assumption={args.source_fps:g}fps pair_budget={pair_budget_ms:.2f}ms frame_interval={frame_budget_ms:.2f}ms")
    print("height model       median    p95      p99      p95<=budget p99<=budget")
    for row in results:
        if "error" in row:
            print(f"{row['height']:>6} {'failed':<10} {row['error']}")
            continue
        print(f"{row['height']:>6} {row['model']:<10} {row['median_ms']:>7.2f}  {row['p95_ms']:>7.2f}  {row['p99_ms']:>7.2f}  {str(row['p95_pair_pass']):<11} {str(row['p99_pair_pass'])}")


if __name__ == "__main__":
    main()
