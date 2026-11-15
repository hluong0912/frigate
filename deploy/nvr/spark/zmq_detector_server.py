#!/usr/bin/env python3
"""Remote object detector for Frigate, meant to run on the DGX Spark.

Speaks the protocol of Frigate's `zmq` detector (frigate/detectors/plugins/zmq_ipc.py)
over TCP, so the NVR host does no inference at all:

  model check   <- [{"model_request": true, "model_name": ...}]
                -> [{"model_available": bool, "model_loaded": bool}]
  model upload  <- [{"model_data": true, "model_name": ...}, <onnx bytes>]
                -> [{"model_saved": bool, "model_loaded": bool}]
  inference     <- [{"shape": [...], "dtype": "...", "model_type": ...}, <tensor bytes>]
                -> [<20x6 float32 bytes>]  rows: class_id, score, y1, x1, y2, x2 (0..1)

Supports `yolo-generic` single-output ONNX models (YOLOv9 / v8 / 11 style,
output [1, 4 + classes, anchors]), which is what deploy/nvr/frigate/config uses.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import time

import numpy as np
import onnxruntime as ort
import zmq

log = logging.getLogger("spark-detector")

ZERO = np.zeros((20, 6), np.float32)


def nms(boxes: np.ndarray, scores: np.ndarray, iou_thr: float) -> list[int]:
    """Plain numpy NMS. boxes are x1, y1, x2, y2."""
    order = scores.argsort()[::-1]
    keep: list[int] = []
    areas = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    while order.size and len(keep) < 20:
        i = int(order[0])
        keep.append(i)
        xx1 = np.maximum(boxes[i, 0], boxes[order[1:], 0])
        yy1 = np.maximum(boxes[i, 1], boxes[order[1:], 1])
        xx2 = np.minimum(boxes[i, 2], boxes[order[1:], 2])
        yy2 = np.minimum(boxes[i, 3], boxes[order[1:], 3])
        inter = np.clip(xx2 - xx1, 0, None) * np.clip(yy2 - yy1, 0, None)
        iou = inter / (areas[i] + areas[order[1:]] - inter + 1e-9)
        order = order[1:][iou <= iou_thr]
    return keep


def post_process_yolo(pred: np.ndarray, width: int, height: int,
                      score_thr: float = 0.4, iou_thr: float = 0.4) -> np.ndarray:
    """Same math as Frigate's __post_process_nms_yolo (frigate/util/model.py)."""
    pred = np.squeeze(pred)
    if pred.shape[0] < pred.shape[1]:
        pred = pred.T  # -> (anchors, 4 + classes)
    scores = pred[:, 4:].max(axis=1)
    mask = scores > score_thr
    pred, scores = pred[mask], scores[mask]
    if not len(pred):
        return ZERO.copy()
    class_ids = pred[:, 4:].argmax(axis=1)
    cx, cy, w, h = pred[:, 0], pred[:, 1], pred[:, 2], pred[:, 3]
    boxes = np.stack([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2], axis=1)
    out = ZERO.copy()
    for row, i in enumerate(nms(boxes, scores, iou_thr)):
        x1, y1, x2, y2 = boxes[i]
        out[row] = [class_ids[i], scores[i], y1 / height, x1 / width, y2 / height, x2 / width]
    return out


class Detector:
    def __init__(self, model_dir: str, providers: list[str]):
        self.model_dir = model_dir
        self.providers = providers
        self.session: ort.InferenceSession | None = None
        self.model_name: str | None = None
        os.makedirs(model_dir, exist_ok=True)

    def path(self, name: str) -> str:
        return os.path.join(self.model_dir, os.path.basename(name))

    def load(self, name: str) -> bool:
        if self.session is not None and self.model_name == name:
            return True
        path = self.path(name)
        if not os.path.exists(path):
            return False
        try:
            available = ort.get_available_providers()
            providers: list = [p for p in self.providers if p in available] or ["CPUExecutionProvider"]
            if "TensorrtExecutionProvider" in providers:
                # cache built engines so restarts don't rebuild (first build can take minutes)
                idx = providers.index("TensorrtExecutionProvider")
                providers[idx] = ("TensorrtExecutionProvider", {
                    "trt_fp16_enable": True,
                    "trt_engine_cache_enable": True,
                    "trt_engine_cache_path": os.path.join(self.model_dir, "trt_cache"),
                })
            opts = ort.SessionOptions()
            opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
            self.session = ort.InferenceSession(path, sess_options=opts, providers=providers)
            self.model_name = name
            inp = self.session.get_inputs()[0]
            log.info("loaded %s on %s, input %s %s", name, self.session.get_providers(),
                     inp.name, inp.shape)
            # warm-up so the first real frame isn't slow (TensorRT builds here)
            shape = [d if isinstance(d, int) else 1 for d in inp.shape]
            self.session.run(None, {inp.name: np.zeros(shape, np.float32)})
            return True
        except Exception:
            log.exception("failed to load %s", name)
            self.session = None
            return False

    def save(self, name: str, data: bytes) -> bool:
        try:
            tmp = self.path(name) + ".part"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, self.path(name))
            return True
        except Exception:
            log.exception("failed to save %s", name)
            return False

    def infer(self, tensor: np.ndarray) -> np.ndarray:
        if self.session is None:
            return ZERO
        inp = self.session.get_inputs()[0]
        if tensor.dtype != np.float32:
            tensor = tensor.astype(np.float32)
        # Frigate sends nchw float already normalised for yolo-generic + input_dtype float
        h, w = tensor.shape[2], tensor.shape[3]
        outputs = self.session.run(None, {inp.name: tensor})
        if len(outputs) != 1:
            log.warning("multi-output YOLO models are not supported by this server")
            return ZERO
        return post_process_yolo(outputs[0], w, h)


def serve(bind: str, det: Detector) -> None:
    ctx = zmq.Context()
    sock = ctx.socket(zmq.REP)
    sock.bind(bind)
    log.info("listening on %s", bind)
    stop = False

    def _stop(*_):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    poller = zmq.Poller()
    poller.register(sock, zmq.POLLIN)
    n, t_sum, t_last = 0, 0.0, time.time()

    while not stop:
        if not poller.poll(500):
            continue
        frames = sock.recv_multipart()
        try:
            header = json.loads(frames[0].decode("utf-8"))
        except Exception:
            sock.send_multipart([ZERO.tobytes()])
            continue

        if header.get("model_request"):
            name = header.get("model_name", "")
            available = os.path.exists(det.path(name))
            loaded = det.load(name) if available else False
            sock.send_multipart([json.dumps({"model_available": available,
                                             "model_loaded": loaded}).encode()])
            continue

        if header.get("model_data"):
            name = header.get("model_name", "")
            saved = len(frames) > 1 and det.save(name, frames[1])
            loaded = saved and det.load(name)
            sock.send_multipart([json.dumps({"model_saved": saved,
                                             "model_loaded": loaded}).encode()])
            continue

        try:
            tensor = np.frombuffer(frames[1], dtype=np.dtype(header["dtype"])).reshape(header["shape"])
            t0 = time.perf_counter()
            result = det.infer(tensor)
            t_sum += time.perf_counter() - t0
            n += 1
        except Exception:
            log.exception("inference failed")
            result = ZERO
        sock.send_multipart([np.ascontiguousarray(result, np.float32).tobytes()])

        if time.time() - t_last > 60 and n:
            log.info("%d inferences in last minute, avg %.1f ms", n, 1000 * t_sum / n)
            n, t_sum, t_last = 0, 0.0, time.time()

    sock.close(linger=0)
    ctx.term()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bind", default=os.environ.get("DETECTOR_BIND", "tcp://0.0.0.0:5555"))
    ap.add_argument("--model-dir", default=os.environ.get("DETECTOR_MODEL_DIR", "/models"))
    ap.add_argument("--providers", default=os.environ.get(
        "DETECTOR_PROVIDERS", "CUDAExecutionProvider,CPUExecutionProvider"))
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    log.info("onnxruntime %s, available providers: %s", ort.__version__, ort.get_available_providers())
    serve(args.bind, Detector(args.model_dir, args.providers.split(",")))


if __name__ == "__main__":
    main()
