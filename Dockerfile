FROM python:3.11

WORKDIR /code

COPY ./app /code
# Script that starts BitNet server and uvicorn
COPY entrypoint.sh /code/entrypoint.sh
RUN chmod +x /code/entrypoint.sh

# Clone BitNet with submodules directly into /code (ensures all files and submodules are present)
RUN git clone --recursive https://github.com/djerz/BitNet.git /tmp/BitNet && \
    cp -r /tmp/BitNet/* /code && \
    rm -rf /tmp/BitNet

# Install dependencies
RUN apt-get update && apt-get install -y \
    wget \
    lsb-release \
    gnupg \
    cmake \
    clang \
    && bash -c "$(wget -O - https://apt.llvm.org/llvm.sh)" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
RUN pip install --no-cache-dir --upgrade -r /code/requirements.txt && \
    pip install "fastapi[standard]" "uvicorn[standard]" httpx fastapi-mcp psutil

# model downloaded with
#  hf download microsoft/BitNet-b1.58-2B-4T-gguf --local-dir app/models/BitNet-b1.58-2B-4T
ENV BN_MODEL="BitNet-b1.58-2B-4T"
ENV BN_MODEL_GGUF="ggml-model-i2_s.gguf"
# Run your setup_env.py if needed
RUN python /code/setup_env.py -md /code/models/$BN_MODEL -q i2_s

EXPOSE 8080
CMD ["/code/entrypoint.sh"]
