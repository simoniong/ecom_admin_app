import { Controller } from "@hotwired/stimulus"

// Click-to-edit a single field on a record from inside a table cell.
//
// Markup:
//   <td data-controller="cell-edit"
//       data-cell-edit-url-value="/product_variants/123"
//       data-cell-edit-field-value="unit_cost"
//       data-cell-edit-step-value="0.01"
//       data-cell-edit-min-value="0">
//     <span data-cell-edit-target="display"
//           data-action="click->cell-edit#startEdit">12.50</span>
//   </td>
//
// Server must respond with a Turbo Stream that replaces the entire row.

export default class extends Controller {
  static targets = ["display"]
  static values  = {
    url:   String,
    field: String,
    step:  { type: String, default: "0.01" },
    min:   { type: String, default: "0" },
    blank: { type: String, default: "—" }
  }

  startEdit(event) {
    // Stimulus also fires this on keydown.space; stop the default page scroll.
    if (event && event.type === "keydown" && event.key === " ") event.preventDefault()
    if (this.element.querySelector("input")) return // already editing

    const currentText = this.displayTarget.textContent.trim()
    // Strip thousands separators, currency / unit suffixes, etc.
    // Keep only digits, decimal point, and a leading minus sign.
    const cleaned = currentText.replace(/[^\d.\-]/g, "")
    const currentValue = (currentText === this.blankValue || cleaned === "" || cleaned === "-") ? "" : cleaned

    const input = document.createElement("input")
    input.type  = "number"
    input.step  = this.stepValue
    input.min   = this.minValue
    input.value = currentValue
    input.className = "w-24 border border-blue-500 rounded px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-blue-300"
    input.dataset.action = "blur->cell-edit#save keydown.enter->cell-edit#save keydown.escape->cell-edit#cancel"

    this.displayTarget.classList.add("hidden")
    this.element.appendChild(input)
    input.focus()
    input.select()
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
    body.append(`product_variant[${this.fieldValue}]`, input.value)

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        body,
        headers: { "Accept": "text/vnd.turbo-stream.html" }
      })

      // If the session expired (or any other 30x), fetch silently follows
      // the redirect and returns a 200 HTML page — NOT a Turbo Stream.
      // Treating that as success would leave the row in a broken state.
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
