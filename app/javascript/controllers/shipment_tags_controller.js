import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "title", "search", "tagList", "confirmBtn", "form", "idsContainer", "tagsContainer", "createOption"]
  static values = {
    availableTagsUrl: String,
    mode: { type: String, default: "add" },
    addedLabel: { type: String, default: "Added" },
    selectedLabel: { type: String, default: "Selected" },
    availableLabel: { type: String, default: "Available" },
    noTagsText: { type: String, default: "No tags yet." },
    noTagsFoundText: { type: String, default: "No tags found." },
    addTitle: { type: String, default: "Add tags" },
    deleteTitle: { type: String, default: "Delete tags" }
  }

  connect() {
    this.allTags = []
    this.selectedTags = new Set()
  }

  async open(event) {
    const mode = event.currentTarget.dataset.tagMode || "add"
    this.modeValue = mode
    this.selectedTags.clear()

    const url = event.currentTarget.dataset.url
    if (url && this.hasFormTarget) {
      this.formTarget.action = url
    }

    this.titleTarget.textContent = mode === "add" ? this.addTitleValue : this.deleteTitleValue

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
    if (!newTag) return

    if (!this.allTags.includes(newTag)) {
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

    const added = filtered.filter(t => this.selectedTags.has(t))
    const available = filtered.filter(t => !this.selectedTags.has(t))

    const container = this.tagListTarget
    container.innerHTML = ""

    if (added.length > 0) {
      container.appendChild(this.buildSection(
        this.modeValue === "add" ? this.addedLabelValue : this.selectedLabelValue,
        added, true
      ))
      const divider = document.createElement("div")
      divider.className = "border-t border-gray-200"
      container.appendChild(divider)
    }

    if (available.length > 0) {
      container.appendChild(this.buildSection(this.availableLabelValue, available, false))
    }

    if (filtered.length === 0) {
      const empty = document.createElement("div")
      empty.className = "py-8 text-center text-sm text-gray-500"
      empty.textContent = query ? this.noTagsFoundTextValue : this.noTagsTextValue
      container.appendChild(empty)
    }

    if (this.hasCreateOptionTarget) {
      const showCreate = this.modeValue === "add" && query && !this.allTags.some(t => t.toLowerCase() === query)
      this.createOptionTarget.classList.toggle("hidden", !showCreate)
      if (showCreate) {
        this.createOptionTarget.querySelector("[data-tag-name]").textContent = `"${this.searchTarget.value.trim()}"`
      }
    }
  }

  buildSection(title, tags, checked) {
    const section = document.createElement("div")
    section.className = "px-1 py-2"

    const heading = document.createElement("p")
    heading.className = "text-sm font-semibold text-gray-900 mb-2"
    heading.textContent = title
    section.appendChild(heading)

    tags.forEach(tag => {
      section.appendChild(this.buildTagCheckbox(tag, checked))
    })

    return section
  }

  buildTagCheckbox(tag, checked) {
    const label = document.createElement("label")
    label.className = "flex items-center gap-3 px-3 py-2 rounded-lg hover:bg-gray-50 cursor-pointer"

    const input = document.createElement("input")
    input.type = "checkbox"
    input.checked = checked
    input.dataset.action = "change->shipment-tags#toggleTag"
    input.dataset.tag = tag
    input.className = "rounded border-gray-300 text-blue-600 focus:ring-blue-500"

    const span = document.createElement("span")
    span.className = "text-sm text-gray-700"
    span.textContent = tag

    label.appendChild(input)
    label.appendChild(span)
    return label
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
