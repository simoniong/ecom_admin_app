import { Controller } from "@hotwired/stimulus"

// Populates this <select> by cloning <option>s out of a shared <template>
// rendered once elsewhere on the page, instead of the server writing the
// full option list into every row's markup.
//
// Used by the unmatched-parcels assign dropdown: with hundreds of named
// orders and dozens of unmatched-parcel rows on a single page, rendering
// `options_from_collection_for_select` once per row made page weight scale
// as rows × orders (measured 127 KB for 300 orders × 5 rows; a full month at
// 434 orders/year would run into multiple MB). The <template> is rendered
// once regardless of row count, so the HTML response stays flat while every
// row's <select> still ends up with the complete, unfiltered order list.
export default class extends Controller {
  static targets = ["select"]
  static values = { template: String }

  connect() {
    const template = document.getElementById(this.templateValue)
    if (!template) return

    this.selectTarget.append(template.content.cloneNode(true))
  }
}
