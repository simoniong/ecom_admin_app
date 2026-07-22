import { Controller } from "@hotwired/stimulus"

// Lightweight bulk selection for the pending_process packages list. Shows the
// action bar with a live count when at least one row is checked.
export default class extends Controller {
  static targets = ["checkbox", "bar", "count", "all"]

  refresh() {
    const n = this.checkboxTargets.filter((c) => c.checked).length
    if (this.hasCountTarget) this.countTarget.textContent = n
    if (this.hasBarTarget) this.barTarget.classList.toggle("hidden", n === 0)
  }

  toggleAll(event) {
    this.checkboxTargets.forEach((c) => { c.checked = event.target.checked })
    this.refresh()
  }
}
