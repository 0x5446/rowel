// The analytics proxy, and nothing else (`run_worker_first: ["/ingest/*"]` in
// wrangler.jsonc keeps every page on plain assets).
//
// Same-origin /ingest/* → PostHog US, so the page needs no third-party host
// and ad blockers have nothing foreign to block. It forwards only the headers
// PostHog needs: not the visitor's IP, not cookies. The country comes from
// Cloudflare's CF-IPCountry and is written into each event with
// `$geoip_disable`, because PostHog locating by IP would only ever find
// Cloudflare's egress. Requires `disable_compression` in analytics.js, or the
// body cannot be read to tag and is forwarded as is.
//
// Adapted from Mnemo's Pages Function (mnemo/site/functions/ingest).
const API = 'us.i.posthog.com'
const ASSETS = 'us-assets.i.posthog.com'

/** Put Cloudflare's country on every event in a decoded PostHog payload. */
function tagEvents(data, country) {
  const events = Array.isArray(data) ? data : Array.isArray(data.batch) ? data.batch : [data]
  for (const event of events) {
    if (!event || typeof event !== 'object') continue
    event.properties = event.properties || {}
    event.properties.$geoip_disable = true
    if (country && country !== 'XX' && country !== 'T1') event.properties.$geoip_country_code = country
  }
  return data
}

/**
 * Tag a request body, in either of the two shapes posthog-js sends with
 * compression off: plain JSON (fetch), or `data=<base64 JSON>` form-encoded
 * with `?compression=base64` (sendBeacon, used for clicks that leave the
 * page). Anything else — or anything that does not parse — goes on as it came.
 */
export function tagBody(body, { compression, contentType, country }) {
  const text = new TextDecoder().decode(body)
  try {
    if (!compression) {
      return new TextEncoder().encode(JSON.stringify(tagEvents(JSON.parse(text), country)))
    }
    if (compression === 'base64' && /x-www-form-urlencoded/.test(contentType || '')) {
      const form = new URLSearchParams(text)
      const json = new TextDecoder().decode(Uint8Array.from(atob(form.get('data') || ''), c => c.charCodeAt(0)))
      const tagged = new TextEncoder().encode(JSON.stringify(tagEvents(JSON.parse(json), country)))
      let binary = ''
      // In slices: spreading a large batch into one call overruns the argument limit.
      for (let i = 0; i < tagged.length; i += 8192) binary += String.fromCharCode(...tagged.subarray(i, i + 8192))
      form.set('data', btoa(binary))
      return new TextEncoder().encode(form.toString())
    }
  } catch {
    // Not a payload we understand; PostHog can still read it untagged.
  }
  return body
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    if (!url.pathname.startsWith('/ingest/')) return env.ASSETS.fetch(request)
    const path = url.pathname.replace(/^\/ingest/, '')
    const host = /^\/(static|array)\//.test(path) ? ASSETS : API
    const headers = new Headers()
    for (const name of ['content-type', 'content-encoding', 'accept', 'user-agent', 'origin', 'referer']) {
      const value = request.headers.get(name)
      if (value) headers.set(name, value)
    }
    const init = { method: request.method, headers, redirect: 'manual' }
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      const body = await request.arrayBuffer()
      init.body = request.headers.get('content-encoding')
        ? body
        : tagBody(body, {
          compression: url.searchParams.get('compression'),
          contentType: request.headers.get('content-type'),
          country: request.headers.get('cf-ipcountry'),
        })
    }
    const response = await fetch(new URL(`https://${host}${path}${url.search}`), init)
    const out = new Headers(response.headers)
    out.delete('set-cookie')
    return new Response(response.body, { status: response.status, headers: out })
  },
}
