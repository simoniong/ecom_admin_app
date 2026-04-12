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
    this.element.className = this.element.className
      .replace(/bg-gray-\d+/g, "bg-red-600")
      .replace(/hover:bg-gray-\d+/g, "hover:bg-red-700")
      .replace(/focus:ring-gray-\d+/g, "focus:ring-red-500")

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
