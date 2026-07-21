import { Controller } from "@hotwired/stimulus"

// Minimal tab switcher for the package detail modal. Two tab strips (a
// vertical desktop sidebar and a horizontal mobile strip) both carry
// data-tabs-target="tab" and drive the SAME set of panels, so only one
// section (address/customs/logistics/note) is visible at a time regardless
// of which strip the user is looking at.
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { active: String }

  connect() {
    if (!this.activeValue && this.tabTargets[0]) {
      this.activeValue = this.tabTargets[0].dataset.tabsNameParam
    }
    this.render()
  }

  select(event) {
    this.activeValue = event.params.name
  }

  activeValueChanged() {
    this.render()
  }

  render() {
    this.tabTargets.forEach((tab) => {
      const isActive = tab.dataset.tabsNameParam === this.activeValue
      tab.classList.toggle("bg-gray-100", isActive)
      tab.classList.toggle("text-gray-900", isActive)
      tab.classList.toggle("text-gray-500", !isActive)
    })
    this.panelTargets.forEach((panel) => {
      panel.classList.toggle("hidden", panel.dataset.tabsNameParam !== this.activeValue)
    })
  }
}
