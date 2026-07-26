import { Controller } from "@hotwired/stimulus"

// Wraps the "package-modal" turbo-frame. The frame link click (data-turbo-frame
// on the package_code link) fetches GET package_path and swaps content into the
// frame; that swap fires a window-level "turbo:frame-load" event, which is
// wired (in the view) to open() here. open() guards on the frame actually
// having content so a load of any OTHER frame on the page, or an empty/failed
// load, never pops the dialog open spuriously.
export default class extends Controller {
  static targets = ["dialog", "backdrop"]

  connect() {
    this._esc = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("keydown", this._esc)
  }

  disconnect() {
    document.removeEventListener("keydown", this._esc)
  }

  open(event) {
    const frame = document.getElementById("package-modal")
    if (!frame || frame.children.length === 0) return
    if (event?.target && event.target !== frame) return

    this.element.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
  }

  close() {
    this.element.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
    const frame = document.getElementById("package-modal")
    if (frame) frame.innerHTML = ""
  }

  backdropClick(event) {
    if (event.target === this.backdropTarget) this.close()
  }
}
