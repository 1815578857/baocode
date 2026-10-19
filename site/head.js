// In each page's <head>, before it shows (docs/attribution.md): a visitor
// who may be a listed channel's has the places a channel changes (the
// brand, the home page's title and subtitle) hidden until site.js has
// filled them in, so ours never flash first; and channels.json is asked
// for already. Never hidden for long, whatever happens.
(() => {
  let kept = null;
  try { kept = JSON.parse(localStorage.getItem('baocode.attribution')); } catch {}
  // Kept: a channel's or not. Not yet: one may be in the address.
  if (kept ? kept.source !== 'channel' : location.search.length < 2) return;
  const root = document.documentElement;
  root.classList.add('channel-pending');
  window.channelsJson = fetch('/channels.json').then((res) => res.json()).catch(() => null);
  setTimeout(() => root.classList.remove('channel-pending'), 2000);
})();
