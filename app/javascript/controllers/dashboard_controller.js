import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["rangeButton"]

  selectRange(event) {
    this.rangeButtonTargets.forEach(btn => {
      btn.classList.remove("bg-gray-900", "text-white")
      btn.classList.add("text-gray-600", "hover:bg-gray-100")
    })
    event.currentTarget.classList.add("bg-gray-900", "text-white")
    event.currentTarget.classList.remove("text-gray-600", "hover:bg-gray-100")
  }
}
