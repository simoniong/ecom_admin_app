import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container", "template"]

  connect() {
    this.disableUsedCountries()
  }

  countryChanged() {
    this.disableUsedCountries()
  }

  add() {
    const content = this.templateTarget.innerHTML
    this.containerTarget.insertAdjacentHTML("beforeend", content)
    this.disableUsedCountries()
  }

  remove(event) {
    event.target.closest("[data-threshold-row]").remove()
    this.disableUsedCountries()
  }

  // Disable already-selected countries in all sibling selects
  disableUsedCountries() {
    const rows = this.containerTarget.querySelectorAll("[data-threshold-row]")
    const selects = Array.from(rows).map(row => row.querySelector("select[name$='[country]']")).filter(Boolean)

    // Collect all selected values
    const used = new Set(selects.map(s => s.value).filter(v => v !== ""))

    selects.forEach(select => {
      const currentValue = select.value
      select.querySelectorAll("option").forEach(option => {
        if (option.value === "" || option.value === currentValue) {
          option.disabled = false
        } else {
          option.disabled = used.has(option.value)
        }
      })
    })
  }
}
