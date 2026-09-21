# RC Copilot

**Draft replies to ServiceNow tickets using a private LLM running inside your
own HPC allocation.** Built for the Research Computing team at Northeastern.

One click on a ticket reads it, sends it to a model running in your Slurm job,
and writes a draft into the work notes for you to review. No ticket data leaves
the university, and no ServiceNow API access is needed.

> **Status:** working prototype. The data path is proven end to end with real
> tickets. The model has not yet generated a draft — see
> [Status](#status) before assuming it is finished.

---

## The problem

RC staff answer a lot of tickets that rhyme: out-of-memory kills, quota limits,
module and environment mistakes, access requests. Writing each reply from
scratch is repetitive.

Two constraints shaped the whole design:

- **No ServiceNow API access.** Org policy doesn't grant it, so anything that
  reads a ticket has to work from what's already on screen.
- **Ticket text can't leave Northeastern.** It contains researcher names and
  unpublished work, which rules out any hosted LLM API.

Together they force an unusual shape: the **browser** is the integration point,
and the **model runs in the user's own Slurm allocation**.

---

## How it works

![RC Copilot system architecture](docs/rc-architecture.png)


1. You open a ticket and click **Draft reply**.
2. The extension reads the ticket and offers a box for anything the model should
   know that the ticket doesn't say.
3. It goes through Open OnDemand's authenticated proxy to a FastAPI service in
   your Slurm job, which prompts a GLM model served by vLLM.
4. You get back a summary, suggested steps, a confidence score, caveats, and a
   ready-to-edit draft — written into **work notes**, unsaved.

**Nothing is ever submitted automatically.** A human reviews and clicks Update.

---

## Quick start

**1 — Launch the backend.** In Open OnDemand: *Develop → My Sandbox Apps →
RC Copilot → Launch*. It defaults to a small 3B model on any free GPU, which
schedules in seconds; switch to GLM-4.7-Flash once you're happy it works.

**2 — Install the extension.** Download
[`rc-copilot-servicenow-extension.zip`](rc-copilot-servicenow-extension.zip),
unzip it, then `chrome://extensions` → Developer mode → **Load unpacked** →
select the folder.

**3 — Open OOD's "My Interactive Sessions".** The extension picks up the
address and token on its own; there's nothing to copy.

**4 — Open a ticket** and click **Draft reply**.

### Without the browser at all

The fastest loop for tuning the prompt needs neither the extension nor OOD:

```bash
cd rc-copilot
pip install -r requirements.txt
uvicorn backend.main:app --port 8080
```

Paste tickets at `http://127.0.0.1:8080` and edit
[`backend/prompts.py`](rc-copilot/backend/prompts.py).

---

## Layout

| Path | What it is |
| --- | --- |
| [`rc-copilot/`](rc-copilot) | FastAPI backend — prompt, vLLM client, auth. Knows nothing about ServiceNow |
| [`servicenow-ood-extension/extension/`](servicenow-ood-extension/extension) | Chrome MV3 extension |
| [`servicenow-ood-extension/ood-app/`](servicenow-ood-extension/ood-app) | OOD interactive app: vLLM + backend in one job |
| [`servicenow-ood-extension/ood-app-capture/`](servicenow-ood-extension/ood-app-capture) | Same, no model — stores what's sent, for testing the data path |
| [`servicenow-ood-extension/cluster/`](servicenow-ood-extension/cluster) | sbatch launchers, capture server |

Helper scripts: `install_vllm.sh --check`, `check_gpus.sh`, `vllm_status.sh`,
`smoke_test.py`.

---

## A few things worth knowing

**The structured output is validated, not trusted.** The model returns JSON;
three strategies are tried (constrained decoding → JSON mode → prompt-only) and
whatever comes back is parsed tolerantly and checked against a schema. The
high/medium/low confidence thresholds are applied *server-side* — the model
supplies a number, we decide what it means.

**The extension can't fetch from the page.** An MV3 content script runs in the
page's origin and is subject to CORS, so all network I/O goes through the
service worker, where `host_permissions` applies instead.

**Three ServiceNow UIs, one content script.** Classic puts the form in an
iframe, Next Experience hides fields in shadow DOM, Service Portal uses its own
id convention. Rather than three sets of selectors, fields are found by a
shadow-piercing DOM walk matched on id, name, `aria-label` and label text.

**Drafts go to work notes, not customer-visible comments** — so a mis-click on
Update can't send unreviewed model output to a researcher.

---

## Status

**Proven**

- Full data path with real tickets: ServiceNow → extension → OOD → Slurm job →
  disk, including ticket-number extraction
- Auth against tampered signatures and forged expiries
- The OOD proxy path, field matching across all three UIs, partition/GPU limits

**Not yet proven**

- **The model has never produced a draft.** Every backend test used a stub
  returning canned JSON, so prompt quality — the actual point — is unvalidated
- The GLM stack hasn't completed a run on a GPU node

**Next step:** one real inference, then 20–30 tickets through the local UI to
tune the prompt. Everything built so far is plumbing around that untested core.

---

## Documentation

| Document | For |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Full design: components, security model, design decisions, deployment |
| [VLLM_SETUP.md](VLLM_SETUP.md) | Model layer: which GLM fits A100 hardware, and the CUDA install trap |
| [servicenow-ood-extension/README.md](servicenow-ood-extension/README.md) | Extension + OOD apps in detail |
| [rc-copilot/README.md](rc-copilot/README.md) | Backend configuration and API |

---

## Caveats

This is a prototype built against one institution's setup. Hostnames, partition
names and GPU types are Northeastern-specific and would need changing elsewhere.

Every draft is a starting point. The model can be confidently wrong — that's why
`caveats` is a first-class field in the response and is shown but deliberately
never written into the ticket.
