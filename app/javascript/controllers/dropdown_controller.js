import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "button"]

  connect() {
    this.closeHandler = this.close.bind(this)
    this.keyHandler = this.onKeydown.bind(this)
    document.addEventListener("click", this.closeHandler)
    document.addEventListener("keydown", this.keyHandler)
  }

  disconnect() {
    document.removeEventListener("click", this.closeHandler)
    document.removeEventListener("keydown", this.keyHandler)
  }

  toggle(event) {
    event.stopPropagation()
    const isHidden = this.menuTarget.classList.toggle("hidden")
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", !isHidden)
    }
  }

  close(event) {
    if (!this.element.contains(event.target)) {
      this.hide()
    }
  }

  onKeydown(event) {
    if (event.key === "Escape") {
      this.hide()
    }
  }

  hide() {
    this.menuTarget.classList.add("hidden")
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", "false")
    }
  }
}
