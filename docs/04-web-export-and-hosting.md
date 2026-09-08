# Web export and hosting

## The secure-context requirement

This is the single most important operational fact about the project, and it was discovered the hard
way. Loading the game from a laptop's LAN address over plain HTTP fails with:

```
The following features required to run Godot projects on the web are missing:
Secure Context - Check web server config (use HTTPS)
```

Godot's web runtime checks `window.isSecureContext` and refuses to start if it is false. Confirmed
directly in the exported runtime:

```console
$ grep -o "isSecureContext[^;]\{0,60\}" build/web/index.js
isSecureContext
isSecureContext: function () {
isSecureContext'] === true
isSecureContext()) {
```

**Secure contexts are HTTPS, `localhost`, and `127.0.0.1`. Nothing else.** A LAN IP over plain HTTP
never qualifies.

The trap is that this looks like it should be avoidable by disabling thread support. It isn't —
those are two *separate* checks in the same feature-detection function:

| Check | Needs | Avoidable? |
|---|---|---|
| `SharedArrayBuffer` | COOP + COEP headers (cross-origin isolation) | yes — `variant/thread_support=false` |
| `isSecureContext` | HTTPS, or localhost | **no** |

So `thread_support=false` buys you freedom from configuring COOP/COEP headers, but not freedom from
HTTPS. What actually follows:

| Goal | Works? | How |
|---|---|---|
| Local browser testing | yes | `http://localhost:8000` |
| Phones, any network | yes | Real HTTPS: Vercel + Fly, or a tunnel |
| Phones, no internet at all | **no** | Would need a certificate the phone already trusts |
| Two laptops, no internet | yes | Native desktop builds — no secure-context rule applies |

That last row is the salvage. The secure-context rule is a *browser* rule. A native desktop build
talks plain `ws://` over a LAN quite happily, so two laptops on a hotspot with no internet is a
genuine fallback. Worth having ready, because campus WiFi commonly has client isolation that blocks
device-to-device traffic outright.

Since HTTPS is mandatory regardless, turning thread support back **on** is now a free performance
experiment rather than a trade-off — `vercel.json` already carries the COOP/COEP headers. It is off
only because it is the shakiest path on iOS Safari.

## Renderer

Godot's Web platform supports only the **Compatibility** renderer (WebGL 2); Forward+ needs Vulkan.
Godot's default project settings include `rendering_method.web="gl_compatibility"`, so this happens
automatically with no configuration.

This cost nothing because the original demo was already written for it — `vehicle.gd`,
`town_scene.gd` and `car_select.gd` all contain
`RenderingServer.get_current_rendering_method() == "gl_compatibility"` branches that compensate for
sRGB blending and shadow-filter differences. The web build exercises those paths every time. To test
them on desktop:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path . --rendering-method gl_compatibility
```

SDFGI is hidden in the menu outside Forward+, so it never appears on the web.

## Export presets

`export_presets.cfg` is **committed**, unlike in the upstream demo repo whose `.gitignore` excludes
it. Reproducible builds are worth more here than avoiding a config file in git.

### Web

```ini
variant/thread_support=false
vram_texture_compression/for_mobile=true
progressive_web_app/enabled=false
export_path="build/web/index.html"
```

`for_mobile=true` produces ETC2/ASTC textures, which mobile GPUs need. It works because
`project.godot` already sets `textures/vram_compression/import_etc2_astc=true`. PWA is off to avoid
a service worker caching stale builds during development.

### Linux Server

```ini
dedicated_server=true
binary_format/embed_pck=true
binary_format/architecture="x86_64"
export_filter="all_resources"
```

`dedicated_server=true` adds the `dedicated_server` feature tag, which `net.gd` detects to
self-start — so the container needs no arguments. `embed_pck=true` yields a single 82 MB file
instead of a binary plus a `.pck`, which keeps the Dockerfile trivial. `x86_64` rather than arm64
because that is what Fly's default machines run.

`export_filter="all_resources"` is deliberate: the server loads the full town scene, so stripping
"visual" resources would produce load errors for meshes and materials it still references. It never
renders them, but it does need to resolve them.

## Build sizes

| Artifact | Size |
|---|---|
| `build/web/index.wasm` | 39.5 MB |
| `build/web/index.pck` | 11.7 MB |
| **Total over the wire** | **~20–25 MB** after Brotli (Vercel compresses automatically) |
| `build/server/truck-town-server` | 82.4 MB (embedded pck, Linux x86-64, stripped) |
| Export templates (prerequisite) | 1.28 GB download, 1.9 GB installed |

The `screenshots/` directory carries a `.gdignore`, so its ~1.7 MB never enters the pck at all.

Export templates must be installed before either build script works. They are not bundled with the
editor:

```bash
curl -fLO https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_export_templates.tpz
unzip -q Godot_v4.7.1-stable_export_templates.tpz -d tpz
mv tpz/templates "$HOME/Library/Application Support/Godot/export_templates/4.7.1.stable"
```

## Deployment shape

```
phone ──https──> Vercel    static page + wasm (QR code points here)
      ──wss────> Fly.io    the relay server
```

**Vercel cannot host the game server.** It is serverless: there is no long-lived process, so it
cannot hold WebSocket connections open. Any host that runs a persistent process works instead —
Fly.io, Railway, Render, or a small VPS with Caddy in front. Fly was chosen because it terminates
TLS automatically, so `wss://<app>.fly.dev` needs no certificate work at all.

`fly.toml` sets `auto_stop_machines = "off"` and `min_machines_running = 1`. A scale-to-zero machine
would cold-start on the first player's connection attempt and drop it — the worst possible failure
at a table where someone has just scanned a QR code.

`vercel.json` must live at the root of the *deployed directory*, not the repo, so
`scripts/build_web.sh` copies it into `build/web/` after exporting.

Before building the web client for cloud deployment, set the server URL in `net/net.gd`:

```gdscript
const DEFAULT_PUBLIC_SERVER_URL := "wss://truck-town.fly.dev"
```

An HTTPS page cannot open a `ws://` connection, and it has no way to infer where the relay lives.
The `?server=wss://other-host` query parameter overrides this without rebuilding, which is handy for
pointing a deployed page at a local or staging relay.
