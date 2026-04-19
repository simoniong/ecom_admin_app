import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "enableToggle",
    "configWrapper",
    "keyInput",
    "scopeWrapper",
    "daysInput",
    "allCheckbox",
  ]

  connect() {
    this.recompute()
  }

  recompute() {
    const enabled = this.hasEnableToggleTarget && this.enableToggleTarget.checked
    this.configWrapperTarget.classList.toggle("hidden", !enabled)

    if (!enabled) return

    const keyPresent = this.hasKeyInputTarget && this.keyInputTarget.value.trim().length > 0
    this.scopeWrapperTarget.classList.toggle("hidden", !keyPresent)

    if (keyPresent && this.hasAllCheckboxTarget && this.hasDaysInputTarget) {
      const all = this.allCheckboxTarget.checked
      this.daysInputTarget.disabled = all
      this.daysInputTarget.classList.toggle("bg-gray-100", all)
      this.daysInputTarget.classList.toggle("text-gray-400", all)
    }
  }
}
