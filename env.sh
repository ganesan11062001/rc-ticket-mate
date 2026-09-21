#!/usr/bin/env bash
# Source this before running anything: `source env.sh`
# Sets up the vLLM venv + caches on /projects (home dirs have tight quotas).

export TM_ROOT=/projects/rc/projects/ticket_mate

# uv + the project venv
export PATH="$TM_ROOT/.uv/bin:$PATH"
export UV_CACHE_DIR="$TM_ROOT/.cache/uv"
export UV_PYTHON_INSTALL_DIR="$TM_ROOT/.uv/python"
export VIRTUAL_ENV="$TM_ROOT/.venv"
export PATH="$VIRTUAL_ENV/bin:$PATH"

# Keep the multi-hundred-GB model downloads off $HOME
export HF_HOME="$TM_ROOT/.cache/huggingface"
export HF_HUB_ENABLE_HF_TRANSFER=1

# vLLM scratch
export VLLM_CACHE_ROOT="$TM_ROOT/.cache/vllm"
export OUTLINES_CACHE_DIR="$TM_ROOT/.cache/outlines"
export TRITON_CACHE_DIR="$TM_ROOT/.cache/triton"

mkdir -p "$HF_HOME" "$VLLM_CACHE_ROOT" "$TRITON_CACHE_DIR"

# CUDA runtime from the cluster module tree (A100 = sm80).
# The torch wheels bundle their own CUDA libs, so this is only needed for nvcc
# and for tools that link against the system CUDA.
if [ -d /shared/EL9/explorer/cuda/12.8.0 ]; then
  export CUDA_HOME=/shared/EL9/explorer/cuda/12.8.0
  export PATH="$CUDA_HOME/bin:$PATH"
  export LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"
fi
