export const CopyConfig = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      if (e.target.closest("button[phx-click='copy_config']")) {
        const pre = this.el.querySelector("pre")
        if (pre) {
          navigator.clipboard.writeText(pre.textContent.trim())
          this.pushEvent("copied", {})
        }
      }
    })
  }
}
