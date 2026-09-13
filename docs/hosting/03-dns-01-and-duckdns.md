# Certificates for a machine with no public address

[The previous document](02-secure-context-and-tls.md) established that phones will not run the game
without a real, publicly-trusted certificate — for the page and for the relay.

This one explains how you get one for a box sitting on a campus network at `10.x.x.x`, with no
public IP, no domain of its own, and no inbound connectivity from the internet. It sounds like it
should be impossible. It isn't, and the reason why is the most genuinely useful thing in this whole
folder.

## The idea in one sentence

> A certificate authority certifies that you control a **name**. It has no opinion about what that
> name points at, or whether anyone can reach it.

Nothing in the design of TLS says a certified hostname must resolve to a routable address. Public
DNS is perfectly happy to hand out `10.x.x.x` as an answer. Let's Encrypt is perfectly happy to
issue for a name that resolves there. Browsers are perfectly happy to validate the certificate.

So the plan is:

1. Get a public DNS name you control.
2. Point it at the box's private IP.
3. Prove to Let's Encrypt that you control the name — **without** it ever contacting the box.
4. Serve TLS on the box with the resulting certificate.

Anyone on the campus network resolves the name, reaches the private address, and sees a valid
padlock. Anyone off campus resolves the name, gets an address they cannot route to, and times out.

## Resolution and reachability are different things

This trips people up, so it is worth separating explicitly. Two distinct steps happen when a phone
opens the page:

```
"what is truck-town.duckdns.org?"  ──> public DNS ──> "10.x.x.x"     (works from anywhere)
connect to 10.x.x.x                ──> the network ──> your box       (works on campus only)
```

**Resolution is global.** Anyone on earth can look up the name and get an answer — DuckDNS serves it
publicly and does not care who is asking.

**Reachability is local.** `10.0.0.0/8` is [RFC 1918](https://datatracker.ietf.org/doc/html/rfc1918)
private space. Off campus, that address either goes nowhere or points at some unrelated device on
whatever LAN the phone happens to be on.

For a demo table, that split is not a limitation — it is the desired behaviour. Everyone playing is
on campus WiFi by definition. You get a working HTTPS URL with no public exposure of the box at all.

## DuckDNS

DuckDNS is a free dynamic-DNS service. It runs the authoritative nameservers for `duckdns.org`, and
gives you a subdomain plus a token. Everything it does is one HTTP endpoint:

```
https://www.duckdns.org/update?domains=truck-town&token=YOUR_DUCKDNS_TOKEN&ip=10.x.x.x
```

Two things about it matter here.

**It does not validate routability.** DuckDNS was built for people exposing home servers on dynamic
*public* IPs, but the `ip=` parameter is taken at face value. Hand it an RFC 1918 address and it
will serve that answer indefinitely. Nothing in the service objects.

**It can set TXT records too**, which is what the certificate half needs:

```
https://www.duckdns.org/update?domains=truck-town&token=YOUR_DUCKDNS_TOKEN&txt=<challenge-value>
```

`domains=` takes the bare label — `truck-town`, not `truck-town.duckdns.org`. Getting that wrong is
a common and confusing failure, because the request still returns `OK`.

### Why the Public Suffix List matters

`duckdns.org` is on the [Public Suffix List](https://publicsuffix.org/). That list tells software —
including Let's Encrypt's rate limiter — where the boundary between "shared infrastructure" and "an
individual registration" falls.

Without it, every DuckDNS user in the world would share a single rate-limit bucket against
`duckdns.org`, and certificate issuance would fail constantly through no fault of your own. Because
it is listed, `truck-town.duckdns.org` counts as its own registrable domain with its own quota.

This is a real practical difference between services. A free-subdomain provider *not* on the PSL is a
poor choice for certificates regardless of how nice its API is.

## ACME challenges: why HTTP-01 cannot work and DNS-01 can

Let's Encrypt needs proof you control the name. It offers a few ways, and the difference between
them is the entire reason this setup is possible.

| Challenge | How Let's Encrypt verifies | Needs inbound access to your box? |
|---|---|---|
| **HTTP-01** | fetches `http://<name>/.well-known/acme-challenge/<token>` | **yes** — port 80 |
| **TLS-ALPN-01** | opens a TLS connection with a special ALPN protocol | **yes** — port 443 |
| **DNS-01** | queries public DNS for a `_acme-challenge.<name>` TXT record | **no** |

HTTP-01 is the default almost everywhere, and it is exactly what fails here. Let's Encrypt's
validation servers live on the public internet; they cannot open a connection to `10.x.x.x`. The
request goes nowhere and validation fails. No amount of firewall configuration on your end changes
that — the address is not routable, full stop.

DNS-01 sidesteps it entirely. The flow is:

1. Caddy asks Let's Encrypt for a certificate for `truck-town.duckdns.org`.
2. Let's Encrypt returns a challenge value.
3. Caddy calls the DuckDNS API to publish it as `_acme-challenge.truck-town.duckdns.org` TXT.
4. Caddy tells Let's Encrypt to go check.
5. Let's Encrypt queries **public DNS** for that TXT record and sees the expected value.
6. Certificate issued.

**At no point does Let's Encrypt contact your box.** The entire conversation happens between Caddy
and the ACME API (outbound HTTPS, which campus networks allow), and between Let's Encrypt and
DuckDNS's nameservers (nowhere near you). The box could be behind three layers of NAT, or powered
off, and it would still work.

This is why DNS-01 is the standard answer for internal services, and why it is worth knowing about
well beyond this project.

## The campus firewall problem

Here is the failure this project actually hit, because it is not obvious and the error message is
long enough to be intimidating.

With `tls { dns duckdns ... }` configured, Caddy published the TXT record correctly and then failed:

```
{"level":"error","logger":"tls.obtain","msg":"could not get certificate from issuer",
 "identifier":"truck-town.duckdns.org",
 "error":"...solving challenges: waiting for solver certmagic.solverWrapper to be ready:
  checking DNS propagation of \"_acme-challenge.truck-town.duckdns.org.\"
  (relative=_acme-challenge.truck-town zone=duckdns.org. resolvers=[127.0.0.53:53]):
  querying authoritative nameservers: dial tcp 15.223.21.81:53: i/o timeout"}
```

Read past the noise to `checking DNS propagation` and `dial tcp ...:53: i/o timeout`.

Before handing off to Let's Encrypt, Caddy tries to confirm for itself that the TXT record is
visible. It does this thoroughly: it finds the authoritative nameservers for the zone and queries
**them directly on port 53**, rather than trusting a local caching resolver that might return a stale
negative answer. `15.223.21.81` is one of DuckDNS's nameservers.

Campus networks almost universally block outbound port 53 to anything except their own resolvers.
It is a standard control — it stops DNS tunnelling and forces all lookups through infrastructure the
university can monitor and filter. So Caddy's query never arrives, times out, and the whole issuance
attempt is abandoned before Let's Encrypt is ever asked to validate.

The crucial insight: **the challenge itself was fine.** The TXT record was published and publicly
visible. Let's Encrypt, which is not behind the campus firewall, could have read it without any
difficulty. The only thing that failed was Caddy's optional self-check.

### The fix

Skip the self-check and wait a fixed interval instead:

```caddyfile
truck-town.duckdns.org {
	tls {
		dns duckdns YOUR_DUCKDNS_TOKEN
		propagation_delay 60s
		propagation_timeout -1
	}
	...
}
```

- `propagation_timeout -1` disables propagation checking entirely.
- `propagation_delay 60s` pauses after publishing the record before telling Let's Encrypt to check,
  which is what the self-check was there to guarantee. DuckDNS publishes near-instantly, so a minute
  is generous.

The trade-off is honest and small: you lose a diagnostic that would have caught a genuinely broken
DNS provider, and you accept a fixed one-minute delay on issuance and renewal. On a network that
blocks outbound 53, there is no alternative — and there is nothing to lose, since the check cannot
run at all.

`resolvers 1.1.1.1 8.8.8.8` is the fix you will find suggested most often online. It does not help
here: pointing Caddy at a different resolver still requires reaching it on port 53, which is the
thing being blocked.

## Risks, honestly

### DNS rebinding protection can kill this outright

Some resolvers refuse to return RFC 1918 addresses from public DNS. This is **DNS rebinding
protection**, and it is a legitimate security control — the attack it prevents is a public hostname
that resolves to an internal address in order to get a victim's browser to attack their own network.
Which, viewed from a certain angle, is an uncharitable description of exactly what we are doing.

If NEU's resolvers did this, phones on campus would get no usable answer for
`truck-town.duckdns.org` and the entire approach would be dead with no workaround.

**Test this before building anything else.** It takes a minute:

```bash
# from a phone or laptop on campus WiFi, after setting the DuckDNS record
dig +short truck-town.duckdns.org
```

If it returns your box's `10.x.x.x`, you are fine. If it returns nothing, stop — you need a tunnel
(Tailscale Funnel gives a real certificate and a public hostname with no DNS work) rather than this
approach.

There is a pleasant shortcut for confirming it: if `curl https://truck-town.duckdns.org` from the box
reaches Caddy and fails only on TLS, then resolution already worked. A TLS error is *good* news at
that stage — it means DNS and routing are both fine and only the certificate is missing.

### You are publishing an internal address

The A record is world-readable. Anyone can learn that `truck-town.duckdns.org` lives at a particular
private address inside the campus network.

This is minor. The address is unroutable from outside, RFC 1918 space is guessable anyway, and it
reveals nothing about what the machine is. But it is not *nothing*, and it is worth being deliberate
about rather than surprised by. If that bothers you, a tunnel keeps the address private.

### The token is a credential

Whoever holds your DuckDNS token can repoint the subdomain anywhere, and can satisfy DNS-01
challenges for it — which means they can obtain valid certificates for your name. Treat it like a
password:

```bash
sudo chmod 640 /etc/caddy/Caddyfile
```

Rotate it if it ever appears in a chat log, a screenshot, a commit, or a terminal recording.

## Renewal

Caddy handles this automatically. It re-runs the same DNS-01 flow well before the 90-day expiry, and
because `propagation_timeout -1` is in the config, renewals succeed on the campus network exactly the
way the first issuance did.

Certificates and keys live in `/var/lib/caddy/.local/share/caddy/`. Deleting that directory forces a
clean retry from scratch, which is the right move if issuance ever gets stuck — notably if Caddy has
fallen back to Let's Encrypt's **staging** endpoint after repeated failures. Staging certificates are
signed by an untrusted root, so a browser will still reject them; if the logs mention
`acme-staging-v02`, clear the directory and restart.

## Where to go next

- [quick-guide.md](quick-guide.md) — the whole sequence as copy-pasteable commands
- [04-serving-the-box.md](04-serving-the-box.md) — Caddy, systemd, and the relay in detail
- [05-troubleshooting.md](05-troubleshooting.md) — every error hit along the way, with the actual fix
- [01-the-hosting-problem.md](01-the-hosting-problem.md) — why the page and the relay are separate jobs
- [../04-web-export-and-hosting.md](../04-web-export-and-hosting.md) — export presets and build sizes
