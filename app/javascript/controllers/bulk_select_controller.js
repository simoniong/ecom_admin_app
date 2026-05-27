import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["bar", "count", "rowCheckbox", "pageToggle"]
  static values  = {
    matchingUrl: String,
    storeId:     String,
    search:      String,
    total:       Number
  }

  connect() { this.refresh() }

  rowChanged() { this.refresh() }

  togglePage(event) {
    const checked = event.target.checked
    this.rowCheckboxTargets.forEach(cb => { cb.checked = checked })
    this.refresh()
  }

  clear() {
    this.rowCheckboxTargets.forEach(cb => { cb.checked = false })
    this.element.querySelectorAll('input[name="variant_ids[]"][type=hidden]').forEach(el => el.remove())
    this.refresh()
  }

  async selectAllMatching() {
    const url = `${this.matchingUrlValue}?store_id=${this.storeIdValue}&search=${encodeURIComponent(this.searchValue)}`
    const res = await fetch(url, { headers: { "Accept": "application/json" } })
    const { ids } = await res.json()
    this.clear()
    ids.forEach(id => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "variant_ids[]"
      input.value = id
      this.element.appendChild(input)
    })
    this.refresh()
  }

  refresh() {
    const visible = this.rowCheckboxTargets.filter(cb => cb.checked).length
    const hidden  = this.element.querySelectorAll('input[name="variant_ids[]"][type=hidden]').length
    const total = visible + hidden
    if (this.hasCountTarget) this.countTarget.textContent = total
    if (this.hasBarTarget)   this.barTarget.classList.toggle("hidden", total === 0)
  }
}
