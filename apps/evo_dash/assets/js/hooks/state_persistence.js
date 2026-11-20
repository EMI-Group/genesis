// StatePersistence hook: keeps the task form's draft with its node and project scope.
//
// A scope is {node, token}: the viewed node plus the selected project's VCT point
// (`data-task-draft-scope`, e.g. `vct:///projects/foo`) when the server knows one,
// else the raw OS path (`data-task-draft-project`), so a path-only project keeps
// the exact legacy key. Server side: `EvoDashWeb.DraftScope` is the ONE place the
// token and the key shape are defined.
const StatePersistence = {
  mounted() {
    this.restore();

    this.handleEvent("persist_state", state => {
      const scope = this.scope();
      if (!this.matches(state, scope)) return;
      const prompt = this.el.querySelector('[name="prompt"]');
      if (scope.project && !prompt) return;

      // The ignored textarea owns the current prompt, including unsaved typing.
      this.flush();
      this.write(scope.key, this.stamp({...state, task_prompt: prompt?.value || ''}, scope));
    });

    this.handleEvent("persist_model_selection", ({node, project, model_spec}) => {
      const scope = this.scope();
      if (!this.matches({node, project}, scope)) return;
      const existing = this.read(scope.key);
      if (existing && !this.matches(existing, scope)) return;

      this.write(scope.key, this.stamp({
        ...(existing || this.saved(scope)), node, model_spec,
        ...(scope.project ? {project: scope.project} : {})
      }, scope));
    });

    this.handleEvent("clear_prompt", () => {
      const scope = this.scope();
      this.flush();
      this.write(scope.key, this.stamp({...this.saved(scope), node: scope.node, task_prompt: '',
        ...(scope.project ? {project: scope.project} : {})}, scope));
    });

    this._onFormChange = event => {
      const name = event.target.getAttribute('name');
      if (!['prompt', 'node_path', 'seeds', 'starting_commit', 'model_id'].includes(name)) return;

      const scope = this.scope();
      const legacyModel = this.el.querySelector('[name="model_id"]');
      this.pending = {
        scope,
        fields: {
          project: scope.project || this.el.dataset.project || '',
          task_mode: this.el.dataset.taskMode || '',
          node: scope.node,
          task_prompt: this.el.querySelector('[name="prompt"]')?.value || '',
          task_node_path: this.el.querySelector('[name="node_path"]')?.value || '',
          task_seeds: this.el.querySelector('[name="seeds"]')?.value || '',
          task_starting_commit: this.el.querySelector('[name="starting_commit"]')?.value || '',
          ...(legacyModel ? {selected_model_id: legacyModel.value} : {})
        }
      };
      clearTimeout(this.saveTimer);
      this.saveTimer = setTimeout(() => this.flush(), 300);
    };

    this.el.addEventListener('input', this._onFormChange);
    this.el.addEventListener('change', this._onFormChange);
  },

  updated() {
    this.restore();
  },

  destroyed() {
    // Release the form listeners and the pending debounce before the final
    // flush, so a late timer can never write through a destroyed hook.
    if (this._onFormChange) {
      this.el.removeEventListener('input', this._onFormChange);
      this.el.removeEventListener('change', this._onFormChange);
      this._onFormChange = null;
    }
    clearTimeout(this.saveTimer);
    this.saveTimer = null;
    this.flush();
  },

  // A path-only project is its own token: same key shape as before this hook
  // learned about VCT points, so its drafts need no migration.
  scope() {
    const node = this.el.dataset.nodeId || 'local';
    const project = this.el.dataset.taskDraftProject || '';
    const token = this.el.dataset.taskDraftScope || project;
    const key = token ? 'dashboard_state:' + JSON.stringify([node, token]) : 'dashboard_state';
    // The path-keyed entry the same project used before it had a VCT point.
    const legacyKey = (token && project && token !== project) ?
      'dashboard_state:' + JSON.stringify([node, project]) : null;
    return {node, project, token, key, legacyKey};
  },

  // A scope_token equal to the state's own project path carries no VCT identity
  // (it was stamped before the server knew the point), so it falls back to the
  // path match; a real point/workspace stamp must still match exactly. An
  // unstamped legacy state falls back to its project path too.
  matches(state, scope) {
    if ((state.node || 'local') !== scope.node) return false;
    if (!scope.token) return true;
    const stamped = typeof state.scope_token === 'string' && state.scope_token !== state.project;
    return stamped ?
      state.scope_token === scope.token :
      Boolean(scope.project) && state.project === scope.project;
  },

  read(key) {
    try {
      const state = JSON.parse(sessionStorage.getItem(key));
      return state && typeof state === 'object' && !Array.isArray(state) ? state : null;
    } catch {
      return null;
    }
  },

  write(key, state) {
    sessionStorage.setItem(key, JSON.stringify(state));
  },

  // Every write records the scope it belongs to, so a later restore can tell a
  // VCT-scoped draft from a legacy path-keyed one.
  stamp(state, scope) {
    return scope.token ? {...state, scope_token: scope.token} : state;
  },

  // Adoption order: the scoped key, the path key this project used before its VCT
  // point was known, then the un-scoped legacy key.
  saved(scope) {
    for (const key of [scope.key, scope.legacyKey, 'dashboard_state']) {
      if (!key) continue;
      const state = this.read(key);
      if (state && this.matches(state, scope)) return state;
    }
    return null;
  },

  restore() {
    const scope = this.scope();
    const prompt = this.el.querySelector('[name="prompt"]');
    if (scope.project && !prompt) return;

    const restoreKey = JSON.stringify([scope.node, scope.key]);
    if (restoreKey === this.restoreKey) return;
    const previous = this.restoreKey;
    const identity = JSON.stringify([scope.node, scope.project]);
    const sameIdentity = identity === this.restoreIdentity;
    // Flush the pending edit under the scope it was typed in BEFORE switching keys,
    // so a VCT point arriving after the first keystroke never drops the draft.
    this.flush();
    this.restoreKey = restoreKey;
    this.restoreIdentity = identity;

    const state = this.saved(scope);
    if (state) this.pushEvent("restore_state", state);
    if (!prompt) return;
    // On an in-place scope change, the ignored textarea may still contain the old
    // draft: adopt what was saved, else clear it only when the node or project
    // actually changed (the same project gaining its token keeps the typing).
    if (state && typeof state.task_prompt === 'string') prompt.value = state.task_prompt;
    else if (previous && !sameIdentity) prompt.value = '';
  },

  flush() {
    if (!this.pending) return;
    const {scope, fields} = this.pending;
    clearTimeout(this.saveTimer);
    this.pending = null;
    this.write(scope.key, this.stamp({...this.saved(scope), ...fields}, scope));
  }
};

export default StatePersistence;
