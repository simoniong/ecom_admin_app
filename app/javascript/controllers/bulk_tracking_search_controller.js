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
    const unique = this.uniqueLines()
    this.lineCountTarget.textContent = unique.length
    const hasInput = unique.length > 0
    this.searchBtnTarget.disabled = !hasInput
    this.searchBtnTarget.classList.toggle("opacity-50", !hasInput)
    this.searchBtnTarget.classList.toggle("cursor-not-allowed", !hasInput)
  }

  submit() {
    const unique = this.uniqueLines()
    if (unique.length === 0) return

    this.hiddenFieldTarget.value = unique.join("\n")
    this.close()
    this.hiddenFieldTarget.form.submit()
  }

  uniqueLines() {
    const lines = this.textareaTarget.value.split(/\r?\n/).map(l => l.trim()).filter(l => l !== "")
    return [...new Set(lines)]
  }
}
