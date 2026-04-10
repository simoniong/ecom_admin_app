import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["selectAll", "checkbox", "bar", "count"]

  connect() {
    this.updateState()
  }

  toggleAll() {
    const checked = this.selectAllTarget.checked
    this.checkboxTargets.forEach(cb => cb.checked = checked)
    this.updateState()
  }

  toggleOne() {
    const all = this.checkboxTargets
    const checkedCount = all.filter(cb => cb.checked).length
    this.selectAllTarget.checked = checkedCount === all.length
    this.selectAllTarget.indeterminate = checkedCount > 0 && checkedCount < all.length
    this.updateState()
  }

  updateState() {
    const selected = this.checkboxTargets.filter(cb => cb.checked)
    const hasSelection = selected.length > 0

    this.barTarget.classList.toggle("hidden", !hasSelection)
    this.countTarget.textContent = selected.length
  }

  copyTracking() {
    const lines = this.selectedData().map(d => {
      const datePart = d.lastEventAt ? this.formatDate(d.lastEventAt) : "N/A"
      const msgPart = d.latestEvent || "N/A"
      return `${d.trackingNumber}, 停更在${datePart}, 最后消息是: ${msgPart}`
    })
    this.copyToClipboard(lines.join("\n"))
  }

  copyTrackingSimple() {
    const lines = this.selectedData().map(d => {
      const datePart = d.lastEventAt ? this.formatDate(d.lastEventAt) : "N/A"
      return `${d.trackingNumber}, 停更在${datePart}`
    })
    this.copyToClipboard(lines.join("\n"))
  }

  selectedData() {
    return this.checkboxTargets
      .filter(cb => cb.checked)
      .map(cb => ({
        trackingNumber: cb.dataset.trackingNumber,
        lastEventAt: cb.dataset.lastEventAt,
        latestEvent: cb.dataset.latestEvent
      }))
  }

  formatDate(isoString) {
    const date = new Date(isoString)
    const month = date.getMonth() + 1
    const day = date.getDate()
    return `${month}月${day}日`
  }

  copyToClipboard(text) {
    navigator.clipboard.writeText(text).then(() => {
      this.flashCopied()
    })
  }

  flashCopied() {
    const flash = document.createElement("div")
    flash.textContent = "Copied!"
    flash.className = "fixed top-4 right-4 z-50 px-4 py-2 bg-gray-900 text-white text-sm rounded-lg shadow-lg transition-opacity duration-300"
    document.body.appendChild(flash)
    setTimeout(() => {
      flash.classList.add("opacity-0")
      setTimeout(() => flash.remove(), 300)
    }, 1500)
  }
}
