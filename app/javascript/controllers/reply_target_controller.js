import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["currentBtn", "newBtn", "newFields"]

  useCurrent() { this._set(false) }
  useNew() { this._set(true) }

  _set(isNew) {
    this.newFieldsTarget.classList.toggle("hidden", !isNew)
    this.currentBtnTarget.classList.toggle("bg-white", !isNew)
    this.currentBtnTarget.classList.toggle("shadow-sm", !isNew)
    this.newBtnTarget.classList.toggle("bg-white", isNew)
    this.newBtnTarget.classList.toggle("shadow-sm", isNew)
  }
}
