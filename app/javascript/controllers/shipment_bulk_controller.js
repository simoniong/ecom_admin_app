import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["selectAll", "checkbox", "bar", "count", "archiveForm", "exportButton"]
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

    if (this.hasBarTarget) {
      this.barTarget.classList.toggle("hidden", !hasSelection)
    }
    if (this.hasCountTarget) {
      this.countTarget.textContent = selected.length
    }
    if (this.hasExportButtonTarget) {
      this.exportButtonTarget.classList.toggle("hidden", !hasSelection)
    }
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

  openTagModal(event) {
    const mode = event.currentTarget.dataset.tagMode
    const tagsController = this.application.getControllerForElementAndIdentifier(
      document.querySelector("[data-controller='shipment-tags']"),
      "shipment-tags"
    )
    if (!tagsController) return

    // Set form action URL
    const url = event.currentTarget.dataset.url
    tagsController.formTarget.action = url

    // Populate IDs
    tagsController.idsContainerTarget.innerHTML = ""
    this.selectedData().forEach(d => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "ids[]"
      input.value = d.id
      tagsController.idsContainerTarget.appendChild(input)
    })

    // For delete mode, collect tags from selected shipments
    if (mode === "delete") {
      const allTags = this.checkboxTargets
        .filter(cb => cb.checked)
        .flatMap(cb => JSON.parse(cb.dataset.tags || "[]"))
      const uniqueTags = [...new Set(allTags)].sort()
      tagsController.element.dataset.selectedShipmentTags = JSON.stringify(uniqueTags)
    }

    // Trigger open on the tags controller
    tagsController.open(event)
  }

  exportExcel(event) {
    const url = event.currentTarget.dataset.url
    const form = document.createElement("form")
    form.method = "POST"
    form.action = url
    form.style.display = "none"

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    if (csrfToken) {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "authenticity_token"
      input.value = csrfToken
      form.appendChild(input)
    }

    this.selectedData().forEach(d => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "ids[]"
      input.value = d.id
      form.appendChild(input)
    })

    document.body.appendChild(form)
    form.submit()
    form.remove()
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
