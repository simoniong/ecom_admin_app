import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dayOfWeek"]

  toggle(event) {
    const isWeekly = event.target.value === "every_week"
    this.dayOfWeekTarget.classList.toggle("hidden", !isWeekly)
  }
}
