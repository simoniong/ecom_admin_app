import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "filterForm", "statusTab", "sortField", "sortDirection",
    "searchInput", "moreFilters", "sortDropdown"
  ]

  selectTab(event) {
    const status = event.currentTarget.dataset.status
    this.statusTabTarget.value = status
    this.filterFormTarget.requestSubmit()
  }

  submit() {
    this.filterFormTarget.requestSubmit()
  }

  submitOnEnter(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.filterFormTarget.requestSubmit()
    }
  }

  filterChanged() {
    this.filterFormTarget.requestSubmit()
  }

  toggleMoreFilters() {
    this.moreFiltersTarget.classList.toggle("hidden")
  }

  toggleSortDropdown() {
    this.sortDropdownTarget.classList.toggle("hidden")
  }

  selectSortField(event) {
    this.sortFieldTarget.value = event.currentTarget.dataset.sortField
    this.filterFormTarget.requestSubmit()
  }

  selectSortDirection(event) {
    this.sortDirectionTarget.value = event.currentTarget.dataset.sortDirection
    this.filterFormTarget.requestSubmit()
  }

  closeSortDropdown(event) {
    if (this.hasSortDropdownTarget && !this.sortDropdownTarget.contains(event.target) &&
        !event.target.closest("[data-action*='toggleSortDropdown']")) {
      this.sortDropdownTarget.classList.add("hidden")
    }
  }

  clearFilter(event) {
    const filterName = event.currentTarget.dataset.filterName
    const input = this.filterFormTarget.querySelector(`[name="${filterName}"]`)
    if (input) {
      input.value = ""
    }
    this.filterFormTarget.requestSubmit()
  }

  clearAllFilters() {
    const selects = this.filterFormTarget.querySelectorAll("select")
    selects.forEach(select => select.value = "")
    const searchInput = this.filterFormTarget.querySelector("[name='search']")
    if (searchInput) searchInput.value = ""
    this.statusTabTarget.value = "All"
    this.filterFormTarget.requestSubmit()
  }
}
