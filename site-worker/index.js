// baocode.dev's Worker: site/ is served as static assets, and this runs only
// for /dl/* (run_worker_first in wrangler.jsonc). /dl/windows, /dl/macos-arm64
// and /dl/macos-x64 redirect to that build of the release in latest.json, and
// /dl/android and /dl/ios to the phone app's in releases/mobile/latest.json, so
// a page's links work before site.js swaps them, and without it: a page
// cached by a browser, a fetch of the manifest too slow or blocked.

const MANIFEST = 'https://dl.baocode.dev/releases/latest.json';
const MOBILE_MANIFEST = 'https://dl.baocode.dev/releases/mobile/latest.json';
const MOBILE = new Set(['android', 'ios']);

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    const os = pathname.match(/^\/dl\/([a-z0-9-]+)\/?$/)?.[1];
    if (!os) return env.ASSETS.fetch(request);
    let manifest;
    try {
      const res = await fetch(MOBILE.has(os) ? MOBILE_MANIFEST : MANIFEST, { cf: { cacheTtl: 60, cacheEverything: true } });
      if (res.ok) manifest = await res.json();
    } catch {}
    const file = manifest?.downloads?.[os];
    if (!file?.url) {
      const [status, text] = manifest ? [404, 'Not found'] : [502, 'The release could not be read; try again shortly.'];
      return new Response(text, { status, headers: { 'Cache-Control': 'no-store' } });
    }
    return new Response(null, {
      status: 302,
      headers: { Location: file.url, 'Cache-Control': 'no-store' },
    });
  },
};
