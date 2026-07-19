import { Controller } from "@hotwired/stimulus"

// Populates the channel create/edit form's product <select> by calling the
// live Raydo getProductList endpoint (LogisticsChannelsController#product_options).
// Selecting an option also mirrors its label into a hidden `product_shortname`
// field so we cache the display name alongside the Raydo `product_id`.
export default class extends Controller {
  static targets = [ "select", "shortname", "error" ]
  static values = { url: String, selected: String, errorMessage: String }

  connect() {
    this.load()
  }

  async load() {
    try {
      const res = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      const data = await res.json()
      if (!res.ok || data.error) throw new Error(data.error || "request failed")
      this.populate(data)
    } catch (e) {
      this.showError()
    }
  }

  populate(products) {
    this.selectTarget.innerHTML = ""

    if (!products.length) {
      this.showError()
      return
    }

    products.forEach((product) => {
      const option = document.createElement("option")
      option.value = product.product_id
      option.textContent = product.product_shortname
      option.dataset.shortname = product.product_shortname
      if (product.product_id === this.selectedValue) option.selected = true
      this.selectTarget.appendChild(option)
    })

    this.selectTarget.disabled = false
    this.sync()
  }

  sync() {
    if (!this.hasShortnameTarget) return

    const option = this.selectTarget.selectedOptions[0]
    this.shortnameTarget.value = option ? option.dataset.shortname : ""
  }

  showError() {
    this.selectTarget.innerHTML = ""
    this.selectTarget.disabled = true

    if (this.hasErrorTarget) {
      this.errorTarget.textContent = this.errorMessageValue
      this.errorTarget.classList.remove("hidden")
    }
  }
}
