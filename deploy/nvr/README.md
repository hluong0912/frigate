# Frigate NVR deployment (LAN host + DGX Spark inference + NAS offload)

Chosen host: **192.168.40.249 (debdb)**, 100 GB local, offload at 70 GB. The .182 profile is kept below for reference.

This folder holds what's needed to run Frigate on one of the LAN Debian VMs,
with **all object detection running on the DGX Spark** and **older recordings
moved to the NAS** once local usage passes a threshold.

```
cameras ──RTSP──> NVR host (Frigate, decode + record)
                     │  zmq over TCP :5555 (frame tensors / detections)
                     ├──────────────────────────────> DGX Spark (spark/zmq_detector_server.py, GPU)
                     │  rsync, oldest hours first
                     └──────────────────────────────> NAS "frigate" folder
```

| Folder | Runs on | What it is |
|---|---|---|
| `docker-compose.yml`, `.env.example`, `frigate/config/config.yml` | NVR host | Frigate itself |
| `offload/` | NVR host | systemd timer + script that moves old recordings to the NAS |
| `spark/` | DGX Spark | ZMQ inference server that Frigate's `zmq` detector talks to |

## Host profiles

| | .182 (dockerDeb) | .249 (debdb) |
|---|---|---|
| Local recordings | ~40 GB | ~100 GB |
| Offload starts at | 30 GB (`HIGH_WATER_GB=30`) | 70 GB (`HIGH_WATER_GB=70`) |
| Offload down to | 25 GB (`LOW_WATER_GB=25`) | 60 GB (`LOW_WATER_GB=60`) |
| Suggested `FRIGATE_MEDIA_DIR` | dedicated 40 GB virtual disk | `/mnt/chnvme/frigate/media` |
| Notes | 4 vCPU shared with PlatformX; port 5000 taken by the registry | 6 vCPU, mostly idle |

Neither VM has a GPU or iGPU passed through, so video **decoding** happens on
the CPU. Detection never runs on the host. Keep the detect stream on each
camera's low-res sub stream and `detect.fps` at 5.

## 1. DGX Spark: inference server

```bash
cd deploy/nvr/spark
docker compose up -d --build
docker logs -f frigate-detector   # expect: "available providers: [... 'CUDAExecutionProvider' ...]"
```

If the log only lists `CPUExecutionProvider`, the onnxruntime-gpu wheel doesn't
match the base image's CUDA. Rebuild with a different base:
`docker compose build --build-arg BASE_IMAGE=<cuda+cudnn image>`. CPU still
works, it's just slower.

Restrict port 5555 to the NVR host, for example
`sudo ufw allow from 192.168.40.249 to any port 5555 proto tcp`.

The server keeps models in `spark/models/`. Frigate uploads its model there
the first time it connects.

## 2. Model

Frigate config uses a `yolo-generic` ONNX model at `/config/model_cache/yolo.onnx`, 320x320.
Export YOLOv9 (Frigate docs recipe) and check the GPU path on the Spark:

```bash
cd ~/frigate-detector
./export-yolov9.sh s 320                      # writes ./yolo.onnx (run on an x86 box: onnx-simplifier has no arm64 wheel)
python3 test_client.py tcp://127.0.0.1:5555 ./yolo.onnx
docker logs frigate-detector | grep loaded    # want: loaded yolo.onnx on ['CUDAExecutionProvider', ...]
```

Then copy `yolo.onnx` to `${FRIGATE_CONFIG_DIR}/model_cache/yolo.onnx` on the NVR host.

## 3. NVR host: Frigate

```bash
sudo mkdir -p /srv/frigate/config/model_cache
sudo mkdir -p "$FRIGATE_MEDIA_DIR"        # see host profile above
cp .env.example .env                      # fill in CHANGE_ME values
sudo cp frigate/config/config.yml /srv/frigate/config/config.yml
# edit config.yml: Spark IP in detectors.spark.endpoint, cameras, go2rtc streams
docker compose up -d
docker logs -f frigate                    # expect: "Model yolo.onnx is ready"
```

UI: `https://<host>:8971`. The admin password is printed in the logs on first start.

## 4. NVR host: NAS offload

The NAS share has to be mounted on the host. Both VMs already mount the
Synology (192.168.40.39) over NFS at `/mnt/archive`. If the "frigate" folder
lives there, set `NAS_MOUNT=/mnt/archive` and `NAS_SUBDIR=frigate/recordings`.
Otherwise mount the share using `offload/nas-mount.example`.

```bash
sudo apt install -y rsync curl
sudo install -m 755 offload/frigate-offload.sh /usr/local/bin/
sudo install -m 600 offload/frigate-offload.env.example /etc/frigate-offload.env   # then edit
sudo install -m 644 offload/frigate-offload.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload

# try it without moving anything
sudo DRY_RUN=1 FRIGATE_OFFLOAD_CONF=/etc/frigate-offload.env /usr/local/bin/frigate-offload.sh

sudo systemctl enable --now frigate-offload.timer
journalctl -u frigate-offload -f
```

How it works, every 10 minutes:
1. Exits unless the NAS is actually mounted.
2. If `recordings/` is under `HIGH_WATER_GB`, does nothing.
3. Otherwise moves whole hour folders (`YYYY-MM-DD/HH`, UTC), oldest first,
   to `<NAS_MOUNT>/<NAS_SUBDIR>/` with `rsync --remove-source-files` until
   usage is under `LOW_WATER_GB`. Hours newer than `MIN_AGE_MINUTES` are never touched.
4. Calls Frigate's `/api/media/sync` so the timeline drops segments that are no longer local.

Moved footage keeps Frigate's layout (`YYYY-MM-DD/HH/<camera>/MM.SS.mp4`) and
plays in any video player. It's no longer browsable in the Frigate UI.

Frigate's own day-based retention (30 days in `config.yml`) is only a safety
net. Frigate also deletes the oldest footage by itself if the disk gets within
about an hour of full.

If the NAS is NFS with root squash, make sure root on the host can write to
the target folder, or run the service as a user that can.

## Testing without cameras

`frigate/config/config.test.yml` defines two fake cameras (`test1`, `test2`)
that loop a sample video with people, bikes and cars:

```bash
mkdir -p /mnt/chnvme/frigate/media/test
curl -L -o /mnt/chnvme/frigate/media/test/sample.mp4 \
  https://github.com/intel-iot-devkit/sample-videos/raw/master/person-bicycle-car-detection.mp4
cp frigate/config/config.test.yml /srv/frigate/config/config.yml
docker compose up -d
```

Expect `Model yolo.onnx is ready` in `docker logs frigate`, detections in the
UI, and recordings under `recordings/`. To test the NAS move without waiting
for 70 GB, run it once against a copy of the env file with low thresholds:

```bash
sed -e 's/^HIGH_WATER_GB=.*/HIGH_WATER_GB=0/' -e 's/^LOW_WATER_GB=.*/LOW_WATER_GB=0/' \
    -e 's/^MIN_AGE_MINUTES=.*/MIN_AGE_MINUTES=60/' /etc/frigate-offload.env > /tmp/offload-test.env
sudo FRIGATE_OFFLOAD_CONF=/tmp/offload-test.env /usr/local/bin/frigate-offload.sh
```
