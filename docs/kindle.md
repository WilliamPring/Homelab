# Kindle (jailbroken, KOReader) — books, Kavita library and Suwayomi manga

Everything the Kindle uses already runs. On home WiFi it talks to the nodes directly over the
LAN NodePorts (plain http — fine on your LAN; the hostnames would need Tailscale on the Kindle).

| Server | LAN URL | Login |
|---|---|---|
| Kavita OPDS | `http://192.168.68.63:30500/api/opds/<key>` | none — the key is in the URL (Kavita → avatar → Settings → 3rd Party Clients → *OPDS URL*, swap the host) |
| Kavita KOReader sync | `http://192.168.68.63:30500/api/koreader/<key>` | username = your Kavita user, password = anything |
| Calibre-Web OPDS | `http://192.168.68.63:30083/opds` | your CWA username + password |
| Suwayomi | `http://192.168.68.63:30456` | Basic auth — the creds in `gitops/suwayomi/deployment.yaml` |

## Setup
1. **KOReader** via the jailbreak (MRPI/KUAL — see the KOReader wiki for Kindle). Then install the
   App Store plugin (`github.com/omer-faruq/appstore.koplugin`) for one-tap plugin installs.
2. **Kavita + books (OPDS)** — Search → OPDS catalog → **+** → name, URL, (username/password for
   CWA only). Browse → tap a book/chapter → Download → opens from the file browser; works offline.
3. **Kavita progress sync** — plugins icon → Progress sync → Custom sync server → the
   `/api/koreader/<key>` URL → Register/Login. Position syncs both ways with the web reader and
   with Paperback/Aidoku-via-Kavita. (KOReader can point at ONE sync server — use Kavita's, not CWA's.)
4. **Suwayomi manga** — Tools → App Store → `suwayomi.koplugin` → install → restart → Search →
   Suwayomi → URL + **Basic Auth** creds → Test connection → pick a download folder.
   Library by category, source search, extension install, chapter download (CBZ, offline), read/unread
   synced to the server, *Auto-download* of the next unread chapters. Your hand-copied manga appears
   via the Local source like any other series.

## Gotchas
| Symptom | Fix |
|---|---|
| OPDS: "Catalog not found" | URL returns a web page/404 — test it in a desktop browser first; Kavita needs OPDS enabled (Administration → Settings) |
| OPDS: "Authentication required" on the **Kavita** catalog | the key is missing/stale in the URL (Kavita → *Reset API Key* kills old URLs). Copy the OPDS URL again |
| OPDS: "Authentication required" on **Calibre-Web** | expected — long-press the catalog → Edit → fill username/password |
| Suwayomi chapters download slowly | chapters already downloaded by the server copy as one archive; page-by-page otherwise → leave server auto-download on |
| Progress not syncing | Progress sync server must be the Kavita URL; sync happens on open/close by default |
| Away from home | nothing here works without Tailscale on the Kindle (a separate project); hostnames would then work with https |

Related: `docs/kavita.md`, `docs/suwayomi.md`.
