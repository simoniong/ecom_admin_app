import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "title", "search", "tagList", "confirmBtn", "form", "idsContainer", "tagsContainer", "createOption"]
  static values = {
    availableTagsUrl: String,
    mode: { type: String, default: "add" } // "add" or "delete"
  }

  connect() {
    this.allTags = []
    this.selectedTags = new Set()
  }

  async open(event) {
    const mode = event.currentTarget.dataset.tagMode || "add"
    this.modeValue = mode
    this.selectedTags.clear()

    // Set form action URL if provided on the trigger button
    const url = event.currentTarget.dataset.url
    if (url && this.hasFormTarget) {
      this.formTarget.action = url
    }

    this.titleTarget.textContent = mode === "add"
      ? this.element.dataset.addTitle
      : this.element.dataset.deleteTitle

    if (this.hasSearchTarget) {
      this.searchTarget.value = ""
    }

    if (mode === "add") {
      await this.fetchAvailableTags()
    } else {
      this.loadSelectedShipmentTags()
    }

    this.render()
    this.modalTarget.classList.remove("hidden")
    this.updateConfirmBtn()
  }

  close() {
    this.modalTarget.classList.add("hidden")
  }

  async fetchAvailableTags() {
    try {
      const response = await fetch(this.availableTagsUrlValue)
      this.allTags = await response.json()
    } catch {
      this.allTags = []
    }
  }

  loadSelectedShipmentTags() {
    // Collect all tags from selected shipments (passed via data attribute)
    const tagsStr = this.element.dataset.selectedShipmentTags || "[]"
    try {
      this.allTags = JSON.parse(tagsStr)
    } catch {
      this.allTags = []
    }
  }

  search() {
    this.render()
  }

  clearSearch() {
    this.searchTarget.value = ""
    this.render()
  }

  toggleTag(event) {
    const tag = event.currentTarget.dataset.tag
    if (this.selectedTags.has(tag)) {
      this.selectedTags.delete(tag)
    } else {
      this.selectedTags.add(tag)
    }
    this.render()
    this.updateConfirmBtn()
  }

  createTag() {
    const newTag = this.searchTarget.value.trim()
    if (newTag && !this.allTags.includes(newTag)) {
      this.allTags.unshift(newTag)
    }
    this.selectedTags.add(newTag)
    this.searchTarget.value = ""
    this.render()
    this.updateConfirmBtn()
  }

  render() {
    const query = (this.hasSearchTarget ? this.searchTarget.value : "").trim().toLowerCase()
    const filtered = this.allTags.filter(t => t.toLowerCase().includes(query))

    // Split into added (selected) and available
    const added = filtered.filter(t => this.selectedTags.has(t))
    const available = filtered.filter(t => !this.selectedTags.has(t))

    let html = ""

    if (added.length > 0) {
      html += `<div class="px-1 py-2"><p class="text-sm font-semibold text-gray-900 mb-2">${this.modeValue === "add" ? "Added" : "Selected"}</p>`
      added.forEach(tag => {
        html += this.tagCheckboxHtml(tag, true)
      })
      html += `</div><div class="border-t border-gray-200"></div>`
    }

    if (available.length > 0) {
      html += `<div class="px-1 py-2"><p class="text-sm font-semibold text-gray-900 mb-2">Available</p>`
      available.forEach(tag => {
        html += this.tagCheckboxHtml(tag, false)
      })
      html += `</div>`
    }

    if (filtered.length === 0 && !query) {
      html = `<div class="py-8 text-center text-sm text-gray-500">${this.element.dataset.noTagsText || "No tags yet."}</div>`
    } else if (filtered.length === 0 && query) {
      html = `<div class="py-8 text-center text-sm text-gray-500">${this.element.dataset.noTagsFoundText || "No tags found."}</div>`
    }

    this.tagListTarget.innerHTML = html

    // Show/hide create option for add mode
    if (this.hasCreateOptionTarget) {
      const showCreate = this.modeValue === "add" && query && !this.allTags.some(t => t.toLowerCase() === query)
      this.createOptionTarget.classList.toggle("hidden", !showCreate)
      if (showCreate) {
        this.createOptionTarget.querySelector("[data-tag-name]").textContent = `"${this.searchTarget.value.trim()}"`
      }
    }
  }

  tagCheckboxHtml(tag, checked) {
    const escapedTag = tag.replace(/"/g, "&quot;").replace(/</g, "&lt;")
    return `
      <label class="flex items-center gap-3 px-3 py-2 rounded-lg hover:bg-gray-50 cursor-pointer">
        <input type="checkbox" ${checked ? "checked" : ""}
               data-action="change->shipment-tags#toggleTag"
               data-tag="${escapedTag}"
               class="rounded border-gray-300 text-blue-600 focus:ring-blue-500">
        <span class="text-sm text-gray-700">${escapedTag}</span>
      </label>
    `
  }

  updateConfirmBtn() {
    if (this.hasConfirmBtnTarget) {
      const hasSelection = this.selectedTags.size > 0
      this.confirmBtnTarget.disabled = !hasSelection
      this.confirmBtnTarget.classList.toggle("opacity-50", !hasSelection)
      this.confirmBtnTarget.classList.toggle("cursor-not-allowed", !hasSelection)
    }
  }

  confirm() {
    if (this.selectedTags.size === 0) return

    const form = this.formTarget
    // Clear previous inputs
    this.tagsContainerTarget.innerHTML = ""

    this.selectedTags.forEach(tag => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "tags[]"
      input.value = tag
      this.tagsContainerTarget.appendChild(input)
    })

    form.submit()
    this.close()
  }
}
