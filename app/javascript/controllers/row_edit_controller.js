import { Controller } from "@hotwired/stimulus"

// Submits every field on a table row together in a single PATCH, so a
// server-side "required-together" validation (the customs page's :customs
// context — see ProductVariant::CUSTOMS_REQUIRED) is evaluated once against
// the whole row instead of once per field.
//
// Deliberately NOT a literal nested <form>: this controller's row (see
// app/views/product_customs/_row.html.erb) renders inside the bulk-select
// page's outer `form_with` (app/views/product_customs/index.html.erb), which
// wraps the entire <table> so checkbox selections serialize natively for
// POST /product_variants/bulk_update_customs. HTML forbids nested <form>
// elements — a nested <form> start tag would be silently dropped by the
// browser's parser and its inputs merged into the outer bulk form, so
// clicking "Save" would submit to the wrong endpoint entirely. This
// controller performs the functional equivalent of a per-row form submit
// (one fetch, every field, one Turbo Stream response) with no <form>
// element involved — mirroring the existing fetch-based approach in
// cell_edit_controller.js, just for several fields at once instead of one.
//
// Markup:
//   <tr data-controller="row-edit"
//       data-row-edit-url-value="/product_variants/123?context=customs">
//     <td><input name="product_variant[customs_name_zh]" data-row-edit-target="field" ...></td>
//     ...
//     <td><button type="button" data-action="click->row-edit#save">Save</button></td>
//   </tr>
//
// Server must respond with a Turbo Stream that replaces the entire row,
// whether the save succeeds or fails validation (see
// app/views/product_variants/update.turbo_stream.erb and
// ProductVariantsController#update) — the same stream template renders the
// row either way, so it can show inline validation errors on failure.
export default class extends Controller {
  static targets = ["field"]
  static values  = { url: String }

  async save(event) {
    event.preventDefault()

    const button = event.currentTarget
    if (button.dataset.saving === "1") return
    button.dataset.saving = "1"
    button.disabled = true

    const body = new FormData()
    body.append("authenticity_token", document.querySelector('meta[name="csrf-token"]')?.content ?? "")
    body.append("_method", "patch")
    this.fieldTargets.forEach(input => body.append(input.name, input.value))

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
      if (contentType.includes("turbo-stream")) {
        // The same stream template renders the row on both success (200)
        // and validation failure (422), so apply it either way — a failed
        // save re-renders the row with the submitted values plus inline
        // errors instead of silently reverting.
        const text = await response.text()
        window.Turbo.renderStreamMessage(text)
        return
      }

      button.dataset.saving = ""
      button.disabled = false
    } catch (e) {
      button.dataset.saving = ""
      button.disabled = false
    }
  }
}
