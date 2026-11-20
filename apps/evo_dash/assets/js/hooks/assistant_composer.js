export default {
  mounted() {
    this.onKeyDown = (event) => {
      if (event.defaultPrevented || event.key !== "Enter" || event.shiftKey) return
      // Some browsers report IME confirmation as key code 229 without isComposing.
      if (event.isComposing || event.keyCode === 229) return

      event.preventDefault()
      if (!event.repeat) this.el.form.requestSubmit()
    }
    this.el.addEventListener("keydown", this.onKeyDown)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeyDown)
  }
}
