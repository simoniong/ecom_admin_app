import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    text: String,
    successMessage: { type: String, default: "Copied!" }
  }

  copy() {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(this.textValue).then(() => {
        this.flash()
      }).catch(() => {
        this.fallbackCopy()
      })
    } else {
      this.fallbackCopy()
    }
  }

  fallbackCopy() {
    const textarea = document.createElement("textarea")
    textarea.value = this.textValue
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.select()
    document.execCommand("copy")
    textarea.remove()
    this.flash()
  }

  flash() {
    const el = document.createElement("div")
    el.textContent = this.successMessageValue
    el.className = "fixed top-4 right-4 z-50 px-4 py-2 bg-gray-900 text-white text-sm rounded-lg shadow-lg transition-opacity duration-300"
    document.body.appendChild(el)
    setTimeout(() => {
      el.classList.add("opacity-0")
      setTimeout(() => el.remove(), 300)
    }, 1500)
  }
}
