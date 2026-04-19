import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { fallbackUrl: String }

  back(event) {
    event.preventDefault()

    if (this.hasInAppHistory()) {
      history.back()
    } else if (this.fallbackUrlValue) {
      window.location.href = this.fallbackUrlValue
    }
  }

  hasInAppHistory() {
    if (history.length <= 1) return false

    const referrer = document.referrer
    if (!referrer) return false

    try {
      return new URL(referrer).origin === window.location.origin
    } catch {
      return false
    }
  }
}
