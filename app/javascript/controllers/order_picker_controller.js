import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "backdrop", "input", "results", "orderId", "form"]
  static values = { url: String }

  open() {
    this.modalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
    this.inputTarget.value = ""
    this._performSearch()
    setTimeout(() => this.inputTarget.focus(), 100)
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
  }

  backdropClick(event) {
    if (event.target === this.backdropTarget) this.close()
  }

  search() {
    clearTimeout(this._debounce)
    this._debounce = setTimeout(() => this._performSearch(), 300)
  }

  select(event) {
    this.orderIdTarget.value = event.params.id || ""
    this.formTarget.requestSubmit()
  }

  async _performSearch() {
    const query = this.inputTarget.value.trim()
    const res = await fetch(`${this.urlValue}?q=${encodeURIComponent(query)}`,
      { headers: { Accept: "application/json" } })
    if (!res.ok) return
    this._render(await res.json())
  }

  _render(orders) {
    const rows = orders.map((o) => `
      <button type="button" data-action="click->order-picker#select"
              data-order-picker-id-param="${o.id}"
              class="w-full text-left px-5 py-3 hover:bg-gray-50">
        <p class="text-sm font-medium text-gray-900">${o.name ?? ""}</p>
        <p class="text-xs text-gray-500">${o.customer_name ?? ""} · ${o.fulfillment_status ?? ""}</p>
      </button>`).join("")
    this.resultsTarget.innerHTML = rows + `
      <button type="button" data-action="click->order-picker#select"
              data-order-picker-id-param=""
              class="w-full text-left px-5 py-3 hover:bg-gray-50 text-gray-500">
        <p class="text-sm font-medium">${this.data.get("clearLabel") || "No order"}</p>
      </button>`
  }
}
