// Visit counts for this website, and only this website: the app collects
// nothing. PostHog, self-hosted script (posthog-js 1.435.8 no-external,
// Apache-2.0 AND MIT, from npm), reporting through same-origin /ingest
// (worker.js — the visitor's IP is not forwarded). No cookies: sessionStorage,
// cleared when the tab closes. No session recording, no surveys, no remote
// scripts. Events follow the shared Novabox spec (product / surface / site_lang,
// download_click with placement).
(function () {
  if (!window.posthog || typeof window.posthog.init !== 'function') return
  var ph = window.posthog
  ph.init('phc_oBVmMMHr9AfgqhS9kvsA8yoGMhyAVvisbcAtxZMkkXYp', {
    api_host: '/ingest',
    ui_host: 'https://us.posthog.com',
    persistence: 'sessionStorage',
    disable_session_recording: true,
    disable_surveys: true,
    disable_external_dependency_loading: true,
    capture_pageview: true,
    capture_pageleave: true,
    autocapture: true,
    capture_performance: false,
    disable_compression: true,
    advanced_disable_toolbar_metrics: true,
    loaded: function (p) {
      p.register({ product: 'rowel', surface: 'website', site_lang: document.documentElement.lang || 'en' })
    }
  })

  // Where on the page a click happened, in the spec's vocabulary.
  function placement(el) {
    if (el.closest('.bar')) return 'nav'
    if (el.closest('.hero')) return 'hero'
    if (el.closest('#get')) return 'get'
    if (el.closest('#setup')) return 'setup'
    if (el.closest('#security')) return 'security'
    if (el.closest('.final')) return 'closing'
    if (el.closest('.foot')) return 'footer'
    return 'other'
  }

  document.addEventListener('click', function (e) {
    var el = e.target && e.target.closest ? e.target : null
    if (!el) return
    var copy = el.closest('.term[data-copy] .copy')
    if (copy) {
      var command = copy.closest('.term').getAttribute('data-copy')
      ph.capture('install_copy', {
        command: /install/.test(command) ? 'install' : /--code/.test(command) ? 'pair-code' : 'pair',
        placement: placement(copy)
      })
      return
    }
    var a = el.closest('a[href]')
    if (!a) return
    var href = a.getAttribute('href')
    // These links mostly leave the site, and an event left in the batch queue
    // goes with the page — so they are sent at once, by beacon.
    var now = { send_instantly: true, transport: 'sendBeacon' }
    // TestFlight is the store this app is on today; "Get the app" leads there.
    if (/testflight\.apple\.com\/join/.test(href) || /^\/?#get$/.test(href)) {
      ph.capture('download_click', { placement: placement(a) }, now)
    } else if (/github\.com\/0x5446\/rowel/.test(href)) {
      ph.capture('github_click', { placement: placement(a) }, now)
    }
  }, true)
})()
