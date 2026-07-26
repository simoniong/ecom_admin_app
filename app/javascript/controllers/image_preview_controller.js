import { Controller } from "@hotwired/stimulus"

// Hover preview for the packing list's SKU thumbnails.
//
// The popover is appended to document.body rather than next to the thumbnail
// because the list's table sits inside an overflow-x-auto container, which
// clips any absolutely positioned child. A fixed-position node on body escapes
// that clipping entirely.
//
// One node is reused for the whole page — a preview per thumbnail would leave
// dozens of hidden 400px images in the DOM.
export default class extends Controller {
  static values = { url: String }

  static PREVIEW_ID = "sku-image-preview"
  static SIZE = 400
  static GAP = 16

  show() {
    if (!this.urlValue) return

    const preview = this.#node()
    preview.src = this.urlValue
    preview.style.display = "block"
    this.#position(preview)
  }

  hide() {
    const preview = document.getElementById(this.constructor.PREVIEW_ID)
    if (preview) preview.style.display = "none"
  }

  // Leaving the page with a preview open would strand it on body.
  disconnect() {
    this.hide()
  }

  #node() {
    let preview = document.getElementById(this.constructor.PREVIEW_ID)
    if (preview) return preview

    preview = document.createElement("img")
    preview.id = this.constructor.PREVIEW_ID
    preview.alt = ""
    preview.style.position = "fixed"
    preview.style.zIndex = "60"
    preview.style.width = `${this.constructor.SIZE}px`
    preview.style.height = `${this.constructor.SIZE}px`
    preview.style.objectFit = "contain"
    preview.style.pointerEvents = "none"
    preview.style.background = "#fff"
    preview.style.border = "1px solid #e5e7eb"
    preview.style.borderRadius = "8px"
    preview.style.boxShadow = "0 10px 25px rgba(0,0,0,0.15)"
    document.body.appendChild(preview)
    return preview
  }

  // Prefer the right of the thumbnail, flip left when that would overflow the
  // viewport, and clamp vertically so the preview is never half off-screen.
  #position(preview) {
    const anchor = this.element.getBoundingClientRect()
    const size = this.constructor.SIZE
    const gap = this.constructor.GAP

    let left = anchor.right + gap
    if (left + size > window.innerWidth) left = anchor.left - size - gap
    if (left < gap) left = gap

    let top = anchor.top + anchor.height / 2 - size / 2
    if (top < gap) top = gap
    if (top + size > window.innerHeight - gap) top = window.innerHeight - size - gap

    preview.style.left = `${left}px`
    preview.style.top = `${top}px`
  }
}
