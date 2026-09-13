# The hosting problem

Before choosing where to put this game, you have to answer a question that sounds trivial and
isn't: **where does the game actually run?**

Get that wrong and every hosting decision after it is wrong too. People reach for "I'll deploy the
server to Vercel" because they are picturing a server that runs the game. That server does not
exist in this project.

---

## Where the game actually runs

Nowhere on a server. **Each player's own device runs the entire game.** A phone is a full player,
not a controller — it renders the whole town, runs its own camera, plays its own audio, and
simulates its own truck.

Eight phones at the table means eight independent copies of Truck Town running simultaneously,
each drawing its own view of a shared world.

There are three pieces, and only one of them is the game:

### 1. The player's browser — this is the game

Downloads roughly **40 MB of wasm and 12 MB of pck** once (about 20–25 MB over the wire after
compression), then runs everything locally. Physics, rendering, input, audio, camera. All of it.

### 2. The static host — a file server, nothing more

Hands over `index.html`, the wasm, and the pck on first load. After that it is **completely out of
the loop.** You could take it offline and every game already running would continue without
noticing. Any host that can serve files over HTTPS does this job identically.

### 3. The relay — a mail sorter

Runs headless. No window, no rendering, no vehicle simulation, no player of its own. Each client
writes two properties — `net_transform` and `net_headlights` — and a `MultiplayerSynchronizer`
publishes them at 30 Hz. The relay forwards them to the other players, along with horn RPCs and the
shared time of day.

That is genuinely all it does. See [../01-architecture.md](../01-architecture.md) for why it does
so little.

**Why it's built this way:** nobody waits on a round trip to steer. Your truck responds to your
thumb instantly because your phone is simulating it, with no server in the path. The cost is that a
car-to-car collision resolves slightly differently on each screen — invisible at a demo table, and
the reason the game feels good on a phone over WiFi.

**The practical consequence:** the relay is doing nearly nothing and the phone is doing all the
work. If phones struggle, the fix is in `project.godot` — `physics_ticks_per_second=120` is very
heavy for a phone — not in a bigger server.

---

## Why that splits hosting in two

Pieces 2 and 3 are unlike jobs:

|  | Static host | Relay |
|---|---|---|
| Work | Hand over ~52 MB, once per player | Forward a few KB/s, continuously |
| Lifetime | Milliseconds per request | Hours, held open |
| State | None | Who is connected, and their trucks |
| Scales by | Bandwidth | Concurrent connections |

A platform being excellent at the first says nothing about whether it can do the second.

**This is why Vercel cannot host the game server.** Vercel is serverless: a function is invoked,
runs briefly, exits. There is no process sitting there holding eight WebSocket connections open for
an hour, because that is precisely the thing serverless is designed not to do. Vercel serves the
page beautifully and cannot be the relay, and no configuration changes that. The same is true of
Netlify, Cloudflare Pages, and GitHub Pages.

So you need either one host that can do both, or two hosts that each do one.

---

## The options we considered

### Fly.io — works, and the config is already in this repo

`Dockerfile` and `fly.toml` are committed and ready. Fly runs Docker containers as microVMs and
terminates TLS for you, so `wss://` needs no certificate work at all. `fly.toml` keeps one machine
permanently warm, because a cold start would drop the first player's connection attempt.

The catch is money. **Fly's free tier ended for new accounts in October 2024.** New signups get a
$5 trial credit, then pay-as-you-go — roughly $2/month for a shared-cpu-1x/256 MB machine, nearer
$3–4 for the 512 MB the committed `fly.toml` asks for. For a one-off demo the trial credit covers
it comfortably. For something permanent it is a small recurring bill.

Entirely reasonable. We didn't pick it because we already had hardware.

### GitHub Pages — works for the page, and only because threads are off

Free, already wherever your repo is, and HTTPS by default. The reason it works here at all is
specific: Godot web exports with thread support need `SharedArrayBuffer`, which needs COOP and COEP
response headers, and **GitHub Pages cannot set custom headers.** This project has
`variant/thread_support=false` in `export_presets.cfg`, so those headers are never needed. The
`vercel.json` in this repo becomes dead weight rather than a requirement.

The 40 MB wasm sits under the 100 MB per-file limit, so size is not a problem.

Two costs. `build/` is gitignored, so publishing means either committing ~52 MB of build artifacts
or force-pushing an orphan `gh-pages` branch. And if you ever flip `thread_support=true` chasing
phone performance, GitHub Pages stops working and cannot be fixed.

It remains a genuinely good option for the page half, and it pairs well with a tunnelled relay —
see below.

### A laptop on campus WiFi — fails, for a reason nobody guesses

The instinct is excellent: your laptop is already on the network, it can obviously run a server,
why involve the cloud at all?

It cannot work for phones, and not because of anything you can configure. See
[02-secure-context-and-tls.md](02-secure-context-and-tls.md) for the full explanation — the short
version is that browsers refuse to run Godot outside a secure context, a LAN IP over plain HTTP
never qualifies, and that rule is enforced on the phone rather than on your laptop.

Native desktop builds have no such rule, so two laptops over plain `ws://` on a hotspot is a
genuinely offline path. It just has no QR code in it, which was the whole premise.

### Tailscale Funnel — works, at the cost of a round trip

Funnel gives you a real Let's Encrypt certificate and a public `https://<host>.ts.net` URL that
tunnels to a machine you control. No domain needed, no DNS to configure, and it sidesteps every
question about campus firewalls and client isolation, because traffic leaves the network and comes
back.

The cost is that traffic leaves the network and comes back. For the relay — a few KB/s of
transforms — that is fine. For the page, it means ~52 MB per phone through a tunnel that was not
built for bulk static delivery.

The sensible shape, if you go this way, is a **split**: GitHub Pages serves the wasm off a real
CDN, and Funnel exposes only the relay. Cross-origin is fine — an HTTPS page may open a `wss://`
connection to a different host, and WebSocket handshakes are not subject to CORS preflight.

Good fallback. Keep it in your pocket.

### A permanent Linux box on the campus network — what we chose

A machine that is already on the network, already ours, always on, and free. It does both jobs from
one origin, which also means no mixed-content problem and no cross-origin anything.

The only thing it lacks is a certificate, because it has a private address and no DNS name. That is
the problem [03-dns-01-and-duckdns.md](03-dns-01-and-duckdns.md) solves, and solving it turns out to
be about fifteen minutes of work.

---

## What we ended up with

```
                        campus network
   ┌────────────────────────────────────────────────────────────┐
   │                                                            │
   │   phone ──┐                                                │
   │   phone ──┼── https ──>  the box  (10.x.x.x)               │
   │   phone ──┘   wss                                          │
   │                    │                                       │
   │                    ├── Caddy  :443                         │
   │                    │     ├── /     -> /srv/trucktown       │
   │                    │     │            (page, ~52 MB, once) │
   │                    │     └── /ws   -> localhost:8910       │
   │                    │                                       │
   │                    └── truck-town-server :8910             │
   │                          (relay: 30 Hz transforms)         │
   └────────────────────────────────────────────────────────────┘
                    ▲
                    │  DNS and certificate issuance only.
                    │  No game traffic ever crosses this line.
                    │
        DuckDNS         truck-town.duckdns.org  ->  10.x.x.x
        Let's Encrypt   validates a TXT record; never connects to the box
```

One machine, one origin, one certificate. Everything the players touch stays on the campus network
and never leaves it. The internet is involved exactly twice: once when DuckDNS answers a DNS query,
and once when Let's Encrypt issues the certificate.

Commands in [quick-guide.md](quick-guide.md), explanations in
[04-serving-the-box.md](04-serving-the-box.md), and every error we hit along the way in
[05-troubleshooting.md](05-troubleshooting.md).

---

## None of this is locked in

`net/net.gd` has a function called `default_server_url()`, and it resolves in priority order:

1. An explicit `?server=` query parameter on the page URL
2. Otherwise, if the page came over plain HTTP, the host that served the page
3. Otherwise, the baked-in `DEFAULT_PUBLIC_SERVER_URL` constant

That first step is the important one. **It completely decouples the page host from the relay
host.** The page can come from GitHub Pages while the relay lives on a box on campus, or on Fly, or
behind a Funnel — and you can switch between them by changing the QR code, with no rebuild.

So the choices above are not a one-way door. Pick the simplest thing that works for the venue you
are in, and know you can move either half independently later.

The one thing worth remembering: `DEFAULT_PUBLIC_SERVER_URL` is compiled into the pck. Changing it
means re-running `scripts/build_web.sh`. Using `?server=` instead means changing a URL. That
difference matters more than it sounds like it should, and it is the single most commonly forgotten
step in the whole setup.

---

**Next:** [02-secure-context-and-tls.md](02-secure-context-and-tls.md) — why the browser, not the
network, is the real constraint.
