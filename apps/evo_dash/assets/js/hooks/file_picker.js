// FilePicker hook: attach a file to the objective editor (kind-aware dropdown)
//
// The attach "+" control is a daisyUI dropdown — a
// <details class="dropdown ..." phx-hook="FilePicker"> (a DIRECT child of the
// toolbar div .input-controls) wrapping the visual "+" <summary
// id="objective-file-button"> and a menu (dropdown-content) of exactly three
// attachable file KINDS, one <button type="button"> per kind (task_form_
// components.ex — NO phx-click on the items; this hook fully owns clicks via
// delegation):
//   data-picker-kind="text"  data-picker-id="objective_file"
//   data-picker-kind="image" data-picker-id="objective_file_image"
//   data-picker-kind="audio" data-picker-id="objective_file_audio"
//
// ONE hook instance lives on the <details>. Click delegation: clicks that are
// NOT on a [data-picker-kind] menu item (e.g. the summary) are ignored, so
// native details toggling opens/closes the menu without ever starting a pick;
// an item click closes the dropdown and pushes a "file_pick" event with the
// CURRENT textarea value:
//   {picker_id: <item id>, prompt: "...", kind: <item kind>}
// ProjectsLive (local node only) runs a native file dialog server-side
// (EvoDash.DirectoryPicker :file mode) and pushes the result back as
// "picker_result:<picker_id>"; mounted() registers ONE shared handler for
// every unique data-picker-id found among the menu items. Payloads:
//   text (success):
//     {prompt: "...", block: "...", attached: true, name: "..."} → `prompt`
//     is the full new objective (base prompt + attached-file Markdown block);
//     `block` is the appended Markdown block alone (used when the user typed
//     between click and result, so their typing is never clobbered). The hook
//     writes the textarea with append-not-clobber semantics (below).
//   image/audio (success):
//     {attached: true, name: "...", kind: "image"|"audio"} → NO prompt/block
//     keys — the server re-render of the staged-attachment chip row is the
//     feedback, so the hook only re-arms and never touches the textarea.
//   {cancelled: true}  → user dismissed the dialog — no-op
//   {unavailable: true} → dialog unavailable (remote node, picker disabled) —
//     reveals the manual path input (<div id="objective-file-manual"
//     class="file-manual">, a SIBLING of the details inside .input-controls,
//     task_form_components.ex); typing a path and pressing Enter (or the
//     confirm button) pushes "file_pick_manual" with the PENDING picker id +
//     kind captured at item-click time (_pendingPick = {picker_id, kind}):
//       {picker_id: <pending id>, path: "...", prompt: "...", kind: <pending kind>}
//     and the server replies with the SAME picker_result payloads (success →
//     close — for image/audio there is no textarea write, only close; error →
//     inline error + keep the panel open, _pendingPick retained so a retry
//     re-submits the same id/kind; unavailable/cancelled → close).
//   {error: true}      → server failed to read the file — console.warn, no-op
//
// Teardown: the manual panel is a SIBLING of the <details> this hook is
// mounted on, so it survives a details teardown. Every listener the hook
// registers — on this.el AND on the manual elements — is therefore kept on the
// instance and removed in destroyed(); otherwise a remount would stack a
// second set of closures over the surviving nodes and Enter/confirm would push
// "file_pick_manual" twice.
const FilePicker = {
  mounted() {
    this._basePrompt = null;
    this._picking = false;             // native dialog in flight (re-entrancy guard)
    this._manualSubmitted = false;     // manual path submission in flight
    this._pendingPick = null;          // {picker_id, kind} of the in-flight pick
    this._manualEl =
      this.el.closest(".input-controls")?.querySelector("#objective-file-manual");
    this._manualInput = this._manualEl?.querySelector(".file-manual-input");
    this._manualError = this._manualEl?.querySelector(".file-manual-error");
    this._resultRefs = [];

    // Click delegation: only [data-picker-kind] menu items start a pick;
    // summary/other clicks are ignored so native details toggling works.
    this._onClick = (event) => {
      if (this._manualEl && !this._manualEl.hidden) {
        // Manual input is open — never start a pick; just focus it.
        this._manualInput?.focus();
        return;
      }
      const item = event.target.closest("[data-picker-kind]");
      if (!item) return;               // summary — native toggle only, never a pick
      this.el.closest("details")?.removeAttribute("open"); // close the dropdown menu
      if (this._picking) return;       // re-entrancy guard, DirectoryPicker pattern
      const textarea = this.promptTextarea();
      if (!textarea) return;
      const pickerId = item.dataset.pickerId;
      const kind = item.dataset.pickerKind;
      this._pendingPick = {picker_id: pickerId, kind: kind};
      this._basePrompt = textarea.value;
      this._picking = true;
      this.pushEvent("file_pick", {
        picker_id: pickerId,
        prompt: this._basePrompt,
        kind: kind
      });
    };
    this.el.addEventListener("click", this._onClick);

    if (this._manualEl && this._manualInput) {
      this._onManualKeydown = (e) => {
        if (e.key === "Enter") {
          e.preventDefault();          // inside the task form — never submit it
          this.submitManual();
        } else if (e.key === "Escape") {
          e.preventDefault();
          this.closeManual();
        }
      };
      this._onManualConfirm = () => this.submitManual();
      this._onManualCancel = () => this.closeManual();
      this._manualInput.addEventListener("keydown", this._onManualKeydown);
      this._manualConfirmEl = this._manualEl.querySelector(".file-manual-confirm");
      this._manualCancelEl = this._manualEl.querySelector(".file-manual-cancel");
      this._manualConfirmEl?.addEventListener("click", this._onManualConfirm);
      this._manualCancelEl?.addEventListener("click", this._onManualCancel);
    }

    // ONE shared handler for EVERY picker id — register the same function once
    // per unique data-picker-id among this dropdown's menu items (single set
    // of handlers, single hook instance, no per-item hook instances).
    this._onResult = (payload) => {
      if (this._manualSubmitted) {
        // Result of a manual path submission — mirror the native semantics:
        // success closes the input (and writes the prompt below for text
        // results); error keeps the input open with an inline message — the
        // pending {picker_id, kind} is retained so a retry re-submits the
        // same id/kind; unavailable/cancelled close.
        this._manualSubmitted = false;
        if (payload.error) {
          this.showManualError(payload.reason || null);
          return;
        }
        if (!payload.attached) {
          this.closeManual();          // unavailable / cancelled
          return;
        }
        this.closeManual();            // success — fall through to the write
      } else {
        this._picking = false;         // dialog closed — re-arm the button
        if (payload.unavailable) {
          this.openManual();           // native picker unavailable — manual fallback
          return;
        }
        if (payload.cancelled) {
          this._pendingPick = null;    // flow ended — nothing to keep
          return;                      // not an error
        }
        if (payload.error) {
          this._pendingPick = null;
          console.warn("[FilePicker] Failed to attach the file");
          return;
        }
      }
      this._pendingPick = null;        // success — flow concluded
      // Image/audio success payloads carry NO prompt/block keys — the server's
      // staged-attachment chip-row re-render is the feedback, so there is
      // nothing to write; only text results drive the DOM write below.
      if (typeof payload.prompt !== "string") return;         // defensive
      const textarea = this.promptTextarea();
      if (!textarea) return;
      const block = typeof payload.block === "string" ? payload.block : "";
      if (textarea.value === this._basePrompt) {
        // Prompt unchanged since the click — apply the server-computed value.
        textarea.value = payload.prompt;
      } else if (block) {
        // User typed meanwhile — append ONLY the file block, never clobber.
        textarea.value = textarea.value + block;
      } else {
        return; // no block info and value changed — do not clobber
      }
      textarea.dispatchEvent(new Event("input", {bubbles: true}));
      textarea.dispatchEvent(new Event("change", {bubbles: true}));
    };

    const pickerIds = [...new Set(
      Array.from(this.el.querySelectorAll("[data-picker-kind]"))
        .map((item) => item.dataset.pickerId)
        .filter(Boolean)
    )];
    for (const id of pickerIds) {
      this._resultRefs.push(this.handleEvent("picker_result:" + id, this._onResult));
    }
  },

  destroyed() {
    // Release the DOM listeners on this.el ...
    if (this._onClick) {
      this.el.removeEventListener("click", this._onClick);
      this._onClick = null;
    }
    // ... and on the manual panel, which is a SIBLING node that outlives a
    // <details> teardown (a stale closure here would double-submit).
    if (this._manualInput && this._onManualKeydown) {
      this._manualInput.removeEventListener("keydown", this._onManualKeydown);
    }
    if (this._manualConfirmEl && this._onManualConfirm) {
      this._manualConfirmEl.removeEventListener("click", this._onManualConfirm);
    }
    if (this._manualCancelEl && this._onManualCancel) {
      this._manualCancelEl.removeEventListener("click", this._onManualCancel);
    }
    this._onManualKeydown = null;
    this._onManualConfirm = null;
    this._onManualCancel = null;

    for (const ref of this._resultRefs || []) {
      this.removeHandleEvent(ref);
    }
    this._resultRefs = [];
    this._onResult = null;
  },

  reconnected() {
    this._picking = false;             // server-side pick is gone after reconnect
    this._manualSubmitted = false;
    // _pendingPick is deliberately kept: the manual panel may still be open
    // (or a late picker_result may still arrive) with the user's pick intent
    // intact. It is overwritten by the next item click and cleared when a
    // flow ends (cancel/close/success).
  },

  promptTextarea() {
    // The task-form textarea; find within the enclosing form first.
    return this.el.closest("form")?.querySelector('textarea[name="prompt"]') ||
      document.querySelector('textarea[name="prompt"]');
  },

  // --- Manual path fallback (revealed when the native picker is unavailable) ---

  openManual() {
    if (!this._manualEl) return;
    this._manualEl.hidden = false;
    // Fresh open: no stale value, no stale error. The pop/slide expansion
    // animation (app.css @keyframes file-manual-expand) restarts whenever
    // the widget becomes visible again.
    if (this._manualInput) this._manualInput.value = "";
    this.clearManualError();
    this._manualInput?.focus();
    console.warn(
      "[FilePicker] Native picker unavailable — the path input next to the attach button remains editable for manual entry"
    );
  },

  submitManual() {
    if (this._manualSubmitted) return; // one submission in flight
    const textarea = this.promptTextarea();
    if (!textarea) return;
    const path = this._manualInput?.value ?? "";
    // Submit the PENDING pick captured at item-click time (picker id + kind).
    // The panel is only reachable after an unavailable native pick, which
    // always leaves _pendingPick set; fall back to the text picker if it is
    // somehow missing (reconnect edge) so the legacy manual flow still works.
    const pending = this._pendingPick || {picker_id: "objective_file", kind: "text"};
    this._basePrompt = textarea.value;
    this._manualSubmitted = true;
    this.clearManualError();
    this.pushEvent("file_pick_manual", {
      picker_id: pending.picker_id,
      path: path,
      prompt: this._basePrompt,
      kind: pending.kind
    });
  },

  closeManual() {
    if (!this._manualEl) return;
    this._manualEl.hidden = true;
    this.clearManualError();
    if (this._manualInput) this._manualInput.value = "";
    this._pendingPick = null;          // flow over — drop the pending pick
  },

  showManualError(reason) {
    if (!this._manualEl || !reason) return;
    if (this._manualError) {
      this._manualError.textContent = reason;
      this._manualError.hidden = false;
    }
    this._manualInput?.focus();
    this._manualInput?.select();
  },

  clearManualError() {
    if (this._manualError) {
      this._manualError.textContent = "";
      this._manualError.hidden = true;
    }
  }
};

export default FilePicker;
