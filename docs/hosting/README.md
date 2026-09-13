# Hosting

How this game got from a laptop onto a network where anyone can scan a QR code and play, what each
piece does, and how to take it all back down.

Written for club members who will run the demo table, and for anyone who wants to host a Godot web
build on a university network without paying for cloud hosting.

| Document | Covers |
|---|---|
| **[quick-guide.md](quick-guide.md)** | **Start here to build it.** Every command in order, one page, no explanation |
| **[quick-unhost.md](quick-unhost.md)** | **Start here to remove it.** Every command to return the box to its prior state |
| [00-lesson-plan.md](00-lesson-plan.md) | Running this as a workshop: objectives, sessions, exercises, misconceptions to surface |
| [01-the-hosting-problem.md](01-the-hosting-problem.md) | Where the game actually runs, why hosting splits in two, and the options we weighed |
| [02-secure-context-and-tls.md](02-secure-context-and-tls.md) | The browser rule that dominates every decision here |
| [03-dns-01-and-duckdns.md](03-dns-01-and-duckdns.md) | How a machine with a private address gets a publicly-trusted certificate |
| [04-serving-the-box.md](04-serving-the-box.md) | The annotated walkthrough: Godot, exports, Caddy, systemd, firewall |
| [05-troubleshooting.md](05-troubleshooting.md) | Every failure we actually hit, with the real error strings |
| [06-teardown-deep-dive.md](06-teardown-deep-dive.md) | A full inventory of what hosting creates, and what removal really undoes |

For how the multiplayer itself works — authority, replication, the join flow — see the
[parent docs directory](../README.md).

## The 60-second version

A multiplayer game needs **two different kinds of host**, and conflating them is where most people
get stuck.

1. **Something to hand out the files.** Each player's browser downloads ~40 MB of wasm and ~12 MB of
   pck once, then runs the entire game locally — rendering the town, simulating its own truck. Any
   static file host does this job.

2. **Something to hold a socket open.** The relay forwards `net_transform` at 30 Hz between players.
   It simulates nothing and holds no player, but it has to stay connected, which serverless
   platforms like Vercel cannot do.

Then one rule overrides everything: **browsers refuse to run a Godot web build outside a secure
context.** Only HTTPS, `localhost` and `127.0.0.1` qualify. A laptop serving the page at
`http://10.x.x.x:8080` can never work for phones, no matter how the network is configured.

That rule is why this is harder than "just put it on the LAN," and why most of these documents are
really about certificates.

Our answer: one permanent Linux box on the campus network doing both jobs, with a free DuckDNS
subdomain pointed at its **private** address and a real Let's Encrypt certificate obtained by
DNS-01 — which proves domain control through a TXT record and never requires the outside world to
connect to the box at all.

```
phone on campus WiFi
  │
  ├── https://truck-town.duckdns.org       page + wasm   ─┐
  └── wss://truck-town.duckdns.org/ws      relay         ─┴── Caddy ──> the box
```

No cloud account, no cost, no tunnel.
