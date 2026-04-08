import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  switch(event) {
    const url = event.target.value
    const form = document.createElement("form")
    form.method = "POST"
    form.action = url

    const methodInput = document.createElement("input")
    methodInput.type = "hidden"
    methodInput.name = "_method"
    methodInput.value = "patch"
    form.appendChild(methodInput)

    const csrfInput = document.createElement("input")
    csrfInput.type = "hidden"
    csrfInput.name = "authenticity_token"
    csrfInput.value = document.querySelector('meta[name="csrf-token"]').content
    form.appendChild(csrfInput)

    document.body.appendChild(form)
    form.submit()
  }
}
