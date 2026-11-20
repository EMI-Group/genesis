// SidebarCollapse hook: manages desktop sidebar collapse state with
// cross-session localStorage persistence, AND mobile sidebar open/close
// (hamburger toggle). The updated() callback is essential — LiveView
// morphdom patches reset server-rendered sidebar classes after every
// navigation, so we must re-apply on every update.
//
// PERFORMANCE: `#sidebar` also carries the Active Tasks list (potentially
// hundreds of rows), so the collapse sweep MUST NOT run on every patch. The
// sweep (`applyCollapsed`) is a set of full-subtree `querySelectorAll` walks
// plus per-element class writes; running it on each patch of the sidebar
// subtree made every task-list update re-walk the whole sidebar.
//
// `updated()` therefore PROBES first (see the pure block below): a handful of
// `querySelector` / `classList.contains` checks decide whether morphdom
// actually reset the markup, and the sweep only runs when it did. The probe
// state `appliedCollapsed` records what was last applied, so a stable sidebar
// costs a few lookups per patch instead of a document walk.

// --- SidebarCollapse: pure collapse-sync probe ------------------------------
// Decides whether the collapse sweep has to re-run after a LiveView patch.
// `state` is `{el, appliedCollapsed, collapseToggle}`; every probe is one
// `querySelector`/`classList.contains` (no `querySelectorAll`, no per-element
// writes), and a MISSING probe element counts as "fine" — no markup, nothing
// the sweep could fix.
//
// Why one probe per class family is enough: the swept classes are all rendered
// by the same server template, so a morphdom reset shows up on whichever
// element of that family is probed. The label and task-link families are
// probed with a `:not(...)` selector instead of "the first element", because
// they also live inside DYNAMIC lists (the Active Tasks rows): re-rendering
// that list resets the rows without touching the static brand label, so only
// "is ANY label/row still in the wrong state" is a sufficient signal.
function collapseSyncNeeded(state, collapsed) {
  const el = state && state.el;
  if (!el || !el.classList) return false;

  // 1. The state we last applied — undefined on the very first run (mount).
  if (state.appliedCollapsed !== collapsed) return true;

  // 2. The state attribute the server renders ("false").
  if (el.dataset && el.dataset.sidebarCollapsed !== String(collapsed)) return true;

  // 3. The sidebar width class pair.
  if (!el.classList.contains(collapsed ? 'w-16' : 'w-60')) return true;

  // 4. Labels: collapsed → every `.sidebar-label` carries `hidden`.
  if (collapsed) {
    if (el.querySelector('.sidebar-label:not(.hidden)')) return true;
  } else if (el.querySelector('.sidebar-label.hidden')) {
    return true;
  }

  // 5. Compact (collapsed-only) markers: collapsed → visible (no `hidden`).
  const compact = el.querySelector('.sidebar-collapsed-only');
  if (compact && compact.classList.contains('hidden') === collapsed) return true;

  // 6. Active-task rows: collapsed → centered (`justify-center`, no `px-3`).
  if (collapsed) {
    if (el.querySelector('[data-sidebar-task-link]:not(.justify-center)')) return true;
  } else if (el.querySelector('[data-sidebar-task-link].justify-center')) {
    return true;
  }

  // 7. The collapse toggle's icon variant.
  const toggle = state.collapseToggle;
  if (toggle && toggle.querySelector) {
    const icon = toggle.querySelector(
      collapsed ? '.hero-chevron-double-right' : '.hero-chevron-double-left'
    );
    if (!icon) return true;
  }

  return false;
}
// SidebarCollapse hook:

const SidebarCollapse = {
  mounted() {
    this.mobileOpen = false;
    // The collapse state actually applied to the DOM (see `applyCollapsed`).
    this.appliedCollapsed = undefined;
    this.mobileViewport = window.matchMedia('(max-width: 1023.98px)');
    this.layout = this.el.closest('#app-layout');
    this.main = this.layout.querySelector('.workbench-main');

    // --- Desktop collapse state ---
    this.collapseToggle = document.getElementById('sidebar-collapse-toggle');
    if (this.collapseToggle) {
      this._clickHandler = () => {
        const next = !this.isCollapsed();
        localStorage.setItem('sidebar-collapsed', String(next));
        this.applyCollapsed(next);
      };
      this.collapseToggle.addEventListener('click', this._clickHandler);
    }

    // --- Mobile sidebar: hamburger open + overlay close ---
    this.mobileToggle = document.getElementById('sidebar-mobile-toggle');
    this.overlay = document.getElementById('sidebar-overlay');

    if (this.mobileToggle) {
      this._mobileToggleHandler = () => {
        if (!this.isMobile()) return;
        if (this.mobileOpen) this.closeMobile();
        else this.openMobile();
      };
      this.mobileToggle.addEventListener('click', this._mobileToggleHandler);
    }

    if (this.overlay) {
      this._overlayHandler = () => {
        if (!this.isMobile()) return;
        this.closeMobile(true);
      };
      this.overlay.addEventListener('click', this._overlayHandler);
    }

    // Close mobile sidebar when any nav link inside it is clicked.
    // Event delegation on the sidebar element survives LiveView morphdom
    // re-renders (no need to re-attach per-link listeners in updated()).
    this._sidebarNavHandler = (e) => {
      if (!this.mobileOpen || !this.isMobile()) return;
      if (e.target.closest('#sidebar-mobile-close')) this.closeMobile(true);
      else if (e.target.closest('a')) this.closeMobile();
    };
    this.el.addEventListener('click', this._sidebarNavHandler);

    // --- Outside-click dismissal of open <details> dropdowns ---
    // The sidebar dropdowns (theme, language, node selector) are native
    // <details> elements, which only toggle on their own <summary>. A
    // document-level listener closes open menus in the bottom bar
    // when the click lands outside them — anywhere else on the page,
    // other sidebar chrome (nav links, collapse toggle), or another dropdown
    // (opening one dismisses the rest). Clicks inside an open dropdown's
    // content are left alone so they register before anything closes.
    this._documentClickHandler = (e) => {
      const target = e.target;
      if (this.el.contains(target)) {
        this.el.querySelectorAll('[data-sidebar-bottom-bar] details[open]').forEach((d) => {
          if (!d.contains(target)) d.removeAttribute('open');
        });
      } else {
        this.closeOpenDropdowns();
      }
    };
    document.addEventListener('click', this._documentClickHandler);

    this._escapeHandler = (event) => {
      if (event.key !== 'Escape' || event.defaultPrevented || !this.mobileOpen ||
          document.querySelector('dialog[open]')) return;
      event.preventDefault();
      this.closeMobile(true);
    };
    this._viewportHandler = () => {
      if (this.mobileOpen && !this.isMobile()) this.closeMobile();
      this.updated();
    };
    this._historyDrawerHandler = () => this.syncNavigationAccess();
    document.addEventListener('keydown', this._escapeHandler);
    this.mobileViewport.addEventListener('change', this._viewportHandler);
    this.layout.addEventListener('workbench:history-drawer', this._historyDrawerHandler);
    // The first sync: `appliedCollapsed` is still undefined, so the probe
    // reports "dirty" and the initial server markup gets the persisted state.
    this.updated();
  },

  updated() {
    const collapsed = !this.isMobile() && this.isCollapsed();
    // Cheap probe FIRST: the sidebar sweep is O(sidebar subtree) and the
    // sidebar carries the Active Tasks list, so it only re-runs when morphdom
    // actually reset the server-rendered markup.
    if (this.needsCollapseSync(collapsed)) this.applyCollapsed(collapsed);
    // Re-apply mobile open/close state — morphdom resets the sidebar's
    // translate classes after every LiveView navigation patch. This is a
    // constant number of classList/inert writes, so it stays unconditional
    // and intentionally OUTSIDE the collapse sweep.
    this.applyMobileState();
  },

  destroyed() {
    if (this.collapseToggle && this._clickHandler)
      this.collapseToggle.removeEventListener('click', this._clickHandler);
    if (this.mobileToggle && this._mobileToggleHandler)
      this.mobileToggle.removeEventListener('click', this._mobileToggleHandler);
    if (this.overlay && this._overlayHandler)
      this.overlay.removeEventListener('click', this._overlayHandler);
    document.removeEventListener('click', this._documentClickHandler);
    document.removeEventListener('keydown', this._escapeHandler);
    this.mobileViewport.removeEventListener('change', this._viewportHandler);
    this.layout.removeEventListener('workbench:history-drawer', this._historyDrawerHandler);
    if (this.mobileOpen) document.body.classList.remove('overflow-hidden');
    this.el.removeEventListener('click', this._sidebarNavHandler);
  },

  // Pure probe (see the block above): does the collapse sweep have to re-run?
  needsCollapseSync(collapsed) {
    return collapseSyncNeeded(this, collapsed);
  },

  isCollapsed() {
    return localStorage.getItem('sidebar-collapsed') === 'true';
  },

  isMobile() {
    return this.mobileViewport.matches;
  },

  openMobile() {
    this.mobileOpen = true;
    this.applyMobileState();
    document.body.classList.add('overflow-hidden');
    this.el.querySelector('#sidebar-mobile-close')?.focus();
  },

  closeMobile(restoreFocus = false) {
    this.mobileOpen = false;
    this.applyMobileState();
    document.body.classList.remove('overflow-hidden');
    if (restoreFocus) this.mobileToggle?.focus();
  },

  applyMobileState() {
    const open = this.isMobile() && this.mobileOpen;
    this.el.classList.toggle('-translate-x-full', !open);
    this.overlay?.classList.toggle('opacity-0', !open);
    this.overlay?.classList.toggle('pointer-events-none', !open);
    this.mobileToggle?.setAttribute('aria-expanded', String(open));
    this.main.inert = open;
    this.syncNavigationAccess();
  },

  syncNavigationAccess() {
    const historyOpen = this.layout.hasAttribute('data-workbench-history-drawer-open');
    this.el.inert = historyOpen || (this.isMobile() && !this.mobileOpen);
    if (this.mobileToggle) this.mobileToggle.inert = historyOpen || this.mobileOpen;
  },

  // Closes every open <details> dropdown inside the sidebar (theme, language,
  // node selector) by removing the open attribute — DaisyUI's close mechanism.
  // Scoped to this.el so dropdowns elsewhere on the page are never touched.
  closeOpenDropdowns() {
    this.el.querySelectorAll('[data-sidebar-bottom-bar] details[open]').forEach((d) => d.removeAttribute('open'));
  },

  // Swaps the collapse toggle's chevron in place: the EXISTING icon element
  // gets its hero class replaced instead of rewriting the toggle's innerHTML
  // (an innerHTML write re-parses the markup and recreates the <svg> node on
  // every patch). Idempotent — when the wanted variant is already there, the
  // opposite lookup misses and nothing is written. Missing/unknown icon markup
  // is left alone (never throws).
  swapCollapseIcon(collapsed) {
    if (!this.collapseToggle) return;
    const from = collapsed ? 'hero-chevron-double-left' : 'hero-chevron-double-right';
    const to = collapsed ? 'hero-chevron-double-right' : 'hero-chevron-double-left';
    const target = this.collapseToggle.classList.contains(from)
      ? this.collapseToggle
      : this.collapseToggle.querySelector('.' + from);
    if (!target) return;
    target.classList.replace(from, to);
  },

  applyCollapsed(collapsed) {
    const sidebar = this.el;
    sidebar.dataset.sidebarCollapsed = String(collapsed);
    // Stable selectors using data attributes — work in both collapsed and expanded states
    const bottomBar = sidebar.querySelector('[data-sidebar-bottom-bar]');
    const bottomGroups = sidebar.querySelectorAll('[data-sidebar-bottom-group]');
    const taskLinks = sidebar.querySelectorAll('[data-sidebar-task-link]');
    
    if (collapsed) {
      // Collapsing to the 64px sidebar hides the dropdown summaries' context;
      // close any open dropdown so its floating panel is not left detached.
      this.closeOpenDropdowns();
      sidebar.classList.add('w-16');
      sidebar.classList.remove('w-60');
      // Allow dropdown menus to extend beyond the collapsed 64px sidebar
      sidebar.classList.add('overflow-visible');
      sidebar.classList.remove('overflow-hidden');
      // Hide all sidebar-labels (text spans that should collapse)
      sidebar.querySelectorAll('.sidebar-label').forEach(el => el.classList.add('hidden'));
      // Show collapsed-only elements (compact task indicators)
      sidebar.querySelectorAll('.sidebar-collapsed-only').forEach(el => el.classList.remove('hidden'));
      // Center the lone status dot in each task row within the 64px sidebar
      taskLinks.forEach(el => {
        el.classList.add('justify-center');
        el.classList.remove('px-3');
      });
      // Stack bottom bar vertically so all buttons are visible in 64px
      if (bottomBar) {
        bottomBar.classList.remove('flex', 'items-center', 'justify-between');
        bottomBar.classList.add('flex-col', 'items-center');
        bottomGroups.forEach(g => {
          g.classList.remove('flex', 'items-center', 'gap-1');
          g.classList.add('flex-col', 'items-center');
        });
      }
      // Icon swap: chevron-double-left → chevron-double-right
      this.swapCollapseIcon(true);
      if (this.collapseToggle) {
        this.collapseToggle.title = 'Expand sidebar';
        this.collapseToggle.classList.remove('hidden'); // ensure visible
      }
    } else {
      sidebar.classList.remove('w-16');
      sidebar.classList.add('w-60');
      // Keep overflow-visible so dropdown menus (SSH node selector w-72,
      // language, theme) are never clipped at the expanded sidebar's w-60
      // edge — same as the collapsed branch.
      sidebar.classList.add('overflow-visible');
      sidebar.classList.remove('overflow-hidden');
      // Show all sidebar-labels
      sidebar.querySelectorAll('.sidebar-label').forEach(el => el.classList.remove('hidden'));
      // Hide collapsed-only elements
      sidebar.querySelectorAll('.sidebar-collapsed-only').forEach(el => el.classList.add('hidden'));
      // Restore left-aligned content in task rows
      taskLinks.forEach(el => {
        el.classList.remove('justify-center');
        el.classList.add('px-3');
      });
      // Restore horizontal flex layout
      if (bottomBar) {
        bottomBar.classList.add('flex', 'items-center', 'justify-between');
        bottomBar.classList.remove('flex-col');
        bottomGroups.forEach(g => {
          g.classList.add('flex', 'items-center', 'gap-1');
          g.classList.remove('flex-col');
        });
      }
      // Icon swap: chevron-double-right → chevron-double-left
      this.swapCollapseIcon(false);
      if (this.collapseToggle) {
        this.collapseToggle.title = 'Collapse sidebar';
      }
    }

    // Record what the DOM now reflects — the probe's first check.
    this.appliedCollapsed = collapsed;
  }
};

export default SidebarCollapse;
