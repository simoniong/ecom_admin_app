import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

export default class extends Controller {
  static targets = ["lane"]

  connect() {
    this.laneTargets.forEach((lane) => {
      Sortable.create(lane, {
        group: "kanban",
        animation: 150,
        ghostClass: "opacity-50",
        dragClass: "shadow-lg",
        onEnd: (event) => this.handleDrop(event)
      })
    })
  }

  async handleDrop(event) {
    const ticketId = event.item.dataset.ticketId
    const newStatus = event.to.dataset.status
    const oldStatus = event.from.dataset.status
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    const positionIds = [...event.to.children].map(card => card.dataset.ticketId)
    const body = { ticket: { position_ids: positionIds } }

    if (newStatus !== oldStatus) {
      body.ticket.status = newStatus
    }

    try {
      const response = await fetch(`/tickets/${ticketId}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          "Accept": "application/json"
        },
        body: JSON.stringify(body)
      })

      if (!response.ok) {
        const data = await response.json()
        alert(data.error || "Operation failed")
        event.from.insertBefore(event.item, event.from.children[event.oldIndex])
      }
    } catch (error) {
      alert("Network error. Please try again.")
      event.from.insertBefore(event.item, event.from.children[event.oldIndex])
    }

    this.updateLaneCount(event.from)
    this.updateLaneCount(event.to)
  }

  updateLaneCount(lane) {
    const count = lane.querySelectorAll("[data-ticket-id]").length
    const header = lane.closest(".flex-col")?.querySelector("[data-lane-count]")
    if (header) header.textContent = count
  }
}
