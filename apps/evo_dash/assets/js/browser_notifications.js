// Advisory document notifications only: an approval click opens review, never
// authorizes a decision. See CONTEXT.md for the gettext-fed host contract.
const BrowserNotifications = {
  mounted() {
    this._notifications = new Map();
    this._alive = true;
    this._requesting = false;
    this._scope = this._approvalScope();
    this._onFocus = () => this._refresh();
    this._onVisibility = () => this._refresh();
    this._onEnable = event => {
      const button = event.target.closest?.("[data-enable-notifications]");
      if (!button || !this.el.contains(button)) return;
      event.preventDefault();
      this._enable();
    };
    window.addEventListener("focus", this._onFocus);
    document.addEventListener("visibilitychange", this._onVisibility);
    this.el.addEventListener("click", this._onEnable);
    this._eventRef = this.handleEvent("task_notification", payload => this._notify(payload));
    this._refresh();
  },

  updated() { this._refresh(); },
  reconnected() { this._refresh(); },
  disconnected() { this._closeAll(); },

  destroyed() {
    this._alive = false;
    window.removeEventListener("focus", this._onFocus);
    document.removeEventListener("visibilitychange", this._onVisibility);
    this.el.removeEventListener("click", this._onEnable);
    this.removeHandleEvent(this._eventRef);
    this._closeAll();
  },

  _approvalScope() {
    const scope = this.el.dataset.approvalScope;
    return typeof scope === "string" && scope.trim() ? scope : null;
  },

  _pendingIds() {
    try {
      const ids = JSON.parse(this.el.dataset.approvalRequestIds);
      return Array.isArray(ids) && ids.every(id => typeof id === "string" && id.trim())
        ? new Set(ids) : new Set();
    } catch (_) {
      // Missing/malformed host metadata is not authority to open an approval.
      return new Set();
    }
  },

  _currentApproval(requestId, scope) {
    return scope !== null && scope === this._approvalScope() && this._pendingIds().has(requestId);
  },

  _refresh() {
    if (!this._alive) return;
    const scope = this._approvalScope();
    if (scope !== this._scope) this._closeAll();
    this._scope = scope;
    for (const [notification, info] of this._notifications) {
      if (info.requestId && !this._currentApproval(info.requestId, info.scope)) {
        this._close(notification);
      }
    }
    this._failed = false;
    this._renderStatus();
  },

  _permission() {
    return typeof Notification === "function" ? Notification.permission : "unsupported";
  },

  _renderStatus() {
    const permission = this._permission();
    const canRequest = permission === "default" && typeof Notification.requestPermission === "function";
    const status = this._requesting ? "requesting"
      : this._failed ? "error"
      : permission === "default" && !canRequest ? "unsupported"
      : ["granted", "denied", "default"].includes(permission) ? permission : "unsupported";
    this.el.dataset.notificationStatus = status;
    const label = this.el.getAttribute(`data-notification-label-${status}`) || "";
    for (const node of this.el.querySelectorAll("[data-notification-status]")) node.textContent = label;
    for (const button of this.el.querySelectorAll("[data-enable-notifications]")) {
      button.disabled = !canRequest || this._requesting;
      button.hidden = !canRequest;
    }
  },

  async _enable() {
    if (!this._alive || this._requesting || this._permission() !== "default") return;
    if (typeof Notification.requestPermission !== "function") return this._renderStatus();
    this._requesting = true;
    this._failed = false;
    this._renderStatus();
    try {
      // Called directly from the delegated user gesture, never on mount/update.
      await Notification.requestPermission();
    } catch (_) {
      // A refused/unavailable browser prompt is recoverable; retain in-app review.
      this._failed = true;
    } finally {
      this._requesting = false;
      if (this._alive) this._renderStatus();
    }
  },

  _shouldNotify() {
    if (this._permission() !== "granted") return false;
    const hidden = typeof document.hidden === "boolean"
      ? document.hidden : document.visibilityState === "hidden";
    return hidden || (typeof document.hasFocus === "function" && !document.hasFocus());
  },

  _notify(payload) {
    if (!this._alive) return;
    this._refresh();
    if (!this._shouldNotify() || !payload || typeof payload.title !== "string" || !payload.title.trim()) return;
    const {title, body, tag, request_id: requestId, scope} = payload;
    // A supplied approval identity must be valid NOW, not just on click.
    if (requestId !== undefined && (typeof requestId !== "string" || !requestId.trim() || !this._currentApproval(requestId, scope))) return;
    const options = {body: typeof body === "string" ? body : "", icon: "/favicon.ico"};
    if (typeof tag === "string" && tag) {
      options.tag = tag;
      options.renotify = true;
    }
    let notification;
    try {
      notification = new Notification(title, options);
    } catch (_) {
      // Some WebViews expose the API but refuse document notifications.
      this._failed = true;
      this._renderStatus();
      return;
    }
    for (const [previous, info] of this._notifications) {
      if ((requestId && info.requestId === requestId) || (options.tag && info.tag === options.tag)) this._close(previous);
    }
    this._notifications.set(notification, {requestId, scope, tag: options.tag});
    notification.onclose = () => this._forget(notification);
    notification.onerror = () => {
      if (!this._alive || !this._notifications.has(notification)) return;
      this._failed = true;
      this._renderStatus();
      this._close(notification);
    };
    notification.onclick = () => {
      if (!this._alive || !this._notifications.has(notification)) return;
      try { window.focus(); } catch (_) { /* Browser may refuse focus. */ }
      if (requestId && this._currentApproval(requestId, scope)) {
        this.pushEvent("review_approval_notification", {request_id: requestId, scope});
      }
      this._close(notification);
    };
  },

  _forget(notification) {
    notification.onclick = null;
    notification.onclose = null;
    notification.onerror = null;
    this._notifications.delete(notification);
  },

  _close(notification) {
    this._forget(notification);
    try { notification.close(); } catch (_) { /* Closing is best-effort in WebViews. */ }
  },

  _closeAll() {
    for (const notification of this._notifications.keys()) this._close(notification);
  }
};

export default BrowserNotifications;
