import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "textarea", "lineCount", "searchBtn", "hiddenField"]

  open() {
    this.modalTarget.classList.remove("hidden")
    this.textareaTarget.value = ""
    this.textareaTarget.focus()
    this.updateLineCount()
  }

  close() {
    this.modalTarget.classList.add("hidden")
  }

  updateLineCount() {
    const lines = this.textareaTarget.value.split(/\r?\n/).filter(l => l.trim() !== "")
    const count = lines.length
    this.lineCountTarget.textContent = count
    const hasInput = count > 0
    this.searchBtnTarget.disabled = !hasInput
    this.searchBtnTarget.classList.toggle("opacity-50", !hasInput)
    this.searchBtnTarget.classList.toggle("cursor-not-allowed", !hasInput)
  }

  submit() {
    const text = this.textareaTarget.value.trim()
    if (!text) return

    this.hiddenFieldTarget.value = text
    this.close()
    this.hiddenFieldTarget.form.submit()
  }

  clear() {
    this.hiddenFieldTarget.value = ""
    this.hiddenFieldTarget.form.submit()
  }
}
