# Hosting: a lesson plan

A workshop for club members on getting a multiplayer browser game in front of real people, on a
real network, that strangers can join by scanning a QR code.

This is the teaching companion to the rest of this folder. If you just want the commands, go to
[quick-guide.md](quick-guide.md) — that document exists precisely so nobody has to sit through a
workshop to get unblocked.

**Assumed knowledge:** you can use a terminal and you have read (or will read alongside)
[../00-godot-multiplayer-for-dummies.md](../00-godot-multiplayer-for-dummies.md). No networking,
DNS, or TLS background is assumed. That is the whole point.

**Format:** roughly 2h45 including two breaks. It splits cleanly into two sessions at the end of
Segment 3 if that suits your club better — Segments 1–3 are "why this is hard", Segments 4–6 are
"here is how you do it".

---

## Learning objectives

By the end, participants should be able to explain, in their own words:

1. **Where a multiplayer game actually runs.** That the phrase "the server" hides a design decision,
   and that in this project the server runs none of the game.
2. **Why hosting splits into two unlike jobs.** Handing out files once, versus holding a connection
   open for an hour. Why one platform being great at the first says nothing about the second.
3. **Why the browser is the hard constraint.** That `window.isSecureContext` is enforced on the
   phone, so no amount of server configuration can talk it out of the requirement.
4. **How a certificate can be issued for a machine with no public address.** That DNS-01 proves
   control of a *name*, never of a *machine*, and why that distinction is what makes campus hosting
   possible at all.
5. **How to actually do it**, and — just as importantly — how to put the machine back
   ([06-teardown-deep-dive.md](06-teardown-deep-dive.md)).

---

## Before the session

The instructor needs, working and tested:

- A box on the campus network running the finished setup, reachable by everyone in the room.
- A second machine that can run the desktop build (`godot --path . -- --client`).
- A phone on campus WiFi.
- A QR code on the projector.

Participants need a laptop and nothing else. Resist the urge to have everyone build their own
deployment during the session — the 1.3 GB of export templates alone will eat your time budget.
Exercise 5 is the hands-on one and it is deliberately scoped to a single shared box.

---

## Common misconceptions to surface early

Put these on the board in the first five minutes and come back to them. Almost everyone walks in
holding at least two.

**"The server runs the game."**
Sometimes true, but a choice, not a law. Here it is false: the relay forwards bytes and simulates
nothing. Surfacing this early makes Segment 1 land instead of being an argument.

**"Multiplayer means the phone is a controller."**
No — a phone is a *full player*. It downloads the whole game, renders the entire town, runs its own
physics, and drives its own camera. Eight phones means eight independent copies of Truck Town.

**"I'll just serve it off my laptop on the WiFi."**
The instinct is good and the conclusion is wrong for a reason nobody guesses. This is the single
most valuable misconception in the whole workshop, so don't spoil it — let Segment 3 kill it live.

**"HTTPS is only for websites with passwords and payments."**
There is no login, no database, and nothing secret in this game, so people reasonably assume TLS is
optional. It is not optional, and the reason has nothing to do with secrecy.

**"A certificate proves the server is trustworthy."**
A certificate proves control over a *name*. That is a narrower claim than most people think, and
understanding how narrow it is, is exactly what unlocks Segment 4.

**"A private IP address means it can't be on the internet's DNS."**
Resolution and reachability are two different steps. Public DNS will happily hand out `10.x.x.x`.

---

## Segment 1 — Where does the game actually run? (20 min)

Open cold with the demo, before any explanation.

**Live demo.** Two laptops running the desktop client against your relay, both driving. Then, on
the box:

```bash
sudo systemctl stop trucktown
```

Ask the room to predict what happens before you hit enter. Most will say "the game freezes" or "it
disconnects."

What actually happens: **each player keeps driving perfectly**, their own truck fully responsive,
while the other player's truck freezes in place. Restart the service and the frozen trucks snap
back to life.

```bash
sudo systemctl start trucktown
```

**Discussion prompt:** *If the server was running the game, why did your truck keep working?*

Let them reason to it. The answer is that each client simulates only its own truck and publishes
the resulting transform; the server never had the physics in the first place. Then show them the
code — `vehicle.gd` writing `net_transform = global_transform` at the end of `_physics_process`,
but only `if is_multiplayer_authority()`.

Cover:

- The three locations: the browser (the whole game), the static host (ships ~52 MB once, then is
  irrelevant), and the relay (forwards `net_transform` and `net_headlights` at 30 Hz).
- Why frozen remote trucks are *kinematic* rather than *static*, so they shove you instead of being
  walls. This is the detail that makes people grin.
- The honest cost: a car-to-car collision resolves slightly differently on each screen.

**Reading:** [01-the-hosting-problem.md](01-the-hosting-problem.md), and
[../01-architecture.md](../01-architecture.md) for the authority model underneath it.

**Discussion prompt:** *What would have to change to make both screens agree exactly about a
collision? What would that cost you?* (Server-authoritative; input lag on every steering input, and
a server that can no longer be a $2 box.)

---

## Segment 2 — Why hosting splits in two (25 min)

Now that the room knows there are two jobs, ask which platforms can do which.

Lead with the thing everyone assumes: *"I'll put it on Vercel."* Vercel is genuinely excellent at
one half of this and structurally incapable of the other. Serverless functions are invoked, they
run briefly, they exit. A WebSocket relay has to sit there holding eight connections open for an
hour. Those are not the same shape of work.

**Discussion prompt:** *Vercel, GitHub Pages, Netlify, Fly.io, a Raspberry Pi in your room. Which
of these can serve the page? Which can hold a socket open? Why is the second list shorter?*

Walk the options table in [01-the-hosting-problem.md](01-the-hosting-problem.md). The point is not
to memorise it but to internalise the axis: **stateless file delivery versus a long-lived process.**

Worth naming out loud: Fly.io's free tier ended for new accounts in October 2024, so the
"obviously just use Fly" answer now costs roughly $2–4/month. That is a fine price and also a real
reason a club might prefer a box it already owns.

**Exercise 1 (5 min, pairs).** Open `net/net.gd` and find `default_server_url()`. Work out the
priority order it resolves in and why each step exists. Then answer: *why does the `?server=`
query parameter mean the page host and the relay host are completely independent choices?*

---

## Segment 3 — The browser is the hard constraint (30 min)

This is the segment that changes how people think, so run the demo before the explanation.

**Live demo.** On your laptop, build the web export and serve it over plain HTTP on the LAN:

```bash
./scripts/serve_local.sh
```

Open `http://localhost:8080` on the laptop — **it works perfectly**. Now find the laptop's LAN IP,
put `http://10.x.x.x:8080` on the projector, and have the room load it on their phones.

Every phone shows:

```
The following features required to run Godot projects on the web are missing:
Secure Context - Check web server config (use HTTPS)
```

Same files. Same server. Same network. The only thing that changed is the hostname in the address
bar.

**Discussion prompt:** *The server didn't change at all. So where is this rule being enforced, and
what does that tell you about your ability to configure your way out of it?*

Cover:

- Godot's web runtime checks `window.isSecureContext` unconditionally, independently of thread
  support. Only HTTPS, `localhost`, and `127.0.0.1` qualify.
- It is enforced **in the browser**, on the phone, which is a machine you do not control. No export
  setting, no header, no server flag reaches it.
- The second wall behind the first: even with the page on HTTPS elsewhere, an HTTPS page cannot
  open a plain `ws://` connection. Mixed content blocking. Fixing one wall reveals the other.
- Native desktop builds have no such rule, which is why the genuinely offline fallback is two
  laptops over plain `ws://`. No QR code, though.

**Exercise 2 (5 min, individually).** In the browser devtools console on a page served over HTTPS,
evaluate `window.isSecureContext`. Then do the same on an `http://` LAN page. Two words of output,
and it is the entire reason this workshop needs Segments 4 and 5.

**Reading:** [02-secure-context-and-tls.md](02-secure-context-and-tls.md).

*(Natural split point if you are running this as two sessions.)*

---

## Segment 4 — Certificates for a machine with no public address (35 min)

Set up the apparent paradox first, and let it sit for a minute:

> Our box has the address `10.x.x.x`. That is a private address — unreachable from the internet by
> design. Let's Encrypt is on the internet. How can it possibly issue us a certificate?

Most rooms will guess it can't, or that you need to open a firewall, or buy a "real" IP.

The resolution is that **a certificate authority validates control of a name, not of a machine.**
The default challenge (HTTP-01) happens to prove it by fetching a file from your server, which is
why everyone assumes public reachability is required. DNS-01 proves the same thing by asking you to
publish a TXT record. Let's Encrypt reads DNS. It never connects to your box. Your box could be
unplugged.

Then unpack the two halves that people conflate:

```
phone anywhere     "what is truck-town.duckdns.org?"  ->  10.x.x.x     (resolution: global)
phone on campus    connect to 10.x.x.x                ->  your box     (reachability: campus only)
phone on cellular  connect to 10.x.x.x                ->  nothing      (reachability: fails)
```

**Discussion prompt:** *Anyone on earth can look up that name and get an answer. Is that a problem?
What exactly have you disclosed?*

Good answers: an internal address that isn't routable from outside, which is mild information
disclosure and essentially no attack surface. It is worth knowing you're doing it, and it is not
worth losing sleep over.

Cover:

- What DuckDNS is and why it works here: free, it runs real authoritative nameservers, it does no
  validation that the address you give it is routable, and it exposes a TXT endpoint that ACME
  clients drive for DNS-01.
- Why it is on the Public Suffix List, and why that matters for Let's Encrypt rate limits.
- **DNS rebinding protection** as the one thing that can kill the whole approach: some resolvers
  strip RFC1918 answers from public DNS on principle. Test it before building anything.

**Exercise 3 (10 min, pairs).** Trace the sequence. Caddy publishes a TXT record via the DuckDNS
API; Let's Encrypt queries public DNS for `_acme-challenge.<SUBDOMAIN>.duckdns.org`; a certificate
is issued. Now answer: *at which step, if any, does anything connect to the box on port 443?*
(Answer: none of them. Only afterwards, when a phone loads the page.)

**Reading:** [03-dns-01-and-duckdns.md](03-dns-01-and-duckdns.md).

---

## Segment 5 — Doing it (40 min)

Hands-on. Work through [quick-guide.md](quick-guide.md) together on the shared box, with
[04-serving-the-box.md](04-serving-the-box.md) open for the explanations.

Beats to hit as you go, rather than as a lecture:

- **Godot and templates go on the box, not the laptop.** The build happens where the thing runs;
  nobody needs 1.3 GB locally.
- **`DEFAULT_PUBLIC_SERVER_URL` is baked into the pck.** Change it and you must rebuild. This is the
  single most commonly forgotten step and it produces a page that loads beautifully and then says
  "No server configured."
- **Caddy does three jobs**: obtains and renews the certificate, serves the static files, and
  reverse-proxies `/ws` to the relay. `handle_path` strips the prefix so Godot's WebSocket server
  sees a plain `/`.
- **systemd is what makes it survive you closing the laptop.** Contrast with a `tmux` session,
  which is what everyone reaches for first and which dies on reboot.

**Exercise 4 (10 min, whole room).** Break it on purpose, one at a time, and predict the symptom
before checking:

| Break | Predicted symptom |
|---|---|
| `sudo systemctl stop trucktown` | Page loads fine, "Connection failed" on truck select |
| Point `DEFAULT_PUBLIC_SERVER_URL` at a wrong hostname, rebuild | Page loads, connection fails, devtools names the bad URL |
| Change the Caddyfile hostname to not match DNS | `tlsv1 alert internal error` — no cert for that SNI |

This is the most valuable ten minutes in the workshop. Every one of those is a real failure we hit
while building it, and recognising the symptom is most of the debugging.

**Exercise 5 (10 min).** Everyone scans the QR and joins at once. Watch
`journalctl -u trucktown -f` on the projector as `Peer N joined` scrolls. Then have someone hit
<kbd>M</kbd> and watch the sky change on every screen simultaneously — shared state, host-owned,
pushed to new joiners via `rpc_id`.

**Reading:** [05-troubleshooting.md](05-troubleshooting.md) — every error in it is one we actually
hit, in the order we hit it.

---

## Segment 6 — Putting it back (15 min)

Do not skip this. A workshop that leaves twelve people with half-configured boxes and an open port
they have forgotten about is a bad workshop.

Walk [quick-unhost.md](quick-unhost.md) and discuss *why the order matters* — stop services before
removing their units, remove the firewall rules last so you don't lock yourself out mid-teardown,
and revoke the DuckDNS subdomain rather than just deleting the local config.

**Discussion prompt:** *Which parts of this setup are still running if you only delete the repo?*
(All of them: the systemd units, Caddy, the firewall rules, and the public DNS record. Deleting the
code removes none of it.)

**Reading:** [06-teardown-deep-dive.md](06-teardown-deep-dive.md).

---

## What participants should be able to do unaided

- Look at any multiplayer game and ask the right first question: *what does the server actually
  simulate?*
- Given a game and a venue, decide what needs a static host, what needs a long-lived process, and
  whether those can be the same thing.
- Recognise the secure-context error on sight and know immediately that it is not fixable
  server-side.
- Explain to someone else why a certificate can exist for a machine the internet cannot reach.
- Stand up the full stack on a fresh box from [quick-guide.md](quick-guide.md) without this
  document.
- Read a `journalctl -u caddy` failure and tell an ACME problem from a DNS problem from a firewall
  problem.
- Tear it all down and verify nothing is left listening.

---

## Where to go next

The obvious follow-up workshop is the one this project skipped: **what changes if you don't trust
the clients.** This game is client-authoritative and cheerfully exploitable by design — a modified
client can teleport. That is the correct trade for a demo table with no stakes, and it is exactly
the wrong trade for anything competitive. Walking the room from "here is how you'd cheat" to "here
is what server-authoritative costs you" is a natural sequel, and
[../01-architecture.md](../01-architecture.md) already sets up both sides of it.
