// We import the CSS which is extracted to its own file by esbuild.
// Remove this line if you add a your own CSS build pipeline (e.g postcss).
//
// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "./vendor/some-package.js"
//
// Alternatively, you can `npm install some-package` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "topbar"
import Alpine from "alpinejs"

window.Alpine = Alpine
Alpine.start()

let Hooks = {}

// Camera barcode scanner for the cashier. Uses the native BarcodeDetector API
// (Android Chrome / recent desktop Chrome). On detection it pushes a "scan"
// event with the decoded value, reusing the same server handler as the text box.
// Requires a secure context (https) or localhost to access the camera.
Hooks.BarcodeScanner = {
  mounted() {
    this.active = true
    this.lastCode = null
    this.lastAt = 0

    if (!("BarcodeDetector" in window)) {
      this.pushEvent("camera_unsupported", {})
      return
    }

    this.detector = new window.BarcodeDetector({
      formats: ["ean_13", "ean_8", "upc_a", "upc_e", "code_128", "code_39", "itf", "qr_code"]
    })

    navigator.mediaDevices
      .getUserMedia({ video: { facingMode: "environment" } })
      .then((stream) => {
        this.stream = stream
        this.el.srcObject = stream
        this.el.setAttribute("playsinline", "true")
        this.el.play()
        this.tick()
      })
      .catch((err) => this.pushEvent("camera_error", { message: String(err) }))
  },

  tick() {
    if (!this.active || !this.detector) return

    this.detector
      .detect(this.el)
      .then((codes) => {
        if (codes && codes.length) {
          const code = codes[0].rawValue
          const now = Date.now()
          // Debounce the same code for 1.5s so one item isn't added repeatedly.
          if (code && (code !== this.lastCode || now - this.lastAt > 1500)) {
            this.lastCode = code
            this.lastAt = now
            this.pushEvent("scan", { q: code })
          }
        }
      })
      .catch(() => {})
      .finally(() => {
        if (this.active) setTimeout(() => this.tick(), 350)
      })
  },

  destroyed() {
    this.active = false
    if (this.stream) this.stream.getTracks().forEach((t) => t.stop())
  }
}

// Camera barcode scanner for an input field (e.g. the product form). On a single
// detection it fills the target <input> (data-target=input id), notifies LiveView
// via an "input" event, then auto-closes by clicking the toggle button.
Hooks.BarcodeInput = {
  mounted() {
    this.active = true
    const input = document.getElementById(this.el.dataset.target)
    const status = this.el.parentElement.querySelector("[data-scan-status]")
    const setStatus = (t) => { if (status) status.textContent = t }

    if (!("BarcodeDetector" in window)) {
      setStatus("Camera scanning isn't supported on this browser.")
      return
    }

    this.detector = new window.BarcodeDetector({
      formats: ["ean_13", "ean_8", "upc_a", "upc_e", "code_128", "code_39", "itf", "qr_code"]
    })

    navigator.mediaDevices
      .getUserMedia({ video: { facingMode: "environment" } })
      .then((stream) => {
        this.stream = stream
        this.el.srcObject = stream
        this.el.setAttribute("playsinline", "true")
        this.el.play()
        this.tick(input, setStatus)
      })
      .catch((err) => setStatus("Could not start the camera: " + err))
  },

  tick(input, setStatus) {
    if (!this.active || !this.detector) return

    this.detector
      .detect(this.el)
      .then((codes) => {
        if (codes && codes.length && codes[0].rawValue) {
          const code = codes[0].rawValue
          if (input) {
            input.value = code
            input.dispatchEvent(new Event("input", { bubbles: true }))
          }
          setStatus("Scanned: " + code)
          this.active = false
          if (this.stream) this.stream.getTracks().forEach((t) => t.stop())
          const toggle = document.getElementById("barcode-scan-toggle")
          if (toggle) toggle.click()
        }
      })
      .catch(() => {})
      .finally(() => {
        if (this.active) setTimeout(() => this.tick(input, setStatus), 350)
      })
  },

  destroyed() {
    this.active = false
    if (this.stream) this.stream.getTracks().forEach((t) => t.stop())
  }
}

// Short "beep" feedback when an item is added/scanned at the cashier.
// Generated with the Web Audio API (no audio file needed).
Hooks.Beeper = {
  mounted() {
    this.handleEvent("beep", () => this.beep())
  },
  beep() {
    try {
      this.ctx = this.ctx || new (window.AudioContext || window.webkitAudioContext)()
      if (this.ctx.state === "suspended") this.ctx.resume()
      const osc = this.ctx.createOscillator()
      const gain = this.ctx.createGain()
      osc.connect(gain)
      gain.connect(this.ctx.destination)
      osc.type = "square"
      osc.frequency.value = 880
      gain.gain.setValueAtTime(0.2, this.ctx.currentTime)
      gain.gain.exponentialRampToValueAtTime(0.001, this.ctx.currentTime + 0.15)
      osc.start()
      osc.stop(this.ctx.currentTime + 0.15)
    } catch (e) {
      // ignore (e.g. autoplay policy before any user gesture)
    }
  }
}

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute('content')

let liveSocket = new LiveSocket('/live', Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken },
  dom: {
    onBeforeElUpdated(from, to) {
      if (from._x_dataStack) {
        window.Alpine.clone(from, to);
      }
    }
  }
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", info => topbar.show())
window.addEventListener("phx:page-loading-stop", info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
