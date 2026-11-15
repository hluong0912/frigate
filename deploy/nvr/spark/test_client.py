#!/usr/bin/env python3
"""Smoke test for zmq_detector_server.py, speaking the same protocol as Frigate.

  python3 test_client.py tcp://192.168.40.126:5555 ./yolo.onnx [--size 320]

Uploads the model (if the server doesn't have it), then times 200 inferences
on a blank frame. Check the server log for "loaded yolo.onnx on [...]" to see
whether CUDA was used. Needs: pip install pyzmq numpy
"""
import argparse, json, os, time
import numpy as np
import zmq

ap = argparse.ArgumentParser()
ap.add_argument("endpoint"); ap.add_argument("model"); ap.add_argument("--size", type=int, default=320)
a = ap.parse_args()
s = zmq.Context().socket(zmq.REQ); s.setsockopt(zmq.RCVTIMEO, 120000); s.connect(a.endpoint)
name = os.path.basename(a.model)

s.send_multipart([json.dumps({"model_request": True, "model_name": name}).encode()])
r = json.loads(s.recv_multipart()[0]); print("model check:", r)
if not r.get("model_loaded"):
    s.send_multipart([json.dumps({"model_data": True, "model_name": name}).encode(), open(a.model, "rb").read()])
    print("model upload:", json.loads(s.recv_multipart()[0]))

x = np.random.rand(1, 3, a.size, a.size).astype(np.float32)
hdr = json.dumps({"shape": list(x.shape), "dtype": "float32", "model_type": "yologeneric"}).encode()
ts = []
for _ in range(200):
    t = time.perf_counter(); s.send_multipart([hdr, x.tobytes()]); out = s.recv_multipart(); ts.append(time.perf_counter() - t)
res = np.frombuffer(out[0], np.float32).reshape(20, 6)
ts = np.array(ts[10:]) * 1000
print(f"round trip ms: median {np.median(ts):.1f}, p95 {np.percentile(ts, 95):.1f}; result shape {res.shape}")
