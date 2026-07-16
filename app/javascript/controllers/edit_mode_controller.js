import { Controller } from "@hotwired/stimulus"

// Gates the /parcels orders-tab's inline edit controls (the cost input +
// save + delete on each parcel row) behind a single page-level "編輯模式"
// checkbox, hidden by default.
//
// Deliberately does NOT walk the DOM hiding/showing individual elements.
// Turbo Stream replaces one parcel row at a time after a save (see
// app/views/parcels/update.turbo_stream.erb), and a freshly-inserted row's
// edit controls need to already be in the right state with no JS re-applying
// anything to them. So the only thing this controller does is toggle one
// class on its own root element; actual visibility is driven by a plain CSS
// descendant selector (see app/assets/tailwind/application.css:
// ".parcels-editing .parcels-edit-col") that applies to any matching
// descendant automatically, including ones that don't exist yet.
export default class extends Controller {
  static classes = ["editing"]

  toggle(event) {
    this.element.classList.toggle(this.editingClass, event.target.checked)
  }
}
