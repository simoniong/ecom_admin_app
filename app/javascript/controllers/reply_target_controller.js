import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["currentBtn", "newBtn", "newFields", "form"]
  static values = { currentUrl: String, newUrl: String }

  connect() {
    this._onUseNew = () => this.useNew()
    window.addEventListener("reply-target:use-new", this._onUseNew)
  }

  disconnect() {
    window.removeEventListener("reply-target:use-new", this._onUseNew)
  }

  useCurrent() { this._set(false) }
  useNew() { this._set(true) }

  _set(isNew) {
    this.newFieldsTarget.classList.toggle("hidden", !isNew)
    this.currentBtnTarget.classList.toggle("bg-white", !isNew)
    this.currentBtnTarget.classList.toggle("shadow-sm", !isNew)
    this.newBtnTarget.classList.toggle("bg-white", isNew)
    this.newBtnTarget.classList.toggle("shadow-sm", isNew)

    if (this.hasFormTarget) {
      const form = this.formTarget
      const methodInput = form.querySelector('input[name="_method"]')
      if (isNew) {
        form.action = this.newUrlValue
        if (methodInput) methodInput.value = "post"
      } else {
        form.action = this.currentUrlValue
        if (methodInput) methodInput.value = "patch"
      }
    }

    const subjectInput = this.newFieldsTarget.querySelector('input[name="ticket[subject]"]')
    if (subjectInput) subjectInput.required = isNew
  }
}
