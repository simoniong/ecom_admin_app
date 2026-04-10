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
    if (filterName === "tags[]") {
      this.clearTagFilter()
      return
    }
    const input = this.filterFormTarget.querySelector(`[name="${filterName}"]`)
    if (input) {
      input.value = ""
    }
    this.filterFormTarget.requestSubmit()
  }

  clearTagFilter() {
    this.filterFormTarget.querySelectorAll("input[name='tags[]']").forEach(cb => cb.checked = false)
    this.filterFormTarget.requestSubmit()
  }

  clearAllFilters() {
    this.filterFormTarget.querySelectorAll("select").forEach(s => s.value = "")
    this.filterFormTarget.querySelectorAll("input[type='text'], input[type='date'], input[type='number']").forEach(i => i.value = "")
    this.filterFormTarget.querySelectorAll("input[type='checkbox'][name='tags[]']").forEach(cb => cb.checked = false)
    this.statusTabTarget.value = "All"
    this.filterFormTarget.requestSubmit()
  }
}
