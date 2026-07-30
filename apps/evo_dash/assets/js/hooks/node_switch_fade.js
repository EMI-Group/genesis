// NodeSwitchFade hook: applies a brief opacity fade animation on the main
// content area when the node context changes (local ↔ remote switch).
// The <main> element carries a data-node-id attribute that reflects the
// current node id (or "local"). When morphdom updates this attribute after
// a node switch, this hook detects the change and plays a fade.
const NodeSwitchFade = {
  mounted() {
    this.previousNodeId = this.el.getAttribute('data-node-id') || 'local';
  },

  updated() {
    const currentNodeId = this.el.getAttribute('data-node-id') || 'local';
    if (currentNodeId !== this.previousNodeId) {
      this.previousNodeId = currentNodeId;
      this.el.classList.remove('node-switch-fade');
      // Force reflow so the animation restarts if the class was already present
      void this.el.offsetWidth;
      this.el.classList.add('node-switch-fade');
    }
  }
};

export default NodeSwitchFade;
