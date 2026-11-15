# Remote detector for Frigate, runs on the DGX Spark (arm64 + GB10 GPU).
# Base is a build arg so it can be swapped for whatever CUDA/cuDNN image
# matches the onnxruntime-gpu wheel. Check the startup log line
# "available providers: [...]" includes CUDAExecutionProvider.
ARG BASE_IMAGE=nvcr.io/nvidia/pytorch:25.10-py3
FROM ${BASE_IMAGE}
RUN pip install --no-cache-dir onnxruntime-gpu pyzmq numpy
WORKDIR /app
COPY zmq_detector_server.py .
ENV DETECTOR_BIND=tcp://0.0.0.0:5555 \
    DETECTOR_MODEL_DIR=/models
EXPOSE 5555
CMD ["python3", "-u", "/app/zmq_detector_server.py"]
