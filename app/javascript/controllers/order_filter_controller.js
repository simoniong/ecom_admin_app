import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["filterForm", "fromDate", "toDate", "rangeButton", "sortColumn", "sortDirection", "searchInput"]

  connect() {
    this.highlightMatchingRange()
  }

  submit() {
    this.filterFormTarget.requestSubmit()
  }

  selectRange(event) {
    const range = event.currentTarget.dataset.range
    const dates = this.computeRange(range)
    if (!dates) return

    this.fromDateTarget.value = this.formatDate(dates.from)
    this.toDateTarget.value = this.formatDate(dates.to)
    this.highlightRange(range)
    this.filterFormTarget.requestSubmit()
  }

  sortBy(event) {
    const column = event.currentTarget.dataset.sortColumn
    const currentCol = this.sortColumnTarget.value
    const currentDir = this.sortDirectionTarget.value

    if (column === currentCol) {
      this.sortDirectionTarget.value = currentDir === "asc" ? "desc" : "asc"
    } else {
      this.sortColumnTarget.value = column
      this.sortDirectionTarget.value = "desc"
    }

    this.filterFormTarget.requestSubmit()
  }

  // --- private helpers ---

  highlightMatchingRange() {
    const from = this.fromDateTarget.value
    const to = this.toDateTarget.value
    let matched = null

    for (const range of ["today", "yesterday", "this_week", "last_week"]) {
      const dates = this.computeRange(range)
      if (dates && this.formatDate(dates.from) === from && this.formatDate(dates.to) === to) {
        matched = range
        break
      }
    }

    this.highlightRange(matched)
  }

  highlightRange(activeRange) {
    this.rangeButtonTargets.forEach(btn => {
      const isActive = btn.dataset.range === activeRange
      btn.classList.toggle("bg-blue-600", isActive)
      btn.classList.toggle("text-white", isActive)
      btn.classList.toggle("border-blue-600", isActive)
      btn.classList.toggle("bg-gray-100", !isActive)
      btn.classList.toggle("text-gray-700", !isActive)
      btn.classList.toggle("border-gray-300", !isActive)
    })
  }

  computeRange(range) {
    const today = new Date()
    let from, to

    switch (range) {
      case "today":
        from = to = today
        break
      case "yesterday":
        from = to = this.addDays(today, -1)
        break
      case "this_week":
        from = this.startOfWeek(today)
        to = today
        break
      case "last_week":
        from = this.addDays(this.startOfWeek(today), -7)
        to = this.addDays(this.startOfWeek(today), -1)
        break
      default:
        return null
    }

    return { from, to }
  }

  addDays(date, days) {
    const result = new Date(date)
    result.setDate(result.getDate() + days)
    return result
  }

  startOfWeek(date) {
    const result = new Date(date)
    const day = result.getDay()
    const diff = day === 0 ? 6 : day - 1
    result.setDate(result.getDate() - diff)
    return result
  }

  formatDate(date) {
    const y = date.getFullYear()
    const m = String(date.getMonth() + 1).padStart(2, "0")
    const d = String(date.getDate()).padStart(2, "0")
    return `${y}-${m}-${d}`
  }
}
