#!/usr/bin/env bash
#SBATCH --job-name=ood-conn-test
#SBATCH --output=logs/ood-test-%j.out
#SBATCH --error=logs/ood-test-%j.err
#SBATCH --partition=short
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#
# Stands up a JSON endpoint inside a Slurm allocation and prints the exact URL
# to paste into the extension popup.
#
#   sbatch test_connection.sbatch
#   tail -f logs/ood-test-<jobid>.out
#
# Northeastern's Open OnDemand portal. The dashboard you log into lives at
# /pun/sys/dashboard; the node proxy used here is a sibling route at the same
# host. Override for a different portal with:
#
#   sbatch --export=ALL,OOD_HOST=other.host.edu test_connection.sbatch
#
# ──────────────────────────────────────────────────────────────────────────────

set -uo pipefail

OOD_HOST="${OOD_HOST:-ood.explorer.northeastern.edu}"

# OOD exposes two proxy routes and sites differ in which is enabled:
#   /rnode/<host>/<port>   raw passthrough  (what you want for an API)
#   /node/<host>/<port>    rewrites HTML links
# Both are printed below; try rnode first.
OOD_ROUTE="${OOD_ROUTE:-rnode}"

cd "$SLURM_SUBMIT_DIR" || exit 1
mkdir -p logs

NODE="$(hostname -s)"

# Ask the kernel for a free port rather than guessing: compute nodes are shared,
# and a hard-coded port is the most common reason this fails on the second run.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("0.0.0.0",0)); print(s.getsockname()[1]); s.close()')"

SERVER="$SLURM_SUBMIT_DIR/mock_server.py"
if [ ! -f "$SERVER" ]; then
  echo "error: mock_server.py not found next to this script ($SERVER)" >&2
  exit 1
fi

BASE_URL="https://${OOD_HOST}/${OOD_ROUTE}/${NODE}/${PORT}"

cat <<BANNER

════════════════════════════════════════════════════════════════════════
 RC Copilot — OOD connection test
════════════════════════════════════════════════════════════════════════
 job id     ${SLURM_JOB_ID}
 node       ${NODE}
 port       ${PORT}
 time limit $(squeue -j "$SLURM_JOB_ID" -h -o '%l' 2>/dev/null || echo '?')

 PASTE THIS INTO THE EXTENSION POPUP:

     ${BASE_URL}

 If that 404s, your site uses the other route — try:

     https://${OOD_HOST}/node/${NODE}/${PORT}

 Check it from a browser tab first (you must be signed into OOD):

     ${BASE_URL}/health

 Local sanity check, from a login node:

     curl --noproxy '*' http://${NODE}:${PORT}/health

 This URL dies with the job. Resubmit and repaste to get a new one.
════════════════════════════════════════════════════════════════════════

BANNER

exec python3 "$SERVER" --port "$PORT" --host 0.0.0.0
