# The secure-context rule

Every hosting decision in this project — why there is a certificate at all, why a laptop on the
campus LAN cannot serve the game, why we ended up with DuckDNS and Let's Encrypt for a machine that
has no public IP — traces back to a single rule enforced inside the browser.

It is worth understanding properly, because almost every instinct you have about "just serve it off
my machine" runs into it, and none of the usual workarounds apply.

## The rule

Godot's web runtime calls `window.isSecureContext` during start-up and refuses to run if it is
false. You get this, and nothing else happens:

```
The following features required to run Godot projects on the web are missing:
Secure Context - Check web server config (use HTTPS)
```

**A secure context is HTTPS, `localhost`, or `127.0.0.1`. That is the entire list.**

Not a LAN IP. Not `http://10.x.x.x:8080`, not `http://192.168.1.50:8080`, not your machine's
hostname over plain HTTP. `isSecureContext` is a property of *how the page was delivered*, and plain
HTTP to anything that isn't loopback is, by definition, insecure.

### Why you cannot configure around it

This is the part that wastes the most time, so it deserves to be stated bluntly:

> The check runs **in the visitor's browser**, on code the browser shipped, evaluating how *it*
> fetched the page. Nothing you change on the server is an input to that decision.

There is no export setting, no HTTP header, no Godot project flag, and no web-server configuration
that makes `isSecureContext` return true over plain HTTP. The server is not a participant in the
decision. When you find yourself grepping export presets for a way to disable this, stop — you are
looking on the wrong machine entirely.

You can confirm the check exists in your own build:

```console
$ grep -o "isSecureContext[^;]\{0,60\}" build/web/index.js
isSecureContext
isSecureContext: function () {
isSecureContext'] === true
isSecureContext()) {
```

## The second wall: mixed content

Suppose you solve the first problem — you put the *page* on real HTTPS somewhere (GitHub Pages,
Vercel, a tunnel) and now the game boots on a phone. You still cannot point it at a relay running on
plain `ws://`.

Browsers block **mixed content**: a page loaded over HTTPS may not open an insecure subresource
connection, and `ws://` counts. The connection fails before a single packet is sent, and the console
says so explicitly.

These are two *independent* walls:

| Wall | Applies to | Requirement |
|---|---|---|
| Secure context | the page | delivered over HTTPS / localhost |
| Mixed content | the WebSocket | `wss://`, if the page is HTTPS |

Solving one does not solve the other. This matters because the obvious compromise — "host the page
on GitHub Pages, run the relay on my laptop" — fails on the second wall even though it clears the
first. Your laptop's `ws://10.x.x.x:8910` is unreachable from an HTTPS page no matter how well the
network routes to it.

The practical consequence: **if the page is HTTPS, the relay must be too.** They do not have to live
on the same machine, but they both need certificates. That is the requirement that eventually forces
you into [DNS-01 and DuckDNS](03-dns-01-and-duckdns.md).

## What this rules in and out

| Goal | Works? | How |
|---|---|---|
| Browser testing on this machine | yes | `scripts/serve_local.sh`, then `http://localhost:8080` |
| Phones, over the internet | yes | Real HTTPS both ends — static host + a relay with a certificate |
| Phones, campus network only | yes | A certificate for a name that resolves to the box — see [03](03-dns-01-and-duckdns.md) |
| Phones, laptop serving plain HTTP on the LAN | **no** | Fails the secure-context check, unfixable |
| Phones, genuinely no internet at all | **no** | Would need a certificate the phone already trusts |
| Two laptops, no internet | yes | **Native desktop builds** — see below |

`serve_local.sh` binds `0.0.0.0` so the port is reachable from the LAN, and that is deliberately a
trap worth knowing about: other devices *can* connect, they just cannot run the game. The script's
own header comment says as much. Use it for `http://localhost:8080` and nothing else.

### The native-build escape hatch

The secure-context rule is a **browser** rule. It has no equivalent in a native build.

```bash
# Machine A
godot --headless --path . -- --server
godot --path . -- --client

# Machine B
godot --path . -- --client --url=ws://<machine-a-ip>:8910
```

Two laptops on a phone hotspot, plain `ws://`, no certificates, no DNS, no internet, no accounts.
This is the only genuinely offline path, and it is worth having ready — campus WiFi frequently has
client isolation that blocks device-to-device traffic outright, and a hotspot sidesteps that too.

What you lose is the entire premise: nobody scans a QR code to install a desktop build. It is a
fallback for a demo among people who already have laptops, not for walk-up visitors.

## Threads are a separate concern

Godot's web start-up checks several features in the same function, and it is easy to conflate two of
them that have nothing to do with each other:

| Check | Needs | Avoidable? |
|---|---|---|
| `SharedArrayBuffer` | COOP + COEP response headers (cross-origin isolation) | yes — `variant/thread_support=false` |
| `isSecureContext` | HTTPS, or localhost | **no** |

`export_presets.cfg` sets `variant/thread_support=false`. That is a caution about iOS Safari, which
is the shakiest platform for threaded web builds, and it is **not** a hosting workaround. Turning
threads off does not buy you HTTP — it buys you freedom from having to set COOP/COEP headers.

That distinction has one genuinely useful consequence. COOP/COEP are *response headers*, which means
a static host that will not let you set custom headers cannot serve a threaded build. **GitHub Pages
cannot set custom headers.** With threads off, it does not need to — which is precisely what makes
GitHub Pages a viable host for this project when it would not be for a threaded one.

`vercel.json` carries the COOP/COEP headers anyway:

```json
{ "key": "Cross-Origin-Opener-Policy",   "value": "same-origin" },
{ "key": "Cross-Origin-Embedder-Policy", "value": "require-corp" }
```

So on Vercel, flipping `thread_support=true` is a free performance experiment if phones struggle.
On GitHub Pages it is a one-way door: turn threads on there and the build stops working with no way
to fix it short of moving hosts. Worth knowing before you chase frame rate.

## Where this leaves you

Any setup that puts the game in front of a phone needs a real, publicly-trusted certificate — for
the page, and for the relay. Once you accept that, the only remaining question is how to obtain one
for a machine that lives on a campus network behind a private IP.

That is the subject of [the next document](03-dns-01-and-duckdns.md). If you just want the commands,
[quick-guide.md](quick-guide.md) has the whole sequence; [01-the-hosting-problem.md](01-the-hosting-problem.md)
explains why the work splits across a page host and a relay in the first place; and
[../04-web-export-and-hosting.md](../04-web-export-and-hosting.md) covers the export settings and
build sizes this all operates on.
