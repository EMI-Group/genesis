// SidebarCollapse hook: manages desktop sidebar collapse state with
// cross-session localStorage persistence, AND mobile sidebar open/close
// (hamburger toggle). The updated() callback is essential — LiveView
// morphdom patches reset server-rendered sidebar classes after every
// navigation, so we must re-apply on every update.
const SidebarCollapse = {
  mounted() {
    this.mobileOpen = false;

    // --- Desktop collapse state ---
    this.applyCollapsed(this.isCollapsed());
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
        this.closeMobile();
      };
      this.overlay.addEventListener('click', this._overlayHandler);
    }

    // Close mobile sidebar when any nav link inside it is clicked.
    // Event delegation on the sidebar element survives LiveView morphdom
    // re-renders (no need to re-attach per-link listeners in updated()).
    this._sidebarNavHandler = (e) => {
      if (!this.mobileOpen || !this.isMobile()) return;
      if (e.target.closest('a')) this.closeMobile();
    };
    this.el.addEventListener('click', this._sidebarNavHandler);
  },

  updated() {
    this.applyCollapsed(this.isCollapsed());
    // Re-apply mobile open/close state — morphdom resets the sidebar's
    // translate classes after every LiveView navigation patch.
    this.applyMobileState(this.mobileOpen);
  },

  destroyed() {
    if (this.collapseToggle && this._clickHandler)
      this.collapseToggle.removeEventListener('click', this._clickHandler);
    if (this.mobileToggle && this._mobileToggleHandler)
      this.mobileToggle.removeEventListener('click', this._mobileToggleHandler);
    if (this.overlay && this._overlayHandler)
      this.overlay.removeEventListener('click', this._overlayHandler);
    this.el.removeEventListener('click', this._sidebarNavHandler);
  },

  isCollapsed() {
    return localStorage.getItem('sidebar-collapsed') === 'true';
  },

  isMobile() {
    return window.matchMedia('(max-width: 1023.98px)').matches;
  },

  openMobile() {
    this.mobileOpen = true;
    this.applyMobileState(true);
    document.body.classList.add('overflow-hidden');
  },

  closeMobile() {
    this.mobileOpen = false;
    this.applyMobileState(false);
    document.body.classList.remove('overflow-hidden');
  },

  // Toggles the mobile sidebar translate + overlay visibility classes.
  // On desktop these are harmless — lg:translate-x-0 and lg:hidden in the
  // server-rendered markup override them at the lg breakpoint.
  applyMobileState(open) {
    if (open) {
      this.el.classList.remove('-translate-x-full');
      if (this.overlay) {
        this.overlay.classList.remove('opacity-0', 'pointer-events-none');
      }
    } else {
      this.el.classList.add('-translate-x-full');
      if (this.overlay) {
        this.overlay.classList.add('opacity-0', 'pointer-events-none');
      }
    }
  },

  applyCollapsed(collapsed) {
    const sidebar = this.el;
    // Stable selectors using data attributes — work in both collapsed and expanded states
    const bottomBar = sidebar.querySelector('[data-sidebar-bottom-bar]');
    const bottomGroups = sidebar.querySelectorAll('[data-sidebar-bottom-group]');
    const taskLinks = sidebar.querySelectorAll('[data-sidebar-task-link]');
    
    if (collapsed) {
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
      if (this.collapseToggle) {
        this.collapseToggle.innerHTML = this.collapseToggle.innerHTML.replace(/hero-chevron-double-left/g, 'hero-chevron-double-right');
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
      if (this.collapseToggle) {
        this.collapseToggle.innerHTML = this.collapseToggle.innerHTML.replace(/hero-chevron-double-right/g, 'hero-chevron-double-left');
        this.collapseToggle.title = 'Collapse sidebar';
      }
    }
  }
};

export default SidebarCollapse;
