import { Controller } from "@hotwired/stimulus"

// Lightweight bulk selection for the pending_review, pending_process, and
// pending_label packages lists. Shows the action bar with a live count when
// at least one row is checked.
export default class extends Controller {
  static targets = ["checkbox", "bar", "count", "all", "rows"]

  connect() {
    // refresh() only ran on a checkbox's own "change" event, so a Turbo
    // Stream replacing or removing a row (a split/merge folding a checked
    // row into new ones, or collapsing checked rows away) never recomputed
    // it — the bar kept reporting a selection nothing on screen matches. A
    // MutationObserver on the ROWS container (not this.element, which also
    // contains the bar/count nodes refresh() itself writes to — observing
    // that would self-trigger) catches every such change, however it
    // happens, without depending on which Turbo Stream action produced it.
    if (this.hasRowsTarget) {
      this._rowsObserver = new MutationObserver(() => this.refresh())
      this._rowsObserver.observe(this.rowsTarget, { childList: true, subtree: true })
    }
  }

  disconnect() {
    this._rowsObserver?.disconnect()
  }

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
