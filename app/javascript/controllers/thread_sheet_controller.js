import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["sheet"]

  open() {
    this.sheetTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
  }

  close() {
    this.sheetTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
  }

  closeBackdrop(event) {
    if (event.target === this.sheetTarget) this.close()
  }
}
