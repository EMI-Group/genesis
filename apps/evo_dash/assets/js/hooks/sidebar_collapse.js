// SidebarCollapse hook: manages desktop sidebar collapse state with
// cross-session localStorage persistence. The updated() callback is
// essential — LiveView morphdom patches reset server-rendered sidebar
// classes after every navigation, so we must re-apply on every update.
const SidebarCollapse = {
  mounted() {
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
  },

  updated() {
    this.applyCollapsed(this.isCollapsed());
  },

  destroyed() {
    if (this.collapseToggle && this._clickHandler) {
      this.collapseToggle.removeEventListener('click', this._clickHandler);
    }
  },

  isCollapsed() {
    return localStorage.getItem('sidebar-collapsed') === 'true';
  },

  applyCollapsed(collapsed) {
    const sidebar = this.el;
    const bottomBar = sidebar.querySelector('.flex.items-center.justify-between');
    
    if (collapsed) {
      sidebar.classList.add('w-16');
      sidebar.classList.remove('w-60');
      // Hide all sidebar-labels (text spans that should collapse)
      sidebar.querySelectorAll('.sidebar-label').forEach(el => el.classList.add('hidden'));
      // Stack bottom bar vertically so all buttons are visible in 64px
      if (bottomBar) {
        bottomBar.classList.remove('flex', 'items-center', 'justify-between');
        bottomBar.classList.add('flex-col', 'items-center');
        // Remove the gap-1 on the inner left group divs and make them flex-col too
        const groups = bottomBar.querySelectorAll('.flex.items-center.gap-1');
        groups.forEach(g => {
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
      // Show all sidebar-labels
      sidebar.querySelectorAll('.sidebar-label').forEach(el => el.classList.remove('hidden'));
      // Restore horizontal flex layout
      if (bottomBar) {
        bottomBar.classList.add('flex', 'items-center', 'justify-between');
        bottomBar.classList.remove('flex-col');
        const groups = bottomBar.querySelectorAll('.flex-col.items-center');
        groups.forEach(g => {
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
