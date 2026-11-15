#!/usr/bin/env bash
# Export a YOLOv9 ONNX model for Frigate (same recipe as Frigate's docs,
# "YOLOv9 for other detectors"). Output: ./yolo.onnx
# Usage: ./export-yolov9.sh [size t|s|m|c|e] [imgsz 320|640]
set -euo pipefail
MODEL_SIZE=${1:-s}
IMG_SIZE=${2:-320}
out=$(mktemp -d)
docker build "$out" --build-arg MODEL_SIZE="$MODEL_SIZE" --build-arg IMG_SIZE="$IMG_SIZE" --output "$out" -f- <<'EOF'
FROM python:3.11 AS build
RUN apt-get update && apt-get install --no-install-recommends -y cmake libgl1 && rm -rf /var/lib/apt/lists/*
COPY --from=ghcr.io/astral-sh/uv:0.10.4 /uv /bin/
WORKDIR /yolov9
ADD https://github.com/WongKinYiu/yolov9.git .
RUN uv pip install --system -r requirements.txt
RUN uv pip install --system onnx==1.18.0 onnxruntime onnx-simplifier==0.4.* onnxscript
ARG MODEL_SIZE
ARG IMG_SIZE
ADD https://github.com/WongKinYiu/yolov9/releases/download/v0.1/yolov9-${MODEL_SIZE}-converted.pt yolov9-${MODEL_SIZE}.pt
RUN sed -i "s/ckpt = torch.load(attempt_download(w), map_location='cpu')/ckpt = torch.load(attempt_download(w), map_location='cpu', weights_only=False)/g" models/experimental.py
RUN python3 export.py --weights ./yolov9-${MODEL_SIZE}.pt --imgsz ${IMG_SIZE} --simplify --include onnx
FROM scratch
ARG MODEL_SIZE
ARG IMG_SIZE
COPY --from=build /yolov9/yolov9-${MODEL_SIZE}.onnx /yolo.onnx
EOF
mv "$out/yolo.onnx" ./yolo.onnx
rm -rf "$out"
echo "wrote ./yolo.onnx (yolov9-$MODEL_SIZE, ${IMG_SIZE}px). Copy it to the NVR host: /srv/frigate/config/model_cache/yolo.onnx"
