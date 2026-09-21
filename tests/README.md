# Inference test

Answers one question: **can this cluster run inference, and does the RC Copilot
prompt produce a usable draft?**

Everything else in this repo has been validated against a stub that returned
canned JSON. This is the first thing that puts a real model behind the real
prompt.

Self-contained. It reads `backend/app/prompts.py` and `backend/app/models.py`
and writes only into `tests/logs/`. Nothing outside `tests/` is modified.

---

## Run it

```bash
ssh you@login.explorer.northeastern.edu
cd /projects/rc/projects/ticket_mate/tests
sbatch run_inference_test.sbatch
tail -f logs/inftest-<jobid>.out
```

Defaults to **Qwen2.5-3B on any free GPU**, so it schedules in seconds rather
than queueing for an A100. The job starts vLLM on loopback, waits for the
weights, runs the test, prints a verdict, and shuts down.

The last line is either:

```
 RESULT: PASS -- inference works and the prompt produced a valid draft
 RESULT: FAIL -- see the failures above; vLLM log is logs/vllm-<jobid>.log
```

### Against the real model

General-access GPU partitions cap at one GPU per job, and GLM-4.7-Flash needs
an 80 GB card:

```bash
sbatch --gres=gpu:a100:1 --constraint=a100@80g --mem=120G \
       --cpus-per-task=16 --export=ALL,MODEL=flash run_inference_test.sbatch
```

### On a real ticket

This is the point of the exercise — the sample ticket only proves the
mechanics. Paste a real one into a file and judge the output yourself:

```bash
sbatch --export=ALL,TICKET=$HOME/ticket.txt run_inference_test.sbatch
```

Add the guidance an RC member would type:

```bash
sbatch --export=ALL,TICKET=$HOME/ticket.txt,INSTRUCTIONS="keep it under 5 lines" \
       run_inference_test.sbatch
```

### Against a server that is already running

If you have the OOD app or `serve_stack.sbatch` up, skip the job entirely:

```bash
source ../cluster/env.sh
python inference_test.py --base-url http://127.0.0.1:8000/v1
```

---

## What it checks

| # | Check | Why it matters |
| --- | --- | --- |
| 1 | A model is being served | Separates "vLLM died" from "the prompt is bad" |
| 2 | A trivial completion works | Proves the CUDA path end to end |
| 2b | Is there a separate reasoning field? | GLM emits reasoning apart from content; that changes parsing |
| 3 | The real prompt with **guided decoding** | The product's preferred path |
| 4 | The real prompt **without** it | The fallback, if the server refuses a JSON schema |
| — | Not truncated | `finish_reason=length` means raise `--max-tokens` |
| — | Valid JSON matching the schema | Validated with the product's own Pydantic model |
| — | Confidence in range, draft non-trivial | Catches a model that returns empty fields |

It then **prints the whole draft** — summary, steps, confidence, caveats, reply.
That part is not pass/fail. A schema-valid draft can still be useless, and only
you can judge whether it is worth sending.

## Files

| File | Purpose |
| --- | --- |
| `run_inference_test.sbatch` | Starts vLLM, runs the test, reports, cleans up |
| `inference_test.py` | The checks; also runs standalone against any endpoint |
| `sample_ticket.txt` | A realistic RC ticket (NumPy 2.x ABI break) |

## Verified

The harness itself was exercised against a fake OpenAI-compatible server in
four modes, so a PASS means something:

- **healthy** → 7 passed, correct draft rendered
- **server refuses `json_schema`** → guided step SKIPs, the prompt-only
  fallback passes; overall PASS, matching how the product behaves
- **model returns prose, not JSON** → schema validation FAILs on both paths and
  the raw output is printed for inspection
- **response truncated** → `finish_reason=length` FAILs and names `--max-tokens`

Not yet run against a real GPU or a real model — that is what you are about to
do.
