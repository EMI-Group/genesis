// Preserve native disclosure state across LiveView patches without ignoring live contents.
export default {
  mounted() {
    this.transient = this.el.matches('.assistant-attach-menu, .assistant-task-control');
    this.close = () => { this.wasOpen = false; this.el.open = false; };
    this.onOutside = event => {
      if (this.el.open && !this.el.contains(event.target)) this.close();
    };
    this.onEscape = event => {
      if (event.key === 'Escape' && this.el.open) {
        this.close();
        this.el.querySelector(':scope > summary')?.focus({preventScroll: true});
      }
    };
    if (this.transient) {
      document.addEventListener('pointerdown', this.onOutside, true);
      document.addEventListener('keydown', this.onEscape, true);
    }
  },
  beforeUpdate() {
    this.wasOpen = this.el.open;
  },
  updated() {
    if (this.wasOpen !== undefined) this.el.open = this.wasOpen;
  },
  destroyed() {
    if (this.transient) {
      document.removeEventListener('pointerdown', this.onOutside, true);
      document.removeEventListener('keydown', this.onEscape, true);
    }
  }
};
