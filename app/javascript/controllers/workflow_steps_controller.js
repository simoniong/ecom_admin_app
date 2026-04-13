import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "addStepArea"]
  static values = { createUrl: String }

  toggleMenu() {
    this.menuTarget.classList.toggle("hidden")
  }

  addStep(event) {
    const stepType = event.currentTarget.dataset.stepType
    this.menuTarget.classList.add("hidden")

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this.createUrlValue, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": token,
        "Accept": "text/vnd.turbo-stream.html"
      },
      body: `step_type=${encodeURIComponent(stepType)}`
    })
    .then(response => response.text())
    .then(html => Turbo.renderStreamMessage(html))
  }

  // Close menu when clicking outside
  disconnect() {
    this._outsideClick && document.removeEventListener("click", this._outsideClick)
  }

  connect() {
    this._outsideClick = (event) => {
      if (this.hasMenuTarget && !this.addStepAreaTarget.contains(event.target)) {
        this.menuTarget.classList.add("hidden")
      }
    }
    document.addEventListener("click", this._outsideClick)
  }
}
