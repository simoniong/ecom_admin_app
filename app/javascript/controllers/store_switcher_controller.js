import { Controller } from "@hotwired/stimulus"

// Navigates the current page to the selected option's URL (a GET that
// carries the new store_id plus the page's existing query params).
export default class extends Controller {
  switch(event) {
    const url = event.target.value
    if (url) window.location.href = url
  }
}
