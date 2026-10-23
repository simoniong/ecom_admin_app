import { Controller } from "@hotwired/stimulus"

// Reloading the frame replaces its children, which disconnects this controller
// and connects a fresh one. The drawer's open state therefore cannot live on
// the instance — a poll would close the drawer every 5 seconds — so it lives
// here, outside any one controller's life. It holds the body the drawer was
// opened on: a poll leaves that body in place and so restores the drawer, while
// a Turbo visit swaps it and so leaves the drawer closed on the way back.
let openedOnBody = null

export default class extends Controller {
  static targets = ["drawer", "backdrop"]
  static values = {
    running: Boolean,
    interval: { type: Number, default: 5000 },
    url: String
  }

  connect() {
    if (openedOnBody === document.body) this.reveal()
    this.restartTimer()
  }

  disconnect() {
    this.stopTimer()
  }

  // Also fires on the re-rendered frame, so a sync that has finished stops the
  // timer and one that has started begins it.
  runningValueChanged() {
    this.restartTimer()
  }

  open() {
    openedOnBody = document.body
    this.reveal()
  }

  close() {
    openedOnBody = null
    this.drawerTarget.classList.add("hidden")
    this.backdropTarget.classList.add("hidden")
  }

  closeBackdrop(event) {
    if (event.target === this.backdropTarget) this.close()
  }

  reveal() {
    this.drawerTarget.classList.remove("hidden")
    this.backdropTarget.classList.remove("hidden")
  }

  restartTimer() {
    this.stopTimer()
    if (!this.runningValue) return

    this.pinFrameSource()
    this.timer = setInterval(() => {
      const frame = this.frame
      if (frame) frame.reload()
    }, this.intervalValue)
  }

  stopTimer() {
    if (!this.timer) return

    clearInterval(this.timer)
    this.timer = null
  }

  // reload() re-fetches the frame's src, and the dashboard renders the frame
  // without one so the first paint costs no second request. Pointing it at the
  // status endpoint here also undoes Turbo, which leaves src on the POST path
  // after the acknowledge button renders into the frame.
  pinFrameSource() {
    const frame = this.frame
    if (!frame || !this.hasUrlValue) return

    const current = new URL(frame.src || "", window.location.origin)
    const wanted = new URL(this.urlValue, window.location.origin)
    if (current.pathname !== wanted.pathname) frame.src = this.urlValue
  }

  get frame() {
    return this.element.closest("turbo-frame")
  }
}
