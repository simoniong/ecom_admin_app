// Custom Turbo Stream actions. Turbo silently ignores an action it does not
// know, so a missing registration here shows up as "the server responded but
// nothing happened" — the system specs assert the visible outcome for exactly
// that reason.

// Closes the package detail modal from a server response. The modal's own
// Stimulus controller owns the hiding (it also clears the frame), so this only
// announces the intent and lets that controller do the work.
Turbo.StreamActions.dismiss_modal = function () {
  window.dispatchEvent(new CustomEvent("modal:dismiss"))
}

// Full-page Turbo Drive visit driven by the server, for a response with no
// in-page target to update — e.g. a split submitted from the standalone
// /packages/:id page, which has no list row to fold into and no
// modal:dismiss listener (see packages/show.html.erb and
// split.turbo_stream.erb). The URL travels as a data attribute rather than
// the stream's `target` (a dom id), since there is no element to target.
Turbo.StreamActions.visit = function () {
  Turbo.visit(this.getAttribute("data-url"))
}
