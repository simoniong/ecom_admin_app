import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "backdrop", "input", "results", "orderId", "form", "force", "confirm", "confirmMessage"]
  static values = { url: String, ticketCustomerId: String, mismatchTemplate: String }

  open() {
    this.modalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
    this.inputTarget.value = ""
    this.cancelForce()
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

  disconnect() {
    clearTimeout(this._debounce)
    if (this._abortController) this._abortController.abort()
  }

  search() {
    clearTimeout(this._debounce)
    this._debounce = setTimeout(() => this._performSearch(), 300)
  }

  select(event) {
    const id = event.params.id || ""
    const customerId = event.params.customerId || ""
    const mismatch = id && this.ticketCustomerIdValue && customerId !== this.ticketCustomerIdValue
    if (mismatch) {
      this._pendingId = id
      this.confirmMessageTarget.textContent = this.mismatchTemplateValue
        .replace("%{order}", event.params.name || "")
        .replace("%{customer}", event.params.customerLabel || "")
      this.confirmTarget.classList.remove("hidden")
      return
    }
    this._submit(id, false)
  }

  confirmForce() {
    if (this._pendingId) this._submit(this._pendingId, true)
  }

  cancelForce() {
    this._pendingId = null
    this.confirmTarget.classList.add("hidden")
  }

  _submit(id, force) {
    this.orderIdTarget.value = id
    this.forceTarget.value = force ? "1" : ""
    this.formTarget.requestSubmit()
  }

  async _performSearch() {
    if (this._abortController) this._abortController.abort()
    this._abortController = new AbortController()

    const query = this.inputTarget.value.trim()
    try {
      const res = await fetch(`${this.urlValue}?q=${encodeURIComponent(query)}`, {
        headers: { Accept: "application/json" },
        signal: this._abortController.signal
      })
      if (!res.ok) throw new Error(`Request failed: ${res.status}`)
      this._render(await res.json())
    } catch (error) {
      if (error.name === "AbortError") return
      this._render([])
    }
  }

  _render(orders) {
    const nodes = orders.map((o) => {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.dataset.action = "click->order-picker#select"
      btn.setAttribute("data-order-picker-id-param", o.id)
      btn.setAttribute("data-order-picker-customer-id-param", o.customer_id ?? "")
      btn.setAttribute("data-order-picker-name-param", o.name ?? "")
      btn.setAttribute("data-order-picker-customer-label-param",
        [o.customer_name, o.customer_email ? `(${o.customer_email})` : null].filter(Boolean).join(" "))
      btn.className = "w-full text-left px-5 py-3 hover:bg-gray-50"

      const nameLine = document.createElement("p")
      nameLine.className = "text-sm font-medium text-gray-900"
      nameLine.textContent = o.name ?? ""

      const metaLine = document.createElement("p")
      metaLine.className = "text-xs text-gray-500"
      metaLine.textContent = `${o.customer_name ?? ""} · ${o.fulfillment_status ?? ""}`

      btn.appendChild(nameLine)
      btn.appendChild(metaLine)
      return btn
    })

    const clearBtn = document.createElement("button")
    clearBtn.type = "button"
    clearBtn.dataset.action = "click->order-picker#select"
    clearBtn.setAttribute("data-order-picker-id-param", "")
    clearBtn.className = "w-full text-left px-5 py-3 hover:bg-gray-50 text-gray-500"

    const clearLine = document.createElement("p")
    clearLine.className = "text-sm font-medium"
    clearLine.textContent = this.data.get("clearLabel") || "No order"

    clearBtn.appendChild(clearLine)
    nodes.push(clearBtn)

    this.resultsTarget.replaceChildren(...nodes)
  }
}
