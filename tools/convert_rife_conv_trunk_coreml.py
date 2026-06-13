#!/usr/bin/env python3
"""Convert RIFE IFBlock conv trunks to NHWC Core ML subgraphs.

The generated models keep the native runtime contract NHWC:
  x_nhwc:          [1, H, W, 7]  (warped img0 RGB, warped img1 RGB, mask)
  flow_nhwc:       [1, H, W, 4]
  flow_mask_nhwc:  [1, H, W, 5]  (delta flow RGBA + delta mask)

The continuous-trunk mode exports a single Core ML subgraph:
  pair_nhwc:       [1, H, W, 6]  (img0 RGB, img1 RGB)
  flow_mask_nhwc:  [1, H, W, 5]  (accumulated flow RGBA + mask)

Core ML may internally choose its preferred convolution layout, but the app does
not need CPU-side NCHW packing or unpacking.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
from safetensors.torch import load_file


def conv(in_planes: int, out_planes: int, stride: int = 1) -> nn.Sequential:
    return nn.Sequential(
        nn.Conv2d(in_planes, out_planes, kernel_size=3, stride=stride, padding=1, bias=True),
        nn.PReLU(out_planes),
    )


class IFBlockConvTrunkNHWC(nn.Module):
    def __init__(self, in_planes: int = 11, channels: int = 90, scale: int = 1) -> None:
        super().__init__()
        self.scale = int(scale)
        self.conv0 = nn.Sequential(
            conv(in_planes, channels // 2, stride=2),
            conv(channels // 2, channels, stride=2),
        )
        self.convblock0 = nn.Sequential(conv(channels, channels), conv(channels, channels))
        self.convblock1 = nn.Sequential(conv(channels, channels), conv(channels, channels))
        self.convblock2 = nn.Sequential(conv(channels, channels), conv(channels, channels))
        self.convblock3 = nn.Sequential(conv(channels, channels), conv(channels, channels))
        self.conv1 = nn.Sequential(
            nn.ConvTranspose2d(channels, channels // 2, 4, 2, 1),
            nn.PReLU(channels // 2),
            nn.ConvTranspose2d(channels // 2, 4, 4, 2, 1),
        )
        self.conv2 = nn.Sequential(
            nn.ConvTranspose2d(channels, channels // 2, 4, 2, 1),
            nn.PReLU(channels // 2),
            nn.ConvTranspose2d(channels // 2, 1, 4, 2, 1),
        )

    def forward(self, x_nhwc: torch.Tensor, flow_nhwc: torch.Tensor) -> torch.Tensor:
        x = x_nhwc.permute(0, 3, 1, 2).contiguous()
        flow = flow_nhwc.permute(0, 3, 1, 2).contiguous()
        height = x.shape[2]
        width = x.shape[3]
        if self.scale != 1:
            x = F.interpolate(x, scale_factor=1.0 / self.scale, mode="bilinear", align_corners=False)
            flow = F.interpolate(flow, scale_factor=1.0 / self.scale, mode="bilinear", align_corners=False) / self.scale

        feat = self.conv0(torch.cat((x, flow), dim=1))
        feat = self.convblock0(feat) + feat
        feat = self.convblock1(feat) + feat
        feat = self.convblock2(feat) + feat
        feat = self.convblock3(feat) + feat

        flow_delta = self.conv1(feat)
        mask_delta = self.conv2(feat)
        if self.scale != 1:
            flow_delta = F.interpolate(flow_delta, size=(height, width), mode="bilinear", align_corners=False) * self.scale
            mask_delta = F.interpolate(mask_delta, size=(height, width), mode="bilinear", align_corners=False)
        return torch.cat((flow_delta, mask_delta), dim=1).permute(0, 2, 3, 1).contiguous()


def warp_nchw(img: torch.Tensor, flow: torch.Tensor) -> torch.Tensor:
    n, _, h, w = img.shape
    horizontal = torch.linspace(-1.0, 1.0, w, device=img.device, dtype=img.dtype).view(1, 1, 1, w).expand(n, -1, h, -1)
    vertical = torch.linspace(-1.0, 1.0, h, device=img.device, dtype=img.dtype).view(1, 1, h, 1).expand(n, -1, -1, w)
    flow_norm = torch.cat(
        (
            flow[:, 0:1] / max((w - 1.0) / 2.0, 1.0),
            flow[:, 1:2] / max((h - 1.0) / 2.0, 1.0),
        ),
        dim=1,
    )
    grid = (torch.cat((horizontal, vertical), dim=1) + flow_norm).permute(0, 2, 3, 1)
    return F.grid_sample(img, grid, mode="bilinear", padding_mode="border", align_corners=True)


class RIFEContinuousFlowMaskNHWC(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.block0 = IFBlockConvTrunkNHWC(scale=4)
        self.block1 = IFBlockConvTrunkNHWC(scale=2)
        self.block2 = IFBlockConvTrunkNHWC(scale=1)

    def forward(self, pair_nhwc: torch.Tensor) -> torch.Tensor:
        pair = pair_nhwc.permute(0, 3, 1, 2).contiguous()
        img0 = pair[:, 0:3]
        img1 = pair[:, 3:6]
        flow = torch.zeros((pair.shape[0], 4, pair.shape[2], pair.shape[3]), dtype=pair.dtype, device=pair.device)
        mask = torch.zeros((pair.shape[0], 1, pair.shape[2], pair.shape[3]), dtype=pair.dtype, device=pair.device)
        warped0 = img0
        warped1 = img1
        for block in (self.block0, self.block1, self.block2):
            x0 = torch.cat((warped0[:, :3], warped1[:, :3], mask), dim=1).permute(0, 2, 3, 1).contiguous()
            flow_nhwc = flow.permute(0, 2, 3, 1).contiguous()
            out0 = block(x0, flow_nhwc).permute(0, 3, 1, 2).contiguous()

            reverse_flow = torch.cat((flow[:, 2:4], flow[:, 0:2]), dim=1)
            x1 = torch.cat((warped1[:, :3], warped0[:, :3], -mask), dim=1).permute(0, 2, 3, 1).contiguous()
            out1 = block(x1, reverse_flow.permute(0, 2, 3, 1).contiguous()).permute(0, 3, 1, 2).contiguous()

            f0 = out0[:, 0:4]
            m0 = out0[:, 4:5]
            f1 = out1[:, 0:4]
            m1 = out1[:, 4:5]
            flow = flow + (f0 + torch.cat((f1[:, 2:4], f1[:, 0:2]), dim=1)) * 0.5
            mask = mask + (m0 - m1) * 0.5
            warped0 = warp_nchw(img0, flow[:, 0:2])
            warped1 = warp_nchw(img1, flow[:, 2:4])

        return torch.cat((flow, mask), dim=1).permute(0, 2, 3, 1).contiguous()


def load_block_weights(model: IFBlockConvTrunkNHWC, tensors: dict[str, torch.Tensor], block: str) -> None:
    state = model.state_dict()
    mapped: dict[str, torch.Tensor] = {}
    for key in state:
        source_key = f"{block}.{key}"
        if source_key not in tensors:
            raise KeyError(f"Missing tensor {source_key}")
        mapped[key] = tensors[source_key].to(dtype=state[key].dtype)
    model.load_state_dict(mapped, strict=True)


def convert_block(args: argparse.Namespace, block: str, scale: int) -> Path:
    import coremltools as ct

    tensors = load_file(str(args.safetensors))
    model = IFBlockConvTrunkNHWC(scale=scale).eval()
    load_block_weights(model, tensors, block)

    x = torch.zeros(1, args.height, args.width, 7, dtype=torch.float32)
    flow = torch.zeros(1, args.height, args.width, 4, dtype=torch.float32)
    traced = torch.jit.trace(model, (x, flow), strict=True)

    output_dir = args.output_dir / f"{block}_s{scale}_{args.width}x{args.height}.mlpackage"
    if output_dir.exists():
        import shutil
        shutil.rmtree(output_dir)

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="x_nhwc", shape=x.shape),
            ct.TensorType(name="flow_nhwc", shape=flow.shape),
        ],
        outputs=[ct.TensorType(name="flow_mask_nhwc")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = f"RIFE {block} conv trunk, NHWC runtime IO"
    mlmodel.author = "Stellaria Motion"
    mlmodel.save(str(output_dir))
    return output_dir


def convert_continuous(args: argparse.Namespace) -> Path:
    import coremltools as ct
    import shutil

    tensors = load_file(str(args.safetensors))
    model = RIFEContinuousFlowMaskNHWC().eval()
    load_block_weights(model.block0, tensors, "block0")
    load_block_weights(model.block1, tensors, "block1")
    load_block_weights(model.block2, tensors, "block2")

    pair = torch.zeros(1, args.height, args.width, 6, dtype=torch.float32)
    traced = torch.jit.trace(model, pair, strict=True)

    output_dir = args.continuous_output_dir / f"rife_flow_mask_{args.width}x{args.height}.mlpackage"
    if output_dir.exists():
        shutil.rmtree(output_dir)

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="pair_nhwc", shape=pair.shape)],
        outputs=[ct.TensorType(name="flow_mask_nhwc")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = "RIFE continuous flow/mask trunk, NHWC runtime IO"
    mlmodel.author = "Stellaria Motion"
    args.continuous_output_dir.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output_dir))

    manifest = {
        "format": "rife-continuous-flow-mask-coreml-nhwc",
        "width": args.width,
        "height": args.height,
        "input": {"pair_nhwc": [1, args.height, args.width, 6]},
        "output": {"flow_mask_nhwc": [1, args.height, args.width, 5]},
        "models": [str(output_dir)],
        "notes": "Single Core ML prediction for accumulated flow/mask; Metal handles texture pack, warp, blend, and present.",
    }
    (args.continuous_output_dir / f"manifest_{args.width}x{args.height}.json").write_text(
        json.dumps(manifest, indent=2) + "\n",
        encoding="utf-8",
    )
    return output_dir


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--safetensors", type=Path, default=Path("Models/RIFE-safetensors/flownet.safetensors"))
    parser.add_argument("--output-dir", type=Path, default=Path("Models/RIFE-CoreML/conv_trunk"))
    parser.add_argument("--continuous-output-dir", type=Path, default=Path("Models/RIFE-CoreML/continuous_trunk"))
    parser.add_argument("--width", type=int, default=960)
    parser.add_argument("--height", type=int, default=544)
    parser.add_argument("--mode", choices=["blocks", "continuous", "all"], default="blocks")
    parser.add_argument("--block", choices=["all", "block0", "block1", "block2"], default="all")
    args = parser.parse_args()

    if args.width % 16 != 0 or args.height % 16 != 0:
        raise SystemExit("--width and --height must be divisible by 16")
    manifests = []
    if args.mode in ("blocks", "all"):
        args.output_dir.mkdir(parents=True, exist_ok=True)
        block_scales = [("block0", 4), ("block1", 2), ("block2", 1)]
        if args.block != "all":
            block_scales = [(b, s) for b, s in block_scales if b == args.block]

        outputs = []
        for block, scale in block_scales:
            outputs.append(str(convert_block(args, block, scale)))

        manifest = {
            "format": "rife-conv-trunk-coreml-nhwc",
            "width": args.width,
            "height": args.height,
            "input": {
                "x_nhwc": [1, args.height, args.width, 7],
                "flow_nhwc": [1, args.height, args.width, 4],
            },
            "output": {
                "flow_mask_nhwc": [1, args.height, args.width, 5],
            },
            "models": outputs,
        }
        (args.output_dir / f"manifest_{args.width}x{args.height}.json").write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )
        manifests.append(manifest)

    if args.mode in ("continuous", "all"):
        output = convert_continuous(args)
        manifests.append({
            "format": "rife-continuous-flow-mask-coreml-nhwc",
            "width": args.width,
            "height": args.height,
            "models": [str(output)],
        })

    print(json.dumps(manifests[-1] if len(manifests) == 1 else manifests, indent=2))


if __name__ == "__main__":
    main()
