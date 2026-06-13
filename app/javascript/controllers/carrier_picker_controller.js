import { Controller } from "@hotwired/stimulus"

// Mirrors the shipment-tags modal contract: exposes `formTarget`,
// `idsContainerTarget`, and `open(event)` for shipment-bulk to drive.
export default class extends Controller {
  static targets = ["modal", "form", "idsContainer", "search", "results", "code", "confirm"]
  static values = { url: String, noResults: String }

  connect() {
    this.carriers = null
  }

  async open() {
    this.modalTarget.classList.remove("hidden")
    this.resetSelection()
    if (!this.carriers) await this.loadCarriers()
    this.render(this.carriers.slice(0, 50))
    this.searchTarget.focus()
  }

  close() {
    this.modalTarget.classList.add("hidden")
  }

  async loadCarriers() {
    const res = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
    this.carriers = res.ok ? await res.json() : []
  }

  filter() {
    const q = this.searchTarget.value.trim().toLowerCase()
    if (!q) return this.render(this.carriers.slice(0, 50))
    const matches = this.carriers.filter(c =>
      c.name.toLowerCase().includes(q) || String(c.code).includes(q)
    ).slice(0, 50)
    this.render(matches)
  }

  render(list) {
    if (!list.length) {
      this.resultsTarget.innerHTML = `<p class="px-3 py-2 text-sm text-gray-500">${this.noResultsValue}</p>`
      return
    }
    this.resultsTarget.innerHTML = list.map(c => `
      <button type="button" data-action="click->carrier-picker#select"
              data-code="${c.code}" data-name="${c.name}"
              class="flex items-center justify-between w-full px-3 py-2 text-sm text-left hover:bg-gray-50">
        <span class="text-gray-700">${c.name}</span>
        <span class="text-xs text-gray-400">${c.country || ""} · ${c.code}</span>
      </button>`).join("")
  }

  select(event) {
    const { code, name } = event.currentTarget.dataset
    this.codeTarget.value = code
    this.searchTarget.value = name
    this.confirmTarget.disabled = false
    this.resultsTarget.innerHTML = ""
  }

  resetSelection() {
    this.codeTarget.value = ""
    this.searchTarget.value = ""
    this.confirmTarget.disabled = true
    this.resultsTarget.innerHTML = ""
  }
}
