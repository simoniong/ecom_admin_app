import { Controller } from "@hotwired/stimulus"

// Two-step confirmation button to prevent accidental clicks.
// First click arms the button (shows confirm text + red style).
// Second click within the timeout submits the form.
// Auto-resets after 3 seconds if not confirmed.
export default class extends Controller {
  static values = {
    confirmText: String,
    timeout: { type: Number, default: 3000 }
  }

  connect() {
    this.armed = false
    this.originalHTML = this.element.innerHTML
    this.originalClasses = this.element.className
  }

  fire(event) {
    if (!this.armed) {
      event.preventDefault()
      this.arm()
    }
    // If armed, let the form submit naturally
  }

  arm() {
    this.armed = true
    this.element.textContent = this.confirmTextValue
    // Match whole class tokens (not substrings) so any Tailwind color family
    // (gray, green, etc.) is swapped to red without one replacement's output
    // being re-matched by a later, broader regex (e.g. "hover:bg-red-700"
    // getting its "bg-red-700" portion re-matched by the plain bg- rule).
    this.element.className = this.element.className
      .split(/\s+/)
      .map((token) => {
        if (/^hover:bg-[a-z]+-\d+$/.test(token)) return "hover:bg-red-700"
        // Exclude "offset" so the ring-offset-width utility (e.g. focus:ring-offset-2)
        // isn't mistaken for a ring-color utility (e.g. focus:ring-green-500).
        if (/^focus:ring-(?!offset-)[a-z]+-\d+$/.test(token)) return "focus:ring-red-500"
        if (/^bg-[a-z]+-\d+$/.test(token)) return "bg-red-600"
        return token
      })
      .join(" ")

    this.timer = setTimeout(() => this.reset(), this.timeoutValue)
  }

  reset() {
    this.armed = false
    this.element.innerHTML = this.originalHTML
    this.element.className = this.originalClasses
    if (this.timer) clearTimeout(this.timer)
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }
}
