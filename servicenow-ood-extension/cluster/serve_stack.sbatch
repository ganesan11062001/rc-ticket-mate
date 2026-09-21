#!/usr/bin/env bash
#SBATCH --job-name=rc-copilot
#SBATCH --output=logs/rc-copilot-%j.out
#SBATCH --error=logs/rc-copilot-%j.err
#SBATCH --partition=gpu-interactive
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#
# The whole product in one allocation:
#
#   vLLM        127.0.0.1:8000   loopback only — nothing outside needs it
#   rc-copilot  0.0.0.0:<port>   reachable, so the OOD node proxy can find it
#
# Defaults to the 3B test model on ANY free GPU, because A100s queue and you
# do not need one to prove the pipeline works:
#
#   sbatch serve_stack.sbatch
#   tail -f logs/rc-copilot-<jobid>.out
#
# For the real model (one A100 80GB; note every general-access GPU partition
# allows only 1 GPU per job):
#
#   sbatch --gres=gpu:a100:1 --constraint=a100@80g --mem=120G \
#          --cpus-per-task=16 --export=ALL,MODEL=flash serve_stack.sbatch
#
# rc-copilot listens on 0.0.0.0 because the OOD web node has to reach it across
# the network — which also means every other user on the cluster can reach the
# port. That is exactly why AUTH_TOKEN below is not optional.

set -uo pipefail

TM_ROOT="${TM_ROOT:-/projects/rc/projects/ticket_mate}"
OOD_HOST="${OOD_HOST:-ood.explorer.northeastern.edu}"
OOD_ROUTE="${OOD_ROUTE:-rnode}"
MODEL="${MODEL:-small}"
SESSION_HOURS="${SESSION_HOURS:-3}"

# Token file lives in $HOME (mode 600), never on group-readable /projects.
TOKEN_DIR="$HOME/.rc_copilot"
TOKEN_FILE="$TOKEN_DIR/token"

cd "$SLURM_SUBMIT_DIR" || exit 1
mkdir -p logs

NODE="$(hostname -s)"

# ── ports ─────────────────────────────────────────────────────────────────────
# Compute nodes are shared; never hard-code. Ask the kernel for a free one.
free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("0.0.0.0",0)); print(s.getsockname()[1]); s.close()'
}
APP_PORT="$(free_port)"
VLLM_PORT="${VLLM_PORT:-8000}"

# ── access token ──────────────────────────────────────────────────────────────
mkdir -p "$TOKEN_DIR"
chmod 700 "$TOKEN_DIR"
TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
umask 077
printf '%s\n' "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

# Slurm creates job logs group-readable. This one will carry no secrets, but
# tighten it anyway since it names the node and port.
chmod 600 "logs/rc-copilot-${SLURM_JOB_ID}.out" 2>/dev/null || true
chmod 600 "logs/rc-copilot-${SLURM_JOB_ID}.err" 2>/dev/null || true

# ── cleanup ───────────────────────────────────────────────────────────────────
VLLM_PID=""
APP_PID=""
cleanup() {
  echo
  echo "shutting down..."
  [ -n "$APP_PID" ]  && kill "$APP_PID"  2>/dev/null
  [ -n "$VLLM_PID" ] && kill "$VLLM_PID" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT INT TERM

# ── vLLM ──────────────────────────────────────────────────────────────────────
source "$TM_ROOT/env.sh"

echo "=== node: $NODE | job: $SLURM_JOB_ID ==="
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv

echo "=== starting vLLM (loopback only, port $VLLM_PORT) ==="
MODEL="$MODEL" PORT="$VLLM_PORT" VLLM_HOST=127.0.0.1 \
  "$TM_ROOT/serve_glm.sh" > "logs/vllm-${SLURM_JOB_ID}.out" 2>&1 &
VLLM_PID=$!

# Weight loading takes minutes. Poll rather than guessing a sleep.
echo -n "waiting for vLLM"
VLLM_READY=0
for _ in $(seq 1 120); do   # up to ~20 minutes
  if ! kill -0 "$VLLM_PID" 2>/dev/null; then
    echo
    echo "ERROR: vLLM exited early. Last lines of logs/vllm-${SLURM_JOB_ID}.out:"
    tail -30 "logs/vllm-${SLURM_JOB_ID}.out"
    exit 1
  fi
  if curl -sf --noproxy '*' --max-time 3 \
       "http://127.0.0.1:${VLLM_PORT}/v1/models" -o /dev/null; then
    VLLM_READY=1
    echo " ready"
    break
  fi
  echo -n "."
  sleep 10
done

if [ "$VLLM_READY" != 1 ]; then
  echo
  echo "ERROR: vLLM never became ready. See logs/vllm-${SLURM_JOB_ID}.out"
  exit 1
fi

SERVED_MODEL="$(curl -sf --noproxy '*' "http://127.0.0.1:${VLLM_PORT}/v1/models" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')"

# ── rc-copilot ────────────────────────────────────────────────────────────────
cd "$TM_ROOT/rc-copilot" || exit 1

export VLLM_BASE_URL="http://127.0.0.1:${VLLM_PORT}/v1"
export VLLM_MODEL_NAME="$SERVED_MODEL"
export AUTH_TOKEN="$TOKEN"
export SESSION_HOURS="$SESSION_HOURS"
export LOG_FILE=""          # stdout only; nothing extra on /projects
export USE_PROXY_ENV=false

echo "=== starting rc-copilot on 0.0.0.0:${APP_PORT} ==="
"$TM_ROOT/rc-copilot/.venv/bin/python" -m uvicorn backend.main:app \
  --host 0.0.0.0 --port "$APP_PORT" &
APP_PID=$!

sleep 5
if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "ERROR: rc-copilot failed to start."
  exit 1
fi

BASE_URL="https://${OOD_HOST}/${OOD_ROUTE}/${NODE}/${APP_PORT}"

cat <<BANNER

════════════════════════════════════════════════════════════════════════
 RC Copilot is up
════════════════════════════════════════════════════════════════════════
 job          ${SLURM_JOB_ID}
 node         ${NODE}
 model        ${SERVED_MODEL}
 app port     ${APP_PORT}

 PASTE THIS URL INTO THE EXTENSION POPUP:

     ${BASE_URL}

 If that 404s, your portal uses the other proxy route — try:

     https://${OOD_HOST}/node/${NODE}/${APP_PORT}

 ACCESS TOKEN — not printed here (job logs are group-readable). Read it
 from your home directory, which is mode 600:

     cat ${TOKEN_FILE}

 Sanity check from a login node:

     curl --noproxy '*' http://${NODE}:${APP_PORT}/api/health

 Both URL and token change every time this job is resubmitted.
════════════════════════════════════════════════════════════════════════

BANNER

wait "$APP_PID"
