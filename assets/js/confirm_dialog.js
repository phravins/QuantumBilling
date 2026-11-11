// In-app confirmation for every `data-confirm` element, in place of the
// browser's window.confirm.
//
// phoenix_html asks before it acts: its click handler dispatches a cancelable
// "phoenix.link.click" on the clicked element and, if that is cancelled, stops
// the click so neither LiveView (phx-click) nor a link or form sees it. This
// listener runs first (capture phase on window), cancels it, and asks in the
// root layout's #confirm-dialog instead. On confirm the element is clicked
// again and let through once, so whatever it does carries on unchanged.
//
// Optional attributes beside data-confirm:
//   data-confirm-title  heading (default: the message's first sentence)
//   data-confirm-label  confirm button text (default: title, text or aria-label)
//   data-confirm-tone   "danger" or "neutral" (default: guessed from the message)

const DANGER = /\b(delete|remove|revoke|bin|disconnect|archive|turn off|withdraw|reset|permanently)\b/i
const MAX_LABEL = 28

const confirmed = new WeakSet()
let pending = null

const firstSentence = message => {
  const match = message.match(/^(.+?[?.!])\s+([\s\S]+)$/)
  return match ? [match[1], match[2]] : [message, ""]
}

const shortText = value => {
  const text = (value || "").replace(/\s+/g, " ").trim()
  return text && text.length <= MAX_LABEL ? text : null
}

const labelFor = el =>
  el.dataset.confirmLabel ||
  shortText(el.getAttribute("title")) ||
  shortText(el.textContent) ||
  shortText(el.getAttribute("aria-label")) ||
  "Confirm"

const toneFor = (el, message) => {
  const tone = el.dataset.confirmTone
  if (tone === "danger" || tone === "neutral") return tone
  return DANGER.test(message) ? "danger" : "neutral"
}

// Click the element again; the capture listener lets this one click through.
const proceed = el => {
  if (!el.isConnected) return
  confirmed.add(el)
  try { el.click() } finally { confirmed.delete(el) }
}

const ask = (el, message) => {
  const dialog = document.getElementById("confirm-dialog")

  // No dialog on this page (or no <dialog> support): fall back to the browser.
  if (!dialog || typeof dialog.showModal !== "function") {
    if (window.confirm(message)) proceed(el)
    return
  }

  const [title, body] = el.dataset.confirmTitle
    ? [el.dataset.confirmTitle, message]
    : firstSentence(message)
  const tone = toneFor(el, message)
  const bodyEl = dialog.querySelector("#confirm-dialog-body")

  dialog.dataset.tone = tone
  dialog.querySelector("#confirm-dialog-title").textContent = title
  bodyEl.textContent = body
  bodyEl.hidden = body === ""
  dialog.querySelector("#confirm-dialog-ok").textContent = labelFor(el)

  pending = el
  dialog.returnValue = ""
  if (!dialog.open) dialog.showModal()

  // A destructive action starts on Cancel, so Enter alone never does harm.
  dialog.querySelector(tone === "danger" ? "#confirm-dialog-cancel" : "#confirm-dialog-ok").focus()
}

const bindDialog = () => {
  const dialog = document.getElementById("confirm-dialog")
  if (!dialog || dialog.dataset.bound) return
  dialog.dataset.bound = "true"

  dialog.querySelector("#confirm-dialog-ok").addEventListener("click", () => dialog.close("ok"))
  dialog.querySelector("#confirm-dialog-cancel").addEventListener("click", () => dialog.close("cancel"))

  // The dialog box fills its own area, so a click on the dialog itself is the backdrop.
  dialog.addEventListener("click", e => { if (e.target === dialog) dialog.close("cancel") })

  dialog.addEventListener("close", () => {
    const el = pending
    pending = null
    if (dialog.returnValue === "ok" && el) proceed(el)
  })
}

window.addEventListener("phoenix.link.click", e => {
  const el = e.target
  const message = el.getAttribute && el.getAttribute("data-confirm")
  if (!message) return

  // Either way phoenix_html's own window.confirm listener must not run.
  e.stopPropagation()
  if (confirmed.has(el)) return

  e.preventDefault()
  bindDialog()
  ask(el, message)
}, true)

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", bindDialog)
} else {
  bindDialog()
}
