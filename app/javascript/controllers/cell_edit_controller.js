import { Controller } from "@hotwired/stimulus"

// Click-to-edit a single field on a record from inside a table cell.
//
// Markup:
//   <td data-controller="cell-edit"
//       data-cell-edit-url-value="/shipping_rate_card_versions/123/rates/456"
//       data-cell-edit-param-value="shipping_rate_card_rate"
//       data-cell-edit-field-value="per_kg_rate_cny"
//       data-cell-edit-type-value="number"
//       data-cell-edit-step-value="0.01"
//       data-cell-edit-min-value="0">
//     <span data-cell-edit-target="display"
//           data-action="click->cell-edit#startEdit">12.50</span>
//   </td>
//
// type can be "number" (default), "text", or "date".
// param is the strong-params wrapper key (default "product_variant").
// Server must respond with a Turbo Stream that replaces the entire row.

export default class extends Controller {
  static targets = ["display"]
  static values  = {
    url:   String,
    param: { type: String, default: "product_variant" },
    field: String,
    type:  { type: String, default: "number" },
    step:  { type: String, default: "0.01" },
    min:   { type: String, default: "0" },
    blank: { type: String, default: "—" }
  }

  startEdit(event) {
    // Stimulus also fires this on keydown.space; stop the default page scroll.
    if (event && event.type === "keydown" && event.key === " ") event.preventDefault()
    if (this.element.querySelector("input")) return // already editing

    const currentText = this.displayTarget.textContent.trim()
    const isBlank = currentText === this.blankValue
    let currentValue
    if (this.typeValue === "number") {
      // Strip thousands separators, currency / unit suffixes, etc.
      const cleaned = currentText.replace(/[^\d.\-]/g, "")
      currentValue = (isBlank || cleaned === "" || cleaned === "-") ? "" : cleaned
    } else {
      currentValue = isBlank ? "" : currentText
    }

    const input = document.createElement("input")
    input.type = this.typeValue
    if (this.typeValue === "number") {
      input.step = this.stepValue
      input.min  = this.minValue
    }
    input.value = currentValue
    input.className = "w-32 border border-blue-500 rounded px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-blue-300"
    input.dataset.action = "blur->cell-edit#save keydown.enter->cell-edit#save keydown.escape->cell-edit#cancel"

    this.displayTarget.classList.add("hidden")
    this.element.appendChild(input)
    input.focus()
    // <input type="date"> does not support select(); guard it.
    if (this.typeValue !== "date") input.select()
  }

  async save(event) {
    const input = this.element.querySelector("input")
    if (!input) return
    if (event.type === "keydown" && event.key === "Enter") event.preventDefault()

    if (input.dataset.saving === "1") return
    input.dataset.saving = "1"

    const body = new FormData()
    body.append("authenticity_token", document.querySelector('meta[name="csrf-token"]').content)
    body.append("_method", "patch")
    body.append(`${this.paramValue}[${this.fieldValue}]`, input.value)

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        body,
        headers: { "Accept": "text/vnd.turbo-stream.html" }
      })

      // If the session expired (or any other 30x), fetch silently follows
      // the redirect and returns a 200 HTML page — NOT a Turbo Stream.
      // Navigate to the final URL so Devise can handle re-auth properly.
      if (response.redirected) {
        window.Turbo.visit(response.url)
        return
      }

      const contentType = response.headers.get("Content-Type") || ""
      const isTurboStream = contentType.includes("turbo-stream")

      if (response.ok && isTurboStream) {
        const text = await response.text()
        window.Turbo.renderStreamMessage(text)
      } else {
        this._markFailed(input)
      }
    } catch (e) {
      this._markFailed(input)
    }
  }

  _markFailed(input) {
    input.dataset.saving = ""
    input.classList.remove("border-blue-500")
    input.classList.add("border-red-500", "bg-red-50")
    input.focus()
  }

  cancel() {
    const input = this.element.querySelector("input")
    if (input) input.remove()
    this.displayTarget.classList.remove("hidden")
  }
}
