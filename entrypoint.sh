#!/usr/bin/env bash
set -e

# 1) Start BitNet server on an internal port (example 5000)
python /code/run_inference_server.py -m /code/models/$BN_MODEL/$BN_MODEL_GGUF --host 0.0.0.0 --port 5000 &

# 2) Start OpenAI-compatible shim on 8080
exec uvicorn main:app --host 0.0.0.0 --port 8080

