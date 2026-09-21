#!/usr/bin/env bash
#SBATCH --job-name=glm-vllm
#SBATCH --output=logs/glm-vllm-%j.out
#SBATCH --error=logs/glm-vllm-%j.err
#SBATCH --partition=gpu
#SBATCH --gres=gpu:a100:2
#SBATCH --cpus-per-task=16
#SBATCH --mem=200G
#SBATCH --time=08:00:00
#
# Submit with:  sbatch sbatch_serve.sh
#
# ADJUST BEFORE FIRST USE -- partition names and gres strings are site-specific.
# Check yours with:
#     sinfo -o '%20P %10G %8D %10t %N'
#     scontrol show node <a100-node> | grep -i gres
# Then set --partition and --gres to match. For GLM-4.5-Air use gpu:a100:4 and
# set MODEL=air below.

set -euo pipefail
cd /projects/rc/projects/ticket_mate
mkdir -p logs

source env.sh

echo "=== node: $(hostname) ==="
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv
python -c "import torch; print('torch', torch.__version__, '| cuda', torch.version.cuda, '| gpus', torch.cuda.device_count())"

# MODEL=flash -> GLM-4.7-Flash (2 GPUs) | MODEL=air -> GLM-4.5-Air (4 GPUs)
export MODEL="${MODEL:-flash}"
export TP="${TP:-$(python -c 'import torch; print(torch.cuda.device_count())')}"

echo "=== serving (MODEL=$MODEL TP=$TP) on $(hostname):8000 ==="
echo "Tunnel from your laptop with:"
echo "  ssh -N -L 8000:$(hostname):8000 ${USER}@login.explorer.northeastern.edu"

./serve_glm.sh
