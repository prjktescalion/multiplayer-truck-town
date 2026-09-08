# Multiplayer Truck Town

Free-roam multiplayer driving in a shared town, joinable from a phone by scanning a QR code.
Built on Godot's Truck Town demo (Godot 4.7, Forward+ on desktop, Compatibility on the web).

Everyone drives in the same town at the same time: you can see each other, bump into each other,
honk, and cycle the shared time of day. Up to 8 players.

The Truck Town game is one of the Godot demo projects:
https://github.com/godotengine/godot-demo-projects/tree/master/3d/truck_town

The multiplayer engine and web ports were developed by [Kush](https://skushagra.com/)

## How the multiplayer works

The server is a **dedicated relay**. It holds no player and simulates no physics — it only passes
truck state between clients. Each client fully simulates *its own* truck and replicates the
resulting transform, which keeps controls instant even over the internet. Other players' trucks
arrive as frozen kinematic bodies, so they still shove you around on contact instead of being
ghosts, and they are eased between the ~30 Hz network updates at the 120 Hz physics rate.

The tradeoff: a car-to-car collision resolves slightly differently on each screen. That is
invisible in practice and is the reason the game feels responsive on a phone over WiFi.

A phone is a **full player**, not a controller — it renders the whole town, runs its own camera,
and simulates its own truck.

## Controls

Keyboard and gamepad are unchanged from the original demo (arrows/WASD to drive, <kbd>Shift</kbd>
boost, <kbd>H</kbd> horn, <kbd>C</kbd> camera, <kbd>M</kbd> time of day, <kbd>L</kbd> headlights,
<kbd>U</kbd> speed unit, <kbd>Escape</kbd> back).

On a touchscreen the vehicle accelerates automatically. Touch the left and right edges to steer and
the middle to brake/reverse, plus on-screen **BOOST**, **HORN** and **CAM** buttons at the bottom
left. Time of day is shared, so changing it changes it for everybody.

## Running it locally

```bash
# Terminal 1 — the relay server.
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --server

# Terminal 2 — a desktop client that skips the menu.
/Applications/Godot.app/Contents/MacOS/Godot --path . -- --client --truck=0
```

Useful flags (they go after the bare `--`):

| Flag | Meaning |
|---|---|
| `--server` | Run as the dedicated relay. |
| `--port=8910` | Port to listen on / connect to. |
| `--client` | Skip the menu and join immediately. |
| `--truck=0` | Which truck to join with (0 minivan, 1 trailer, 2 tow). |
| `--url=ws://host:8910` | Connect somewhere other than localhost. |

## Deploying for the table

Two hosts are involved, because they do genuinely different jobs:

```
phone ──https──> Vercel    static page + wasm (the QR code points here)
      ──wss────> Fly.io    the relay server
```

**Vercel cannot host the game server.** It is serverless, so it can't hold open WebSocket
connections. It only serves the page.

### 1. The relay server (Fly.io)

```bash
./scripts/build_server.sh          # exports build/server/truck-town-server (Linux x86-64)
fly launch --no-deploy             # first time only; keep the existing fly.toml
fly deploy
```

Fly terminates TLS for you, so you get `wss://<app>.fly.dev` with no certificate work.
`fly.toml` keeps one machine always running — a cold start would drop the first player's
connection attempt.

Any host that allows a long-lived process and WebSockets works equally well (Railway, Render, a
small VPS with Caddy in front). Only Vercel-style serverless platforms don't.

### 2. The page (Vercel)

Set `DEFAULT_PUBLIC_SERVER_URL` in `net/net.gd` to your deployed server first — an HTTPS page
cannot open an insecure `ws://` connection, and it has no way to guess where the server lives:

```gdscript
const DEFAULT_PUBLIC_SERVER_URL := "wss://truck-town.fly.dev"
```

Then:

```bash
./scripts/build_web.sh
vercel --prod build/web
```

Print a QR code of the resulting URL and put it on the table. You can point a build at a different
server without rebuilding by appending `?server=wss://other-host`.

### 3. Browsers require HTTPS — there is no plain-HTTP shortcut

Godot's web runtime refuses to start outside a **secure context**, and checks this independently of
thread support:

```
The following features required to run Godot projects on the web are missing:
Secure Context - Check web server config (use HTTPS)
```

Secure contexts are HTTPS, `localhost`, and `127.0.0.1` — **a LAN IP over plain HTTP never
qualifies.** So serving the page off a laptop at `http://192.168.x.x` cannot work for phones, and
no export setting changes that.

What this means in practice:

| Goal | Works? | How |
|---|---|---|
| Test on this machine | yes | `scripts/serve_local.sh`, open `http://localhost:8080` |
| Phones, any network | yes | Deploy to Vercel + Fly (above), or a tunnel (below) |
| Phones, no internet at all | no | Would need a cert the phone already trusts |
| Two laptops, no internet | yes | Native desktop builds — see below |

### Offline fallback for laptops

The secure-context rule is a *browser* rule. Native desktop builds have no such requirement, so
two laptops can play over plain `ws://` on a hotspot with no internet, certificates or accounts.
With Godot installed on both:

```bash
# Laptop A
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --server
/Applications/Godot.app/Contents/MacOS/Godot --path . -- --client

# Laptop B
/Applications/Godot.app/Contents/MacOS/Godot --path . -- --client --url=ws://<laptop-a-ip>:8910
```

This is the genuinely offline path, and it is worth having ready because **campus WiFi usually has
client isolation** that blocks device-to-device traffic outright.

### Quick HTTPS for phones without deploying

`tailscale` is already installed on this machine. Tailscale Funnel issues a real certificate and
gives a public URL, so any phone can reach it:

```bash
tailscale funnel --set-path / --bg http://localhost:8080
tailscale funnel --set-path /ws --bg http://localhost:8910
tailscale funnel status          # prints the https://<host>.ts.net URL
```

Then set `DEFAULT_PUBLIC_SERVER_URL` to `wss://<host>.ts.net/ws` and rebuild the web client.
Funnel has to be enabled for the tailnet in the admin console first. This still needs internet, so
it is a convenience for testing rather than a true offline fallback.

## Web export notes

Thread support is currently **off** in the Web preset, because it is the shakiest path on iOS
Safari. Note that this buys less than it looks like it does: HTTPS is mandatory either way thanks
to the secure-context rule above, and `vercel.json` already sets the COOP/COEP headers that
`SharedArrayBuffer` needs. So turning threads on is a reasonable performance experiment if phones
struggle — flip `variant/thread_support=true` in `export_presets.cfg` and re-test on a real
iPhone.

The build is roughly 40 MB of wasm plus 12 MB of pck, which compresses to ~20-25 MB over the wire.

If phones struggle, the highest-impact lever is `physics_ticks_per_second=120` in `project.godot`,
which is very heavy for a phone; `scaling_3d/scale.mobile` is already 0.67 and can go lower.

## Credits

Based on the [Truck Town demo](https://github.com/godotengine/godot-demo-projects) from
godot-demo-projects, MIT licensed.

### Ambient sounds

- [Sunrise](https://freesound.org/people/nyoz/sounds/614202/) by nyoz
- [Day](https://freesound.org/people/pawsound/sounds/154880/) by pawsound
- [Sunset](https://freesound.org/people/roisin.gleeson/sounds/699131/) by roisin.gleeson
- [Night](https://freesound.org/people/DidntGoToFilmSchool/sounds/248103/) by DidntGoToFilmSchool

### Models

- [tree low-poly](https://sketchfab.com/3d-models/tree-low-poly-4cd243eb74c74b3ea2190ebcec0439fb) by Ricardo Sanchez (https://sketchfab.com/380660711785)
- [Lowpoly lamp](https://sketchfab.com/3d-models/lowpoly-lamp-c020f6af78f7482f8cf2ac84d05c08a5) by RitiWox (https://sketchfab.com/RitiWox)

### Screenshot

<img width="2330" height="1231" alt="Screenshot 2026-09-08 at 15 46 16" src="https://github.com/user-attachments/assets/b5660e9b-c2e5-4e28-a28f-a21633612245" />
