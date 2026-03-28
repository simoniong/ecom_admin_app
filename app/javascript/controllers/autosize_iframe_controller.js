import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this._onLoad = () => this.resize()
    this.element.addEventListener("load", this._onLoad)
    this.resize()
  }

  disconnect() {
    this.element.removeEventListener("load", this._onLoad)
  }

  resize() {
    // Without allow-same-origin, we can't access contentDocument
    // Use a reasonable default height with scrolling
    this.element.style.height = "300px"
    this.element.style.overflowY = "auto"
  }
}
