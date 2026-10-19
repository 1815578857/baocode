# baocode.dev

The BaoCode website, hosted on Cloudflare, with no build step: `site/` is
served as it is, `/download` being `download.html`.

- English at the root, Chinese under `zh/` (`/zh/`, `/zh/download`,
  `/zh/changelog`); each page links to itself in the other language. A
  change to a page's copy goes into both. The Chinese pages use absolute
  paths (`/style.css`, `/shots/…`); the screenshots are shared.
- `changelog.html`, `zh/changelog.html`: made by
  `dart run tool/build_changelog.dart` from `release-notes/`. Edit those.

- `import.html`, `import.js`: a site's one-click import of an upstream,
  handed on to the app (`baocode://provider/import`); `upstreams.html`, how
  a site adds it. See `docs/upstream-import.md`.
- `site.js` keeps, on any page, where a visitor came from (`?abc` after
  any page's address, the site linking here, or direct), and gives the
  channel build to those who came through a channel listed with its
  account site, the standard build to anyone else; `head.js` hides what a channel changes until it is
  in; `activate.html`, `activate.js`: what the channel build opens on its
  first start, to send it to stats.baocode.dev; `channels.json` and
  `channels/` (their logos), the channels listed, shown by the brand, in
  the home page's title and subtitle; and in the channel build once set up
  (lib/channel/): its name; the site its users sign in to, without which
  the channel build cannot be used, `account: {type, url, apiUrl?,
  protocol?}` (`type` `newapi` or `sub2api`, the panel it runs; `url` the
  panel's, HTTPS, opened in the app's login window; `apiUrl` where its
  keys' models are, the panel's unless given; `protocol` `anthropic`,
  `openai-chat` or `openai-responses`, else the key's group's where
  sub2api tells, else Anthropic's); and its welcome, `welcome: {title,
  text, button?}` (each text `{zh, en}`; "Welcome to <name>" and Sign In
  unless given). `BAOCODE_CHANNELS_URL=http://127.0.0.1:<port>`, `site/`
  served there, shows one before it is published.
- `shots/`: the screenshots on the page.
- `sounds/`: the notification sound the page plays.
- `qr/`: the phone cards' QR codes, made by
  `dart run tool/make_download_qr.dart`.
- Copy marked `<mark class="todo">` is still to be written.
