import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.element.addEventListener("load", () => this.resize())
  }

  resize() {
    try {
      const height = this.element.contentDocument.documentElement.scrollHeight
      this.element.style.height = `${Math.min(height + 20, 600)}px`
    } catch (e) {
      // sandbox may prevent access
      this.element.style.height = "300px"
    }
  }
}
