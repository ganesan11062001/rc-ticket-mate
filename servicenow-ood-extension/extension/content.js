/* Runs on ServiceNow pages. Reads the open ticket, asks the backend for a
 * draft, writes it into the work notes.
 *
 * Handles both ServiceNow UIs:
 *
 *   Classic          form lives inside an iframe (#gsft_main), plain DOM.
 *                    The manifest sets all_frames:true so we run in there.
 *   Next Experience  form is web components with closed-ish shadow roots, so
 *                    querySelector alone never reaches the inputs.
 *
 * Both are handled by collecting fields with a shadow-piercing walk instead of
 * relying on selectors that only work in one of them.
 */

(function () {
  "use strict";

  const BUTTON_ID = "rc-copilot-btn";
  const PANEL_ID = "rc-copilot-panel";
  const MAX_ACTIVITY_CHARS = 4000;

  /* ---------- field discovery ---------- */

  /* Walk the DOM including shadow roots. Next Experience needs this; Classic
     is unaffected because it simply has no shadow roots to descend into. */
  function deepCollect(root, out, depth) {
    if (depth > 12) return out; // guard against pathological nesting
    let nodes;
    try {
      nodes = root.querySelectorAll("input, textarea, [contenteditable='true']");
    } catch (err) {
      return out;
    }
    for (const node of nodes) out.push(node);

    let all;
    try {
      all = root.querySelectorAll("*");
    } catch (err) {
      return out;
    }
    for (const el of all) {
      if (el.shadowRoot) deepCollect(el.shadowRoot, out, depth + 1);
    }
    return out;
  }

  function allFields() {
    return deepCollect(document, [], 0).filter(function (node) {
      if (node.type === "hidden" || node.disabled) return false;
      if (node.offsetParent === null && node.getClientRects().length === 0) return false;
      return true;
    });
  }

  /* Everything we can use to recognise a field, lowercased into one string. */
  function signature(node) {
    const parts = [
      node.id,
      node.name,
      node.getAttribute("aria-label"),
      node.getAttribute("placeholder"),
      node.getAttribute("data-field"),
      node.getAttribute("data-type")
    ];
    if (node.labels && node.labels.length) {
      for (const label of node.labels) parts.push(label.textContent);
    }
    return parts.filter(Boolean).join(" | ").toLowerCase();
  }

  const PATTERNS = {
    // Anchored on both sides: a loose /number/ would match phone_number,
    // account_number, sys_id fields and so on.
    ticket_number: /(^|[\s|._-])number([\s|._-]|$)/,
    short_description: /short[\s._-]*description/,
    description: /(^|[\s|._-])description/,
    work_notes: /work[\s._-]*notes/,
    comments: /additional\s*comments|(^|[\s|._-])comments([\s|._-]|$)/
  };

  function findField(key) {
    const wanted = PATTERNS[key];
    if (!wanted) return null;

    const candidates = allFields().filter(function (node) {
      const sig = signature(node);
      if (!wanted.test(sig)) return false;
      // "description" must not swallow "short description".
      if (key === "description" && PATTERNS.short_description.test(sig)) return false;
      return true;
    });

    // Prefer a writable one; fall back to read-only for reading.
    return candidates.find((n) => !n.readOnly) || candidates[0] || null;
  }

  function readValue(node) {
    if (!node) return "";
    if (node.isContentEditable) return (node.innerText || "").trim();
    return (node.value || "").trim();
  }

  /* Best effort: the activity stream gives the model prior context. Its markup
     differs a lot between versions, so treat an empty result as normal. */
  function readActivity() {
    const selectors = [
      ".sn-widget-list-table_v2",
      "#activity-stream",
      "[data-stream-entries]",
      ".h-card-wrapper"
    ];
    for (const selector of selectors) {
      const node = document.querySelector(selector);
      if (node && node.innerText && node.innerText.trim()) {
        return node.innerText.trim().slice(0, MAX_ACTIVITY_CHARS);
      }
    }
    return "";
  }

  /* Northeastern runs ServiceNow on a custom domain (service.northeastern.edu),
     so the hostname tells us nothing about which UI we're in. Detect from the
     DOM instead. Three are possible:
       Classic         agent form inside the #gsft_main iframe
       Next Experience agent workspace, web components + shadow DOM
       Service Portal  the "Service Hub" requester portal, AngularJS */
  function detectUi() {
    if (document.querySelector("now-record-form, now-app-root, [id^='sn-']")) {
      return "Next Experience";
    }
    if (window.name === "gsft_main" || document.querySelector("[id^='element.'], [id^='sys_display.']")) {
      return "Classic";
    }
    if (document.querySelector("[id^='sp_formfield_'], .sp-form, #sp-page-root, sp-page, .sp-widget")) {
      return "Service Portal";
    }
    return "Unknown";
  }

  /* ---------- writing ---------- */

  /* Assigning .value silently is not enough: ServiceNow's client scripts and
     its unsaved-changes tracker only react to events. Go through the native
     setter (frameworks patch the property) and then dispatch. */
  function setFieldValue(node, value) {
    if (node.isContentEditable) {
      node.textContent = value;
      node.dispatchEvent(new Event("input", { bubbles: true }));
      return true;
    }

    const proto =
      node instanceof HTMLTextAreaElement
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
    const descriptor = Object.getOwnPropertyDescriptor(proto, "value");
    if (!descriptor || !descriptor.set) return false;

    node.focus();
    descriptor.set.call(node, value);
    node.dispatchEvent(new Event("input", { bubbles: true }));
    node.dispatchEvent(new Event("change", { bubbles: true }));
    node.blur();
    return true;
  }

  /* ---------- UI ---------- */

  function panel() {
    let box = document.getElementById(PANEL_ID);
    if (box) return box;

    box = document.createElement("div");
    box.id = PANEL_ID;
    box.className = "rc-panel";
    box.setAttribute("role", "dialog");
    box.setAttribute("aria-label", "RC Copilot draft");
    box.innerHTML =
      '<div class="rc-head">' +
      '<span class="rc-badge-mark" aria-hidden="true"></span>' +
      '<span class="rc-title">RC Copilot</span>' +
      '<button type="button" class="rc-close" aria-label="Close">\u00d7</button>' +
      "</div>" +
      '<div class="rc-body"></div>';
    box.querySelector(".rc-close").addEventListener("click", closePanel);
    document.body.appendChild(box);
    return box;
  }

  function closePanel() {
    const box = document.getElementById(PANEL_ID);
    if (box) box.removeAttribute("data-open");
  }

  function showPanel(html, footHtml) {
    const box = panel();
    box.querySelector(".rc-body").innerHTML = html;

    const oldFoot = box.querySelector(".rc-foot");
    if (oldFoot) oldFoot.remove();
    if (footHtml) {
      const foot = document.createElement("div");
      foot.className = "rc-foot";
      foot.innerHTML = footHtml;
      box.appendChild(foot);
    }

    box.setAttribute("data-open", "1");
    return box;
  }

  // Esc closes, as in any dialog.
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") closePanel();
  });

  function escapeHtml(text) {
    const div = document.createElement("div");
    div.textContent = String(text == null ? "" : text);
    return div.innerHTML;
  }

  function status(kind, message) {
    showPanel('<p class="rc-msg rc-' + kind + '">' + escapeHtml(message) + "</p>");
  }

  /* Spinner plus skeleton lines: shows both that we are working and roughly
     what is about to appear. */
  function working(message) {
    showPanel(
      '<div class="rc-working"><span class="rc-spin"></span>' +
      '<span class="rc-working-text">' + escapeHtml(message) + "</span></div>" +
      '<div class="rc-skel" style="width:88%"></div>' +
      '<div class="rc-skel" style="width:74%"></div>' +
      '<div class="rc-skel" style="width:93%"></div>' +
      '<div class="rc-skel" style="width:61%"></div>'
    );
  }

  /* ---------- the flow ---------- */

  /* Extra instructions the RC member types before drafting. Kept per page so
     a redraft after an unsatisfying answer starts from what they already
     wrote. */
  let extraInstructions = "";

  function gatherTicket() {
    const ticketNumber = readValue(findField("ticket_number"));
    const short = readValue(findField("short_description"));
    const description = readValue(findField("description"));
    const activity = readActivity();

    if (!short && !description) return null;

    return {
      number: ticketNumber,
      text: [
        ticketNumber ? "Ticket: " + ticketNumber : "",
        short ? "Short description: " + short : "",
        description ? "Description:\n" + description : "",
        activity ? "Work notes / activity:\n" + activity : ""
      ].filter(Boolean).join("\n\n")
    };
  }

  /* Step 1: show what was read and let them add context the ticket lacks. */
  function compose(button) {
    const ticket = gatherTicket();

    if (!ticket) {
      // Name the UI and the path: that pair is what's needed to widen the
      // selectors if this page uses different markup.
      status(
        "warn",
        "Couldn't find ticket fields here. Detected UI: " + detectUi() +
          ". Path: " + location.pathname +
          ". Open an actual ticket form and try again — if it still fails, " +
          "report this UI and path."
      );
      return;
    }

    const bits = [];
    if (ticket.number) bits.push(escapeHtml(ticket.number));
    bits.push(ticket.text.length.toLocaleString() + " characters read");

    const html =
      '<p class="rc-msg rc-info"><span>' + bits.join(" · ") + "</span></p>" +
      '<p class="rc-h">Anything the model should know?</p>' +
      '<textarea class="rc-notes" rows="4" placeholder="Optional. e.g. they already tried reinstalling; keep it short and link the docs; this is a repeat of INC123."></textarea>' +
      '<p class="rc-meta">Sent with the ticket. Leave blank to draft from the ticket alone.</p>';

    const foot =
      '<button type="button" class="rc-btn rc-btn-primary rc-go">Draft reply</button>' +
      '<button type="button" class="rc-btn rc-btn-ghost rc-cancel">Cancel</button>';

    const box = showPanel(html, foot);
    const notes = box.querySelector(".rc-notes");
    notes.value = extraInstructions;
    notes.focus();

    const go = function () {
      extraInstructions = notes.value.trim();
      draftNow(button, ticket, extraInstructions);
    };

    box.querySelector(".rc-go").addEventListener("click", go);
    box.querySelector(".rc-cancel").addEventListener("click", closePanel);
    // Ctrl/Cmd+Enter submits, so the common "nothing to add" case is one key.
    notes.addEventListener("keydown", function (e) {
      if ((e.ctrlKey || e.metaKey) && e.key === "Enter") { e.preventDefault(); go(); }
    });
  }

  /* Step 2: send it. */
  async function draftNow(button, ticket, instructions) {
    const labelEl = button.querySelector(".rc-fab-label") || button;
    const label = labelEl.textContent;
    const ticketNumber = ticket.number;
    const ticketText = ticket.text;

    button.disabled = true;
    labelEl.textContent = "Drafting…";
    working("Drafting a reply. This can take a minute on a busy cluster.");

    let reply;
    try {
      reply = await chrome.runtime.sendMessage({
        type: "DRAFT",
        ticketText: ticketText,
        ticketNumber: ticketNumber,
        extraInstructions: instructions || ""
      });
    } catch (err) {
      reply = { ok: false, error: "Extension was reloaded — refresh this page." };
    }

    button.disabled = false;
    labelEl.textContent = label;

    if (!reply || !reply.ok) {
      status("error", (reply && reply.error) || "Unknown error.");
      return;
    }

    const data = reply.data || {};
    const cfgReply = await chrome.runtime.sendMessage({ type: "GET_CONFIG" });
    const targetKey = (cfgReply && cfgReply.data && cfgReply.data.targetField) || "work_notes";

    const target = findField(targetKey);
    let wrote = false;
    if (target && !target.readOnly && data.draft_response) {
      wrote = setFieldValue(target, data.draft_response);
    }

    /* Caveats are the "check before sending" list. They must NOT go into the
       ticket, but they must not be silently dropped either. */
    const caveats = Array.isArray(data.caveats) ? data.caveats : [];
    const confidence = typeof data.confidence === "number" ? data.confidence : null;
    const level = data.confidence_label || "unknown";

    const pct = confidence === null ? null : Math.round(confidence * 100);

    let html = "";

    // Confidence first: it decides how much of the rest you should trust.
    html +=
      '<div class="rc-conf rc-' + escapeHtml(level) + '">' +
        '<div class="rc-conf-top">' +
          '<span class="rc-conf-label">Confidence</span>' +
          '<span class="rc-conf-val">' + escapeHtml(level) +
            (pct === null ? "" : " · " + pct + "%") +
          "</span>" +
        "</div>" +
        '<div class="rc-meter"><i style="width:' + (pct === null ? 0 : pct) + '%"></i></div>' +
      "</div>";

    html += wrote
      ? '<p class="rc-msg rc-ok"><span>Written into <b>' +
        escapeHtml(targetKey.replace("_", " ")) +
        "</b> — not saved. Review, edit, then Update.</span></p>"
      : '<p class="rc-msg rc-warn"><span>No writable ' +
        escapeHtml(targetKey.replace("_", " ")) +
        " field here, so the draft is below instead.</span></p>";

    if (instructions) {
      html += '<p class="rc-h">Your instructions</p>';
      html += '<p class="rc-summary rc-yours">' + escapeHtml(instructions) + "</p>";
    }

    if (data.problem_summary) {
      html += '<p class="rc-h">Summary</p>';
      html += '<p class="rc-summary">' + escapeHtml(data.problem_summary) + "</p>";
    }

    if (caveats.length) {
      html += '<p class="rc-h">Check before sending</p><ul class="rc-list">';
      for (const c of caveats) html += "<li>" + escapeHtml(c) + "</li>";
      html += "</ul>";
    }

    html += '<p class="rc-h">Draft</p>';
    html += '<textarea class="rc-draft" spellcheck="true">' +
            escapeHtml(data.draft_response || "") + "</textarea>";

    const meta = [];
    if (data.model) meta.push(escapeHtml(data.model));
    if (typeof data.latency_ms === "number") meta.push((data.latency_ms / 1000).toFixed(1) + "s");
    if (meta.length) html += '<p class="rc-meta">' + meta.join(" · ") + "</p>";

    const foot =
      '<button type="button" class="rc-btn rc-btn-primary rc-copy">Copy</button>' +
      '<button type="button" class="rc-btn rc-btn-ghost rc-insert">Insert</button>' +
      '<button type="button" class="rc-btn rc-btn-ghost rc-redraft">Redraft</button>';

    const box = showPanel(html, foot);
    const area = box.querySelector(".rc-draft");

    box.querySelector(".rc-copy").addEventListener("click", function () {
      const btn = this;
      const done = function () {
        btn.textContent = "Copied ✓";
        btn.classList.add("rc-btn-done");
        setTimeout(function () {
          btn.textContent = "Copy";
          btn.classList.remove("rc-btn-done");
        }, 1600);
      };
      navigator.clipboard.writeText(area.value).then(done, function () {
        area.select();
        try { document.execCommand("copy"); done(); } catch (e) { /* selected; Ctrl+C */ }
      });
    });

    // Lets you edit in the panel and push the edited version into the ticket.
    box.querySelector(".rc-redraft").addEventListener("click", function () {
      compose(button);
    });

    box.querySelector(".rc-insert").addEventListener("click", function () {
      const btn = this;
      const node = findField(targetKey);
      if (node && !node.readOnly && setFieldValue(node, area.value)) {
        btn.textContent = "Inserted ✓";
        btn.classList.add("rc-btn-done");
        setTimeout(function () {
          btn.textContent = "Insert again";
          btn.classList.remove("rc-btn-done");
        }, 1600);
      } else {
        btn.textContent = "No field found";
        setTimeout(function () { btn.textContent = "Insert again"; }, 1600);
      }
    });
  }

  function injectButton() {
    if (document.getElementById(BUTTON_ID)) return;
    // Only in the frame that actually holds the form — with all_frames:true we
    // also run in nav and shell frames, which have no ticket fields.
    if (!findField("short_description") && !findField("description")) return;

    const button = document.createElement("button");
    button.id = BUTTON_ID;
    button.type = "button";
    button.className = "rc-fab";
    button.innerHTML = '<span class="rc-ico" aria-hidden="true"></span><span class="rc-fab-label">Draft reply</span>';
    button.title = "Read this ticket, draft a reply with RC Copilot, and fill the work notes";
    button.addEventListener("click", () => compose(button));
    document.body.appendChild(button);
  }

  injectButton();

  /* ServiceNow swaps forms in without a page load. */
  let pending = null;
  const observer = new MutationObserver(function () {
    clearTimeout(pending);
    pending = setTimeout(injectButton, 400);
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
})();
