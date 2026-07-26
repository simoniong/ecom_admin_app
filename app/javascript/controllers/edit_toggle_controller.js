import { Controller } from "@hotwired/stimulus"

// Generic read-view/edit-form toggle for a modal section (e.g. the package
// detail modal's address section). Two targets, mutually exclusive:
// "view" (read-only markup, shown by default) and "form" (edit form,
// starts hidden via the "hidden" class in the markup). edit() swaps to the
// form; cancel() swaps back without submitting anything.
//
// Deliberately local/stateless (no server round-trip to open the form) —
// only the actual save (the form's own turbo_frame submission) hits the
// server. A fresh turbo_stream.replace of the whole section (see
// packages/update_address.turbo_stream.erb) re-renders this controller's
// root element from scratch, which naturally resets back to the "view"
// state on every save.
export default class extends Controller {
  static targets = ["view", "form"]

  edit() {
    this.viewTarget.classList.add("hidden")
    this.formTarget.classList.remove("hidden")
  }

  cancel() {
    this.formTarget.classList.add("hidden")
    this.viewTarget.classList.remove("hidden")
  }
}
