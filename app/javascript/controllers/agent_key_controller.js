import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["value", "revealLabel", "hideLabel"]
  static values = {
    key: String,
    masked: { type: String, default: "••••••••••••••••••••••••••••••••••••••••••" },
    revealed: Boolean,
    copyMessage: { type: String, default: "Copied!" }
  }

  connect() {
    this.render()
  }

  toggle() {
    this.revealedValue = !this.revealedValue
    this.render()
  }

  copy() {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(this.keyValue).then(() => this.flash()).catch(() => this.fallbackCopy())
    } else {
      this.fallbackCopy()
    }
  }

  fallbackCopy() {
    const textarea = document.createElement("textarea")
    textarea.value = this.keyValue
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.select()
    document.execCommand("copy")
    textarea.remove()
    this.flash()
  }

  render() {
    if (!this.hasValueTarget) return
    this.valueTarget.textContent = this.revealedValue ? this.keyValue : this.maskedValue
    this.valueTarget.dataset.state = this.revealedValue ? "revealed" : "masked"

    if (this.hasRevealLabelTarget) this.revealLabelTarget.classList.toggle("hidden", this.revealedValue)
    if (this.hasHideLabelTarget) this.hideLabelTarget.classList.toggle("hidden", !this.revealedValue)
  }

  flash() {
    const el = document.createElement("div")
    el.textContent = this.copyMessageValue
    el.setAttribute("role", "status")
    el.setAttribute("aria-live", "polite")
    el.className = "fixed top-4 right-4 z-50 px-4 py-2 bg-gray-900 text-white text-sm rounded-lg shadow-lg transition-opacity duration-300"
    document.body.appendChild(el)
    setTimeout(() => {
      el.classList.add("opacity-0")
      setTimeout(() => el.remove(), 300)
    }, 1500)
  }
}
