import { Controller } from "@hotwired/stimulus"

// Drives the split dialog: open/close, add/remove box columns, and live
// recompute of per-item remainder (box 1), per-box empties, and submit-enabled.
// Box inputs are named `allocations[<lineItemId>][]`; appended in the same box
// order across every row, so each item's submitted array aligns by box index.
export default class extends Controller {
  static targets = [
    "dialog", "form", "headerRow", "row", "remainder", "submit",
    "headerCellTemplate", "cellTemplate", "boxLabel", "input"
  ]

  connect() { this.boxCount = 0 }

  open() { this.dialogTarget.classList.remove("hidden"); if (this.boxCount === 0) this.addBox() }
  close() { this.dialogTarget.classList.add("hidden") }

  addBox() {
    this.boxCount += 1
    const idx = this.boxCount

    const header = this.headerCellTemplateTarget.content.cloneNode(true)
    header.querySelector("[data-split-target='boxLabel']").textContent =
      this.boxLabelText(idx)
    this.headerRowTarget.appendChild(header)

    const lineItemIds = []
    this.rowTargets.forEach((row) => {
      const cell = this.cellTemplateTarget.content.cloneNode(true)
      const input = cell.querySelector("input")
      input.name = `allocations[${row.dataset.lineItemId}][]`
      input.max = row.dataset.shippable
      row.appendChild(cell)
      lineItemIds.push(row.dataset.lineItemId)
    })
    this.recompute()
  }

  removeBox(event) {
    const th = event.currentTarget.closest("th")
    const cellIndex = Array.from(this.headerRowTarget.children).indexOf(th)
    th.remove()
    this.rowTargets.forEach((row) => {
      const cell = row.children[cellIndex]
      if (cell) cell.remove()
    })
    this.boxCount -= 1
    this.relabel()
    this.recompute()
  }

  relabel() {
    // header box labels start at column index 3 (after product/total/remainder)
    this.boxLabelTargets.forEach((label, i) => {
      label.textContent = this.boxLabelText(i + 1)
    })
  }

  boxLabelText(n) { return `${this.data.get("boxWord") || "包裹"}${n + 1}` }

  recompute() {
    let anyBoxEmpty = false
    let sourceRemainderTotal = 0
    let overAllocated = false

    // per-box totals
    const boxTotals = new Array(this.boxCount).fill(0)

    this.rowTargets.forEach((row, rowIdx) => {
      const shippable = parseInt(row.dataset.shippable, 10) || 0
      const inputs = row.querySelectorAll("input[data-split-target='input']")
      let moved = 0
      inputs.forEach((input, boxIdx) => {
        const v = parseInt(input.value, 10) || 0
        moved += v
        boxTotals[boxIdx] = (boxTotals[boxIdx] || 0) + v
      })
      const remainder = shippable - moved
      if (remainder < 0) overAllocated = true
      sourceRemainderTotal += Math.max(remainder, 0)
      this.remainderTargets[rowIdx].textContent = remainder
      this.remainderTargets[rowIdx].classList.toggle("text-red-600", remainder < 0)
    })

    boxTotals.forEach((t) => { if (t <= 0) anyBoxEmpty = true })

    const valid =
      this.boxCount > 0 && !anyBoxEmpty && !overAllocated && sourceRemainderTotal > 0
    this.submitTarget.disabled = !valid
  }
}
