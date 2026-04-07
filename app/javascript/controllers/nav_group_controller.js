import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "arrow"]
  static values = { open: { type: Boolean, default: false } }

  connect() {
    if (this.openValue) {
      this.menuTarget.classList.remove("hidden")
      this.arrowTarget.classList.add("rotate-90")
    }
    this.#syncAria()
  }

  toggle() {
    this.openValue = !this.openValue
    this.menuTarget.classList.toggle("hidden")
    this.arrowTarget.classList.toggle("rotate-90")
    this.#syncAria()
  }

  #syncAria() {
    this.element.querySelector("button").setAttribute("aria-expanded", this.openValue)
  }
}
