import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["selectAll", "checkbox", "bar", "count", "archiveForm"]
  static values = { copiedText: { type: String, default: "Copied!" } }

  connect() {
    this.updateState()
  }

  toggleAll() {
    const checked = this.selectAllTarget.checked
    this.selectAllTarget.indeterminate = false
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
      const datePart = d.lastEventDate || "N/A"
      const msgPart = d.latestEvent || "N/A"
      return `${d.trackingNumber}, 停更在${datePart}, 最后消息是: ${msgPart}`
    })
    this.copyToClipboard(lines.join("\n"))
  }

  copyTrackingSimple() {
    const lines = this.selectedData().map(d => {
      const datePart = d.lastEventDate || "N/A"
      return `${d.trackingNumber}, 停更在${datePart}`
    })
    this.copyToClipboard(lines.join("\n"))
  }

  selectedData() {
    return this.checkboxTargets
      .filter(cb => cb.checked)
      .map(cb => ({
        id: cb.dataset.fulfillmentId,
        trackingNumber: cb.dataset.trackingNumber,
        lastEventDate: cb.dataset.lastEventDate,
        latestEvent: cb.dataset.latestEvent
      }))
  }

  submitBulkAction(event) {
    const form = this.archiveFormTarget
    const url = event.currentTarget.dataset.url

    form.action = url
    form.innerHTML = ""

    // Add CSRF token
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    if (csrfToken) {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "authenticity_token"
      input.value = csrfToken
      form.appendChild(input)
    }

    // Add selected IDs
    this.selectedData().forEach(d => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "ids[]"
      input.value = d.id
      form.appendChild(input)
    })

    form.submit()
  }

  copyToClipboard(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(() => {
        this.flashCopied()
      }).catch(() => {
        this.fallbackCopy(text)
      })
    } else {
      this.fallbackCopy(text)
    }
  }

  fallbackCopy(text) {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.select()
    document.execCommand("copy")
    textarea.remove()
    this.flashCopied()
  }

  flashCopied() {
    const flash = document.createElement("div")
    flash.textContent = this.copiedTextValue
    flash.setAttribute("role", "status")
    flash.setAttribute("aria-live", "polite")
    flash.className = "fixed top-4 right-4 z-50 px-4 py-2 bg-gray-900 text-white text-sm rounded-lg shadow-lg transition-opacity duration-300"
    document.body.appendChild(flash)
    setTimeout(() => {
      flash.classList.add("opacity-0")
      setTimeout(() => flash.remove(), 300)
    }, 1500)
  }
}
