import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

export default class extends Controller {
  static targets = ["dropdown", "checkbox", "list", "item"]
  static values = { storageKey: { type: String, default: "shipment_columns" } }

  connect() {
    this.loadPreferences()
    this.applyPreferences()
    this.initSortable()
  }

  disconnect() {
    if (this.sortable) {
      this.sortable.destroy()
    }
  }

  initSortable() {
    if (!this.hasListTarget) return

    this.sortable = Sortable.create(this.listTarget, {
      handle: "[data-drag-handle]",
      ghostClass: "opacity-50",
      animation: 150,
      onEnd: () => {
        this.applyColumnOrder()
        this.savePreferences()
      }
    })
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
        const parsed = JSON.parse(stored)
        if (Array.isArray(parsed)) {
          // New format: [{ id: "col", visible: true }, ...]
          this.preferences = parsed
        } else if (typeof parsed === "object" && parsed !== null) {
          // Old format: { col: true, ... } — convert to new format
          this.preferences = Object.entries(parsed).map(([id, visible]) => ({ id, visible }))
        } else {
          this.preferences = null
        }
      } else {
        this.preferences = null
      }
    } catch {
      this.preferences = null
    }
  }

  applyPreferences() {
    if (!this.preferences) return

    const prefsMap = new Map(this.preferences.map(p => [p.id, p.visible]))

    // Apply visibility to checkboxes and columns
    this.checkboxTargets.forEach(checkbox => {
      const column = checkbox.dataset.column
      if (prefsMap.has(column)) {
        checkbox.checked = prefsMap.get(column)
        this.toggleColumn(column, prefsMap.get(column))
      }
    })

    // Reorder dropdown items to match saved order
    this.reorderDropdownItems()

    // Reorder table columns to match saved order
    this.applyColumnOrder()
  }

  reorderDropdownItems() {
    if (!this.preferences || !this.hasListTarget) return

    const container = this.listTarget
    const items = Array.from(this.itemTargets)
    const itemMap = new Map(items.map(item => [item.dataset.column, item]))

    // Append items in preference order, then any remaining items not in prefs
    this.preferences.forEach(pref => {
      const item = itemMap.get(pref.id)
      if (item) {
        container.appendChild(item)
        itemMap.delete(pref.id)
      }
    })

    // Append any remaining items (new columns not in saved prefs)
    itemMap.forEach(item => container.appendChild(item))
  }

  applyColumnOrder() {
    const order = this.getCurrentOrder()
    const table = document.querySelector("table")
    if (!table) return

    const rows = table.querySelectorAll("tr")
    rows.forEach(row => {
      const cells = Array.from(row.children)
      if (cells.length === 0) return

      // First cell (tracking_no) stays fixed
      const firstCell = cells[0]
      const cellMap = new Map()
      cells.slice(1).forEach(cell => {
        const col = cell.getAttribute("data-column")
        if (col) cellMap.set(col, cell)
      })

      // Reorder: append cells in the saved order
      order.forEach(colId => {
        const cell = cellMap.get(colId)
        if (cell) {
          row.appendChild(cell)
          cellMap.delete(colId)
        }
      })

      // Append any remaining cells not in order (safety)
      cellMap.forEach(cell => row.appendChild(cell))
    })
  }

  getCurrentOrder() {
    // Get order from dropdown items (reflects drag state)
    return this.itemTargets.map(item => item.dataset.column)
  }

  savePreferences() {
    const prefs = this.itemTargets.map(item => {
      const column = item.dataset.column
      const checkbox = item.querySelector("input[type='checkbox']")
      return { id: column, visible: checkbox ? checkbox.checked : true }
    })
    try {
      localStorage.setItem(this.storageKeyValue, JSON.stringify(prefs))
    } catch {
      // localStorage may be unavailable
    }
  }
}
