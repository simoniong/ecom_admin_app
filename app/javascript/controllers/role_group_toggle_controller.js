import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["role", "groupField", "permissionsField"]

  connect() {
    this.toggle()
  }

  toggle() {
    const isOwner = this.roleTarget.value === "owner"
    if (this.hasGroupFieldTarget) {
      this.groupFieldTarget.classList.toggle("hidden", isOwner)
    }
    if (this.hasPermissionsFieldTarget) {
      this.permissionsFieldTarget.classList.toggle("hidden", isOwner)
    }
  }
}
