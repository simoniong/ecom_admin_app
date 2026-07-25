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
