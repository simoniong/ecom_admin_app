import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "textarea", "lineCount", "results", "resultCount", "searchBtn", "spinner"]
  static values = { url: String }

  open() {
    this.modalTarget.classList.remove("hidden")
    this.textareaTarget.value = ""
    this.textareaTarget.focus()
    this.updateLineCount()
    this.resultsTarget.innerHTML = ""
    this.resultCountTarget.classList.add("hidden")
    this.searchBtnTarget.disabled = true
    this.searchBtnTarget.classList.add("opacity-50", "cursor-not-allowed")
  }

  close() {
    this.modalTarget.classList.add("hidden")
  }

  updateLineCount() {
    const lines = this.textareaTarget.value.split(/\r?\n/).filter(l => l.trim() !== "")
    const count = lines.length
    this.lineCountTarget.textContent = count
    const hasInput = count > 0
    this.searchBtnTarget.disabled = !hasInput
    this.searchBtnTarget.classList.toggle("opacity-50", !hasInput)
    this.searchBtnTarget.classList.toggle("cursor-not-allowed", !hasInput)
  }

  async search() {
    const lines = this.textareaTarget.value.split(/\r?\n/).filter(l => l.trim() !== "")
    if (lines.length === 0) return

    this.searchBtnTarget.disabled = true
    this.spinnerTarget.classList.remove("hidden")

    try {
      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          "Accept": "application/json"
        },
        body: JSON.stringify({ tracking_numbers: lines.join("\n") })
      })

      const data = await response.json()
      this.renderResults(data)
    } catch (error) {
      this.resultsTarget.innerHTML = `<p class="text-sm text-red-500 py-4 text-center">Search failed. Please try again.</p>`
    } finally {
      this.spinnerTarget.classList.add("hidden")
      this.searchBtnTarget.disabled = false
    }
  }

  renderResults(data) {
    this.resultCountTarget.classList.remove("hidden")
    this.resultCountTarget.innerHTML =
      `<span class="text-sm text-gray-600">${data.found_count} / ${data.total} found</span>`

    if (data.results.length === 0) {
      this.resultsTarget.innerHTML = `<p class="text-sm text-gray-500 py-4 text-center">No results</p>`
      return
    }

    const rows = data.results.map(r => {
      if (r.found) {
        return `<tr class="hover:bg-gray-50">
          <td class="px-3 py-2 text-sm font-mono text-gray-900 whitespace-nowrap">
            <a href="/shipments/${r.fulfillment_id}" class="text-blue-600 hover:underline" target="_blank">${this.escapeHtml(r.tracking_number)}</a>
          </td>
          <td class="px-3 py-2 text-sm text-blue-600 font-medium whitespace-nowrap">${this.escapeHtml(r.order_name)}</td>
          <td class="px-3 py-2 text-sm text-gray-600 whitespace-nowrap">${this.escapeHtml(r.status || "--")}</td>
          <td class="px-3 py-2 text-sm text-gray-600 whitespace-nowrap">${this.escapeHtml(r.shop_name || "--")}</td>
        </tr>`
      } else {
        return `<tr class="bg-red-50">
          <td class="px-3 py-2 text-sm font-mono text-gray-500 whitespace-nowrap">${this.escapeHtml(r.tracking_number)}</td>
          <td colspan="3" class="px-3 py-2 text-sm text-red-500">Not found</td>
        </tr>`
      }
    }).join("")

    this.resultsTarget.innerHTML = `
      <table class="min-w-full divide-y divide-gray-200">
        <thead class="bg-gray-50">
          <tr>
            <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase">Tracking No.</th>
            <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase">Order</th>
            <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase">Status</th>
            <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase">Store</th>
          </tr>
        </thead>
        <tbody class="bg-white divide-y divide-gray-200">${rows}</tbody>
      </table>`
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
