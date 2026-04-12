import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "backdrop", "input", "results", "empty", "loading"]
  static values = { url: String }

  open() {
    this.modalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
    this.inputTarget.value = ""
    this.resultsTarget.innerHTML = ""
    this.emptyTarget.classList.add("hidden")
    this.loadingTarget.classList.add("hidden")
    setTimeout(() => this.inputTarget.focus(), 100)
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
  }

  backdropClick(event) {
    if (event.target === this.backdropTarget) {
      this.close()
    }
  }

  search() {
    clearTimeout(this._debounce)
    this._debounce = setTimeout(() => this._performSearch(), 300)
  }

  async _performSearch() {
    const query = this.inputTarget.value.trim()
    if (query.length < 2) {
      this.resultsTarget.innerHTML = ""
      this.emptyTarget.classList.add("hidden")
      return
    }

    this.loadingTarget.classList.remove("hidden")
    this.emptyTarget.classList.add("hidden")

    try {
      const response = await fetch(`${this.urlValue}?q=${encodeURIComponent(query)}`, {
        headers: { "Accept": "application/json" }
      })
      const data = await response.json()
      this._renderResults(data)
    } catch {
      this.resultsTarget.innerHTML = ""
    } finally {
      this.loadingTarget.classList.add("hidden")
    }
  }

  _renderResults(results) {
    if (results.length === 0) {
      this.resultsTarget.innerHTML = ""
      this.emptyTarget.classList.remove("hidden")
      return
    }

    this.emptyTarget.classList.add("hidden")
    this.resultsTarget.innerHTML = results.map(r => {
      const name = r.customer_name || ""
      const email = r.customer_email || ""
      const badge = r.match_type === "order"
        ? `<span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-blue-100 text-blue-700">${r.order_name}</span>`
        : `<span class="text-xs text-gray-400">${r.order_count} order(s)</span>`

      return `
        <button type="button"
                data-action="click->customer-search-modal#select"
                data-customer-id="${r.customer_id}"
                class="w-full text-left px-4 py-3 hover:bg-gray-50 border-b border-gray-100 last:border-0 transition">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-gray-900">${this._escapeHtml(name)}</p>
              <p class="text-xs text-gray-500">${this._escapeHtml(email)}</p>
            </div>
            <div>${badge}</div>
          </div>
        </button>
      `
    }).join("")
  }

  select(event) {
    const customerId = event.currentTarget.dataset.customerId
    const form = document.getElementById("link-customer-form")
    const input = form.querySelector('input[name="customer_id"]')
    input.value = customerId
    form.requestSubmit()
  }

  _escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }
}
