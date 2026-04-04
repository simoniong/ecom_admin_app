import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dropdown", "checkbox"]
  static values = { storageKey: { type: String, default: "shipment_columns" } }

  connect() {
    this.loadPreferences()
    this.applyVisibility()
  }

  toggle() {
    this.dropdownTarget.classList.toggle("hidden")
  }

  close(event) {
    if (this.hasDropdownTarget && !this.dropdownTarget.contains(event.target) &&
        !event.target.closest("[data-action*='column-toggle#toggle']")) {
      this.dropdownTarget.classList.add("hidden")
    }
  }

  columnChanged(event) {
    const column = event.currentTarget.dataset.column
    const visible = event.currentTarget.checked
    this.toggleColumn(column, visible)
    this.savePreferences()
  }

  toggleColumn(column, visible) {
    const elements = document.querySelectorAll(`[data-column="${column}"]`)
    elements.forEach(el => {
      el.classList.toggle("hidden", !visible)
    })
  }

  loadPreferences() {
    try {
      const stored = localStorage.getItem(this.storageKeyValue)
      if (stored) {
        this.preferences = JSON.parse(stored)
      } else {
        this.preferences = null
      }
    } catch {
      this.preferences = null
    }
  }

  applyVisibility() {
    if (!this.preferences) return

    this.checkboxTargets.forEach(checkbox => {
      const column = checkbox.dataset.column
      if (column in this.preferences) {
        checkbox.checked = this.preferences[column]
        this.toggleColumn(column, this.preferences[column])
      }
    })
  }

  savePreferences() {
    const prefs = {}
    this.checkboxTargets.forEach(checkbox => {
      prefs[checkbox.dataset.column] = checkbox.checked
    })
    try {
      localStorage.setItem(this.storageKeyValue, JSON.stringify(prefs))
    } catch {
      // localStorage may be unavailable
    }
  }
}
