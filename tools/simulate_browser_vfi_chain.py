#!/usr/bin/env python3
import argparse
import json
import math
import random
from statistics import mean


def pct(values, q):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, math.ceil(len(ordered) * q) - 1))
    return ordered[index]


def sample_ms(rng, base, jitter, floor=0.0):
    return max(floor, rng.gauss(base, jitter))


def parse_args():
    parser = argparse.ArgumentParser(description="Simulate the browser -> App VFI -> browser presentation chain.")
    parser.add_argument("--source-fps", type=float, default=30.0)
    parser.add_argument("--target-fps", type=float, default=60.0)
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--source-jitter-ms", type=float, default=0.0)
    parser.add_argument("--source-stall-prob", type=float, default=0.0)
    parser.add_argument("--source-stall-ms", type=float, default=0.0)
    parser.add_argument("--capture-ms", type=float, default=1.5)
    parser.add_argument("--capture-jitter-ms", type=float, default=2.0)
    parser.add_argument("--encode-ms", type=float, default=9.6)
    parser.add_argument("--encode-jitter-ms", type=float, default=4.0)
    parser.add_argument("--app-ms", type=float, default=8.3)
    parser.add_argument("--app-jitter-ms", type=float, default=2.0)
    parser.add_argument("--return-ms", type=float, default=4.0)
    parser.add_argument("--return-jitter-ms", type=float, default=6.0)
    parser.add_argument("--buffer-ms", type=float, default=360.0)
    parser.add_argument("--max-buffer-ms", type=float, default=900.0)
    parser.add_argument("--warmup-ms", type=float, default=700.0)
    parser.add_argument("--returned-frames-per-input", type=float, default=0.0, help="0 means target_fps/source_fps.")
    parser.add_argument("--max-returned-frames-per-input", type=int, default=8)
    parser.add_argument("--strict", action="store_true", help="Exit non-zero when online playback stability criteria fail.")
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    rng = random.Random(args.seed)
    source_interval = 1000.0 / max(1.0, args.source_fps)
    target_interval = 1000.0 / max(1.0, args.target_fps)
    frames = max(1, int(args.seconds * args.source_fps))
    app_done = []
    returned = []
    input_to_app = []
    end_to_end = []
    output_accumulator = 0.0
    source_time = 0.0
    last_source_time = 0.0
    for i in range(frames):
        if i == 0:
            source_time = 0.0
        else:
            source_time += source_interval + sample_ms(rng, 0.0, args.source_jitter_ms)
            if args.source_stall_prob > 0.0 and rng.random() < args.source_stall_prob:
                source_time += sample_ms(rng, args.source_stall_ms, args.source_stall_ms * 0.35)
        t = max(0.0, source_time)
        capture = sample_ms(rng, args.capture_ms, args.capture_jitter_ms)
        encode = sample_ms(rng, args.encode_ms, args.encode_jitter_ms)
        app = sample_ms(rng, args.app_ms, args.app_jitter_ms)
        ret = sample_ms(rng, args.return_ms, args.return_jitter_ms)
        done = t + capture + encode + app
        arrive = done + ret
        app_done.append(done)
        if args.returned_frames_per_input > 0.0:
            output_accumulator += args.returned_frames_per_input
        else:
            source_elapsed = source_interval if i == 0 else max(1.0, t - last_source_time)
            output_accumulator += source_elapsed / target_interval
        returned_count = max(1, int(math.floor(output_accumulator + 0.0001)))
        returned_count = min(max(1, args.max_returned_frames_per_input), returned_count)
        output_accumulator -= returned_count
        last_source_time = t
        for j in range(returned_count):
            returned.append(arrive + j * target_interval)
        input_to_app.append(done - t)
        end_to_end.append(arrive - t)

    returned.sort()
    queue = []
    returned_index = 0
    presented_times = []
    presentation_gaps = []
    underflows = 0
    max_queue = max(2, math.ceil(args.target_fps * args.max_buffer_ms / 1000.0))
    next_present = args.buffer_ms
    stop_time = args.seconds * 1000.0 + args.buffer_ms
    while next_present <= stop_time:
        while returned_index < len(returned) and returned[returned_index] <= next_present:
            queue.append(returned[returned_index])
            returned_index += 1
        while len(queue) > max_queue:
            queue.pop(0)
        if queue:
            queue.pop(0)
            if presented_times and next_present >= args.warmup_ms:
                presentation_gaps.append(next_present - presented_times[-1])
            presented_times.append(next_present)
        else:
            if next_present >= args.warmup_ms:
                underflows += 1
        next_present += target_interval

    input_budget = source_interval
    input_pass = pct(input_to_app, 0.99) <= input_budget
    presentation_pass = bool(presentation_gaps) and pct(presentation_gaps, 0.99) <= target_interval * 1.15 and underflows == 0
    stable = input_pass and presentation_pass
    result = {
        "source_fps": args.source_fps,
        "target_fps": args.target_fps,
        "online_stable": stable,
        "input_budget_ms": round(input_budget, 3),
        "target_interval_ms": round(target_interval, 3),
        "frames_in": frames,
        "frames_presented": len(presented_times),
        "underflows": underflows,
        "input_to_app_ms": {
            "avg": round(mean(input_to_app), 3),
            "p95": round(pct(input_to_app, 0.95), 3),
            "p99": round(pct(input_to_app, 0.99), 3),
            "pass_p99": input_pass,
        },
        "end_to_end_ms": {
            "avg": round(mean(end_to_end), 3),
            "p95": round(pct(end_to_end, 0.95), 3),
            "p99": round(pct(end_to_end, 0.99), 3),
        },
        "presentation_gap_ms": {
            "avg": round(mean(presentation_gaps), 3) if presentation_gaps else 0.0,
            "p95": round(pct(presentation_gaps, 0.95), 3),
            "p99": round(pct(presentation_gaps, 0.99), 3),
            "pass_p99": presentation_pass,
        },
    }
    if args.json:
        print(json.dumps(result, indent=2))
        raise SystemExit(0 if stable or not args.strict else 1)

    print(f"ONLINE_STABLE {'pass' if stable else 'fail'}")
    print(f"source={args.source_fps:g}fps target={args.target_fps:g}fps input_budget={input_budget:.2f}ms target_interval={target_interval:.2f}ms")
    print(f"input->app avg={result['input_to_app_ms']['avg']:.2f} p95={result['input_to_app_ms']['p95']:.2f} p99={result['input_to_app_ms']['p99']:.2f} pass_p99={result['input_to_app_ms']['pass_p99']}")
    print(f"end-to-end avg={result['end_to_end_ms']['avg']:.2f} p95={result['end_to_end_ms']['p95']:.2f} p99={result['end_to_end_ms']['p99']:.2f}")
    print(f"present gap avg={result['presentation_gap_ms']['avg']:.2f} p95={result['presentation_gap_ms']['p95']:.2f} p99={result['presentation_gap_ms']['p99']:.2f} pass_p99={result['presentation_gap_ms']['pass_p99']} underflows={underflows}")
    raise SystemExit(0 if stable or not args.strict else 1)


if __name__ == "__main__":
    main()
