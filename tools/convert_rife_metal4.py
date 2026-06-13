#!/usr/bin/env python3
"""Pack RIFE safetensors into a compact Metal INT4 experiment bundle.

The app runtime can quantize the first online Metal INT4 layer directly from
safetensors, but this tool makes the q4 representation inspectable and reusable
for future full-graph Metal kernels.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
from pathlib import Path


def read_safetensors(path: Path) -> tuple[dict, memoryview]:
    data = path.read_bytes()
    header_len = struct.unpack("<Q", data[:8])[0]
    header = json.loads(data[8 : 8 + header_len])
    return header, memoryview(data)[8 + header_len :]


def tensor_f32(header: dict, payload: memoryview, name: str) -> tuple[list[int], list[float]]:
    entry = header[name]
    if entry["dtype"] != "F32":
        raise ValueError(f"{name}: expected F32, got {entry['dtype']}")
    start, end = entry["data_offsets"]
    raw = payload[start:end]
    count = len(raw) // 4
    return list(entry["shape"]), list(struct.unpack("<" + "f" * count, raw))


def quantize_symmetric_int4(values: list[float], output_channels: int) -> tuple[bytes, list[float]]:
    per_output = len(values) // output_channels
    packed_per_output = (per_output + 1) // 2
    packed = bytearray(output_channels * packed_per_output)
    scales: list[float] = []
    for oc in range(output_channels):
        row = values[oc * per_output : (oc + 1) * per_output]
        max_abs = max((abs(v) for v in row), default=0.0)
        scale = max_abs / 7.0 if max_abs > 1.0e-8 else 1.0
        scales.append(scale)
        for i, value in enumerate(row):
            q = max(-8, min(7, int(math.floor(value / scale + (0.5 if value >= 0 else -0.5)))))
            nibble = q & 0x0F
            offset = oc * packed_per_output + i // 2
            if i & 1:
                packed[offset] |= nibble << 4
            else:
                packed[offset] = nibble
    return bytes(packed), scales


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--safetensors", type=Path, default=Path("Models/RIFE-safetensors/flownet.safetensors"))
    parser.add_argument("--output", type=Path, default=Path("Models/RIFE-Metal4/rife_metal4_q4.bin"))
    args = parser.parse_args()

    header, payload = read_safetensors(args.safetensors)
    first = [f"block{i}.conv0.0.0.weight" for i in range(3)]
    all_weight_names = sorted(
        name
        for name, entry in header.items()
        if name != "__metadata__"
        and entry.get("dtype") == "F32"
        and len(entry.get("shape", [])) == 4
        and name.endswith(".weight")
    )
    ordered_names = first + [name for name in all_weight_names if name not in first]
    q4_chunks: list[bytes] = []
    scales_all: list[float] = []
    bias_all: list[float] = []
    descriptors: list[dict] = []
    weight_offset = 0
    scale_offset = 0
    bias_offset = 0
    for name in ordered_names:
        weight_shape, weights = tensor_f32(header, payload, name)
        if len(weight_shape) != 4:
            raise ValueError(f"{name}: unsupported weight shape")
        bias_name = name[: -len(".weight")] + ".bias"
        try:
            _, bias = tensor_f32(header, payload, bias_name)
        except KeyError:
            bias = [0.0] * weight_shape[0]
        q4, scales = quantize_symmetric_int4(weights, weight_shape[0])
        q4_chunks.append(q4)
        bias = (bias + [0.0] * weight_shape[0])[: weight_shape[0]]
        descriptors.append(
            {
                "name": name,
                "weight_offset_bytes": weight_offset,
                "scale_offset": scale_offset,
                "bias_offset": bias_offset,
                "shape": weight_shape,
                "op": "deconv" if ".conv1." in name or ".conv2." in name else "conv",
            }
        )
        weight_offset += len(q4)
        scale_offset += len(scales)
        bias_offset += len(bias)
        scales_all.extend(scales)
        bias_all.extend(bias)
    q4_all = b"".join(q4_chunks)
    manifest = {
        "format": "stellaria.rife.metal4.q4.v1",
        "source": str(args.safetensors),
        "graph_tensors": sum(1 for name in header if name != "__metadata__"),
        "q4_layers": len(descriptors),
        "layers": descriptors,
        "quantization": "symmetric_int4_per_output_channel",
        "packed_weight_bytes": len(q4_all),
    }
    manifest_bytes = json.dumps(manifest, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("wb") as f:
        f.write(b"SMR4")
        f.write(struct.pack("<III", 1, len(manifest_bytes), len(q4_all)))
        f.write(manifest_bytes)
        f.write(q4_all)
        f.write(struct.pack("<" + "f" * len(scales_all), *scales_all))
        f.write(struct.pack("<" + "f" * len(bias_all), *bias_all))
    print(f"wrote {args.output} ({args.output.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
