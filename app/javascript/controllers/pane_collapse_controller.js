import { Controller } from "@hotwired/stimulus"

// Collapses the ticket thread pane into a narrow rail.
//
// The grid width lives in a CSS custom property rather than a swapped Tailwind
// class so the utility stays a static string the Tailwind scanner can see, and
// so the collapse only takes effect at the lg breakpoint where the property is
// referenced. State is persisted in a cookie (not localStorage) so the server
// renders the collapsed state on first paint instead of flashing open.
export default class extends Controller {
  static targets = ["rail", "panel"]
  static values = {
    collapsed: Boolean,
    property: { type: String, default: "--left-col" },
    expandedWidth: { type: String, default: "300px" },
    collapsedWidth: { type: String, default: "44px" },
    cookieName: { type: String, default: "ticket_threads_pane" }
  }

  collapse() {
    this.collapsedValue = true
  }

  expand() {
    this.collapsedValue = false
  }

  collapsedValueChanged(collapsed, previous) {
    this.element.style.setProperty(
      this.propertyValue,
      collapsed ? this.collapsedWidthValue : this.expandedWidthValue
    )

    if (this.hasRailTarget) this.railTarget.classList.toggle("hidden", !collapsed)
    if (this.hasPanelTarget) this.panelTarget.classList.toggle("hidden", collapsed)

    // Skip the initial call — the cookie already says what the server rendered.
    if (previous !== undefined) this.#persist(collapsed)
  }

  #persist(collapsed) {
    const value = collapsed ? "collapsed" : "expanded"
    document.cookie = `${this.cookieNameValue}=${value}; path=/; max-age=31536000; samesite=lax`
  }
}
