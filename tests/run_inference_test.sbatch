#!/usr/bin/env bash
#SBATCH --job-name=rc-inftest
#SBATCH --output=logs/inftest-%j.out
#SBATCH --error=logs/inftest-%j.err
#SBATCH --partition=gpu-interactive
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#
# Self-contained answer to one question: can this cluster run inference, and
# does the RC Copilot prompt produce a usable draft?
#
#   cd /projects/rc/projects/ticket_mate/tests
#   sbatch run_inference_test.sbatch
#   tail -f logs/inftest-<jobid>.out
#
# Defaults to the 3B test model on ANY free GPU, so it schedules in seconds.
# For the real model (one A100 80GB; general-access partitions cap at 1 GPU):
#
#   sbatch --gres=gpu:a100:1 --constraint=a100@80g --mem=120G \
#          --cpus-per-task=16 --export=ALL,MODEL=flash run_inference_test.sbatch
#
# To judge quality on a real ticket, drop it in a file and point at it:
#
#   sbatch --export=ALL,TICKET=/path/to/ticket.txt run_inference_test.sbatch
#
# Touches nothing outside tests/ -- it reads backend/app/prompts.py and
# backend/app/models.py, and writes only into tests/logs/.

set -uo pipefail

TM_ROOT="${TM_ROOT:-/projects/rc/projects/ticket_mate}"
MODEL="${MODEL:-small}"
TICKET="${TICKET:-$TM_ROOT/tests/sample_ticket.txt}"
INSTRUCTIONS="${INSTRUCTIONS:-}"

cd "${SLURM_SUBMIT_DIR:-$TM_ROOT/tests}" || exit 1
mkdir -p logs

echo "======================================================================"
echo " node        $(hostname)"
echo " job         ${SLURM_JOB_ID:-n/a}"
echo " model       $MODEL"
echo " ticket      $TICKET"
echo "======================================================================"

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=index,name,memory.total,compute_cap,driver_version --format=csv
else
  echo "ERROR: no nvidia-smi -- this is not a GPU node."
  exit 1
fi

source "$TM_ROOT/cluster/env.sh"

# --- vLLM on a free loopback port ------------------------------------------
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
LOG="logs/vllm-${SLURM_JOB_ID:-local}.log"

echo
echo "=== starting vLLM on 127.0.0.1:${PORT} (log: $LOG) ==="
MODEL="$MODEL" PORT="$PORT" VLLM_HOST=127.0.0.1 \
  "$TM_ROOT/cluster/serve_glm.sh" > "$LOG" 2>&1 &
VLLM_PID=$!

cleanup() {
  [ -n "${VLLM_PID:-}" ] && kill "$VLLM_PID" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT INT TERM

echo -n "waiting for the model to load"
READY=0
for _ in $(seq 1 120); do          # up to ~20 minutes
  if ! kill -0 "$VLLM_PID" 2>/dev/null; then
    echo
    echo "ERROR: vLLM exited during startup. Last 40 lines of $LOG:"
    echo "----------------------------------------------------------------------"
    tail -40 "$LOG"
    exit 1
  fi
  if curl -sf --noproxy '*' --max-time 3 \
       "http://127.0.0.1:${PORT}/v1/models" -o /dev/null 2>/dev/null; then
    READY=1; echo " ready"; break
  fi
  echo -n "."
  sleep 10
done

if [ "$READY" != 1 ]; then
  echo
  echo "ERROR: vLLM never became ready. Last 40 lines of $LOG:"
  echo "----------------------------------------------------------------------"
  tail -40 "$LOG"
  exit 1
fi

# --- the actual test --------------------------------------------------------
echo
ARGS=(--base-url "http://127.0.0.1:${PORT}/v1" --ticket "$TICKET")
[ -n "$INSTRUCTIONS" ] && ARGS+=(--instructions "$INSTRUCTIONS")

python "$TM_ROOT/tests/inference_test.py" "${ARGS[@]}"
STATUS=$?

echo
echo "======================================================================"
if [ "$STATUS" = 0 ]; then
  echo " RESULT: PASS -- inference works and the prompt produced a valid draft"
else
  echo " RESULT: FAIL -- see the failures above; vLLM log is $LOG"
fi
echo "======================================================================"
exit "$STATUS"
