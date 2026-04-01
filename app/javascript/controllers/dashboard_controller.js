import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["rangeButton", "startDate", "endDate", "customForm"]

  selectRange(event) {
    this.rangeButtonTargets.forEach(btn => {
      btn.classList.remove("bg-gray-900", "text-white")
      btn.classList.add("text-gray-600", "hover:bg-gray-100")
    })
    event.currentTarget.classList.add("bg-gray-900", "text-white")
    event.currentTarget.classList.remove("text-gray-600", "hover:bg-gray-100")
  }

  submitCustomRange() {
    const start = this.startDateTarget.value
    const end = this.endDateTarget.value
    if (!start || !end) return

    // Deactivate preset buttons
    this.rangeButtonTargets.forEach(btn => {
      btn.classList.remove("bg-gray-900", "text-white")
      btn.classList.add("text-gray-600", "hover:bg-gray-100")
    })

    // Submit via Turbo Frame
    const url = new URL(window.location.href)
    url.searchParams.set("start_date", start)
    url.searchParams.set("end_date", end)
    url.searchParams.delete("range")

    const frame = document.getElementById("dashboard_metrics")
    if (frame) {
      frame.src = url.toString()
    }
  }
}
