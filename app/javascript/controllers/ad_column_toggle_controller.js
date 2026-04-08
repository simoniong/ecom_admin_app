import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

/**
 * Manages column visibility & order for the Ad Campaigns table.
 * Persists to server-side CampaignDisplayTemplate via fetch.
 */
export default class extends Controller {
  static targets = [
    "dropdown",       // modal container
    "list",           // sortable list container
    "item",           // individual draggable items
    "checkbox",       // column checkboxes
    "templateSelect", // template dropdown
    "nameInput",      // template name input (for save-as-new)
    "saveSection",    // save-as-new section
    "syncIcon",       // sync button icon (for spin animation)
    "syncLabel",      // sync button label text
  ]

  static values = {
    activeTemplateId: String,
    createUrl: String,
  }

  connect() {
    this.initSortable()
    this.applyColumnsFromPopover()
  }

  disconnect() {
    if (this.sortable) this.sortable.destroy()
  }

  initSortable() {
    if (!this.hasListTarget) return

    this.sortable = Sortable.create(this.listTarget, {
      handle: "[data-drag-handle]",
      ghostClass: "opacity-50",
      animation: 150,
      onEnd: () => this.applyColumnsFromPopover()
    })
  }

  // --- Modal open / close ---

  toggle() {
    const isHidden = this.dropdownTarget.classList.contains("hidden")
    if (isHidden) {
      this.dropdownTarget.classList.remove("hidden")
      document.body.classList.add("overflow-hidden")
    } else {
      this.dropdownTarget.classList.add("hidden")
      document.body.classList.remove("overflow-hidden")
    }
  }

  close() {
    // kept for data-action compatibility
  }

  backdropClick(event) {
    // Only close if the click is directly on the backdrop overlay
    if (event.target === event.currentTarget) {
      this.toggle()
    }
  }

  stopPropagation(event) {
    event.stopPropagation()
  }

  // --- Column visibility ---

  columnChanged() {
    this.applyColumnsFromPopover()
  }

  applyColumnsFromPopover() {
    const table = document.querySelector("[data-ad-table]")
    if (!table) return

    // Build visibility map from current checkbox state
    const visibilityMap = new Map()
    this.checkboxTargets.forEach(cb => {
      visibilityMap.set(cb.dataset.column, cb.checked)
    })

    // Apply visibility
    visibilityMap.forEach((visible, column) => {
      table.querySelectorAll(`[data-column="${column}"]`).forEach(el => {
        el.classList.toggle("hidden", !visible)
      })
    })

    // Apply column order from dropdown item order
    const order = this.itemTargets.map(item => item.dataset.column)
    const rows = table.querySelectorAll("tr")
    rows.forEach(row => {
      const cells = Array.from(row.children)
      if (cells.length === 0) return

      // First two cells (campaign_name, status) stay fixed
      const cellMap = new Map()
      cells.slice(2).forEach(cell => {
        const col = cell.getAttribute("data-column")
        if (col) cellMap.set(col, cell)
      })

      order.forEach(colId => {
        const cell = cellMap.get(colId)
        if (cell) {
          row.appendChild(cell)
          cellMap.delete(colId)
        }
      })
      cellMap.forEach(cell => row.appendChild(cell))
    })
  }

  // --- Template switching ---

  templateChanged(event) {
    const templateId = event.currentTarget.value
    if (!templateId) return

    const url = new URL(window.location.href)
    url.searchParams.set("template_id", templateId)
    window.location.href = url.toString()
  }

  // --- Template CRUD ---

  showSaveSection() {
    if (this.hasSaveSectionTarget) {
      this.saveSectionTarget.classList.remove("hidden")
      this.nameInputTarget.focus()
    }
  }

  hideSaveSection() {
    if (this.hasSaveSectionTarget) {
      this.saveSectionTarget.classList.add("hidden")
    }
  }

  async saveAsNew(event) {
    event.preventDefault()
    const name = this.nameInputTarget.value.trim()
    if (!name) {
      this.nameInputTarget.focus()
      return
    }

    const columns = this.getVisibleColumnsOrdered()
    const token = document.querySelector('meta[name="csrf-token"]')?.content

    try {
      const response = await fetch(this.createUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": token,
          "Accept": "application/json"
        },
        body: JSON.stringify({
          campaign_display_template: { name, visible_columns: columns }
        })
      })

      const data = await response.json()
      if (data.redirect_url) {
        window.location.href = data.redirect_url
      } else if (data.errors) {
        alert(data.errors.join(", "))
      }
    } catch (err) {
      console.error("Save template failed:", err)
    }
  }

  async updateTemplate(event) {
    event.preventDefault()
    if (!this.activeTemplateIdValue) return

    const columns = this.getVisibleColumnsOrdered()
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const url = this.createUrlValue.replace(/\/$/, "") + "/" + this.activeTemplateIdValue

    try {
      const response = await fetch(url, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": token,
          "Accept": "application/json"
        },
        body: JSON.stringify({
          campaign_display_template: { visible_columns: columns }
        })
      })

      const data = await response.json()
      if (data.redirect_url) {
        window.location.href = data.redirect_url
      } else if (data.errors) {
        alert(data.errors.join(", "))
      }
    } catch (err) {
      console.error("Update template failed:", err)
    }
  }

  async deleteTemplate(event) {
    event.preventDefault()
    if (!this.activeTemplateIdValue) return
    if (!confirm(this.element.dataset.deleteConfirm || "Delete this template?")) return

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const url = this.createUrlValue.replace(/\/$/, "") + "/" + this.activeTemplateIdValue

    try {
      const response = await fetch(url, {
        method: "DELETE",
        headers: {
          "X-CSRF-Token": token,
          "Accept": "application/json"
        }
      })

      const data = await response.json()
      if (data.redirect_url) {
        window.location.href = data.redirect_url
      }
    } catch (err) {
      console.error("Delete template failed:", err)
    }
  }

  // --- Sync ---

  async syncAds(event) {
    const btn = event.currentTarget
    const url = btn.dataset.syncUrl
    if (!url || btn.disabled) return

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const originalLabel = this.syncLabelTarget.textContent

    // Disable button and show spinning state
    btn.disabled = true
    this.syncIconTarget.classList.add("animate-spin")
    this.syncLabelTarget.textContent = this.syncLabelTarget.dataset.syncingText || "..."

    try {
      await fetch(url, {
        method: "POST",
        headers: {
          "X-CSRF-Token": token,
          "Accept": "application/json"
        }
      })
      this.syncLabelTarget.textContent = this.syncLabelTarget.dataset.doneText || "✓"
      setTimeout(() => {
        this.syncLabelTarget.textContent = originalLabel
        btn.disabled = false
        this.syncIconTarget.classList.remove("animate-spin")
      }, 2000)
    } catch {
      this.syncLabelTarget.textContent = originalLabel
      btn.disabled = false
      this.syncIconTarget.classList.remove("animate-spin")
    }
  }

  // --- Helpers ---

  getVisibleColumnsOrdered() {
    return this.itemTargets
      .filter(item => {
        const cb = item.querySelector("input[type='checkbox']")
        return cb && cb.checked
      })
      .map(item => item.dataset.column)
  }
}
