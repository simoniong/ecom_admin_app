import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["display", "editor", "textarea", "submitBtn", "error"]

  static EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

  edit() {
    this.displayTarget.classList.add("hidden")
    this.editorTarget.classList.remove("hidden")
    this.textareaTarget.focus()
    this.validateCompleted()
  }

  cancel() {
    this.editorTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
    this.clearError()
  }

  // Triggered on keyup — only validate when user presses Enter, comma, or space
  checkKey(event) {
    if (event.key === "Enter" || event.key === "," || event.key === " ") {
      this.validateCompleted()
    }
  }

  // Triggered on blur — validate all lines when leaving the field
  validateAll() {
    const lines = this.parseEmails()
    this.showValidation(lines)
  }

  // Only validate completed lines (all except the last line being typed)
  validateCompleted() {
    const lines = this.parseEmails()
    // Skip the last line — user may still be typing it
    const completed = lines.slice(0, -1)
    this.showValidation(completed)
  }

  parseEmails() {
    return this.textareaTarget.value
      .split(/[\n,\s]+/)
      .map(l => l.trim())
      .filter(l => l !== "")
  }

  showValidation(lines) {
    const invalid = lines.filter(l => !this.constructor.EMAIL_REGEX.test(l))

    if (invalid.length > 0) {
      this.textareaTarget.classList.remove("border-gray-300", "focus:border-blue-500")
      this.textareaTarget.classList.add("border-red-500", "focus:border-red-500")
      this.errorTarget.textContent = `Invalid email: ${invalid.join(", ")}`
      this.errorTarget.classList.remove("hidden")
      this.submitBtnTarget.disabled = true
      this.submitBtnTarget.classList.add("opacity-50", "cursor-not-allowed")
    } else {
      this.clearError()
    }
  }

  clearError() {
    this.textareaTarget.classList.remove("border-red-500", "focus:border-red-500")
    this.textareaTarget.classList.add("border-gray-300", "focus:border-blue-500")
    this.errorTarget.textContent = ""
    this.errorTarget.classList.add("hidden")
    this.submitBtnTarget.disabled = false
    this.submitBtnTarget.classList.remove("opacity-50", "cursor-not-allowed")
  }
}
