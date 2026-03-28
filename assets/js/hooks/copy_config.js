// CopyConfig: copies text content of the element to clipboard
export const CopyConfig = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.copy || this.el.innerText
      navigator.clipboard.writeText(text).catch(() => {})
    })
  }
}

// CopyToClipboard: copies data-copy attribute to clipboard on button click, notifies server
export const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.copy
      if (text) {
        navigator.clipboard.writeText(text).then(() => {
          this.pushEvent("copy", {})
        }).catch(() => {
          this.pushEvent("copy", {})
        })
      }
    })
  }
}

// CopyOnClick: copies data-copy attribute when the block itself is clicked
export const CopyOnClick = {
  mounted() {
    this.el.style.cursor = "pointer"
    this.el.title = "Click to copy"
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.copy || this.el.innerText.trim()
      navigator.clipboard.writeText(text).catch(() => {})
    })
  }
}
