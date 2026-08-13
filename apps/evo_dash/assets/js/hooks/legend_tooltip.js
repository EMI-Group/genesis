// LegendTooltip hook: renders the agent-tree legend chip tooltips (data-tip)
// as a fixed-position element appended to document.body. DaisyUI 5's .tooltip
// pseudo-element is clipped by the page-level overflow containers
// (#app-layout, #main-scroll, .agents-page-layout, .agents-left-col), and
// .agents-page-layout's persisted translateY transform (animation-fill-mode:
// both) creates a containing block that would trap even fixed descendants —
// so the tip must live outside the layout entirely.
const LegendTooltip = {
  mounted() {
    this.tipEl = null;
    this._mouseenter = () => this.show();
    this._mouseleave = () => this.hide();
    this.el.addEventListener('mouseenter', this._mouseenter);
    this.el.addEventListener('mouseleave', this._mouseleave);
  },

  destroyed() {
    this.el.removeEventListener('mouseenter', this._mouseenter);
    this.el.removeEventListener('mouseleave', this._mouseleave);
    this.removeTip();
  },

  show() {
    const tipText = this.el.dataset.tip;
    if (!tipText) return;

    if (!this.tipEl) {
      const tip = document.createElement('div');
      tip.className = 'agents-legend-tip';
      tip.textContent = tipText;
      document.body.appendChild(tip);
      this.tipEl = tip;
    }

    const tip = this.tipEl;
    const rect = this.el.getBoundingClientRect();
    const tipWidth = tip.offsetWidth;
    const tipHeight = tip.offsetHeight;

    // Vertical: default above the chip; flip below when there's no room.
    if (rect.top < tipHeight + 16) {
      tip.style.top = `${rect.bottom + 8}px`;
      tip.style.bottom = 'auto';
    } else {
      tip.style.bottom = `${window.innerHeight - rect.top + 8}px`;
      tip.style.top = 'auto';
    }

    // Horizontal: center on the chip, clamped to the viewport.
    const left = Math.min(
      Math.max(rect.left + rect.width / 2 - tipWidth / 2, 8),
      Math.max(8, window.innerWidth - tipWidth - 8)
    );
    tip.style.left = `${left}px`;
    tip.style.right = 'auto';

    // Show after the text is rendered and measured so the CSS opacity
    // transition runs.
    requestAnimationFrame(() => tip.classList.add('is-visible'));
  },

  hide() {
    this.removeTip();
  },

  removeTip() {
    if (this.tipEl) {
      this.tipEl.remove();
      this.tipEl = null;
    }
  }
};

export default LegendTooltip;
