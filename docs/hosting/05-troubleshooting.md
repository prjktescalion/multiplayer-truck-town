# Troubleshooting

Every failure actually hit while standing this up, in the order they appeared. Each one is
symptom → cause → fix, with the real error text, because the error text is what you will be
searching for at 11pm the night before a demo.

The general shape of all of these: **the failures are not where they appear to be.** A TLS error
turned out to be a typo, a certificate failure turned out to be a firewall rule, and a
"connection failed" turned out to be a service that was never created.

## `systemctl reload caddy` fails right after `caddy add-package`

```console
$ sudo systemctl reload caddy
Job for caddy.service failed.
See "systemctl status caddy.service" and "journalctl -xeu caddy.service" for details.
```

And then, confusingly:

```console
$ caddy list-modules | grep duckdns
dns.providers.duckdns
```

The module is clearly there. The config clearly uses it. The reload clearly fails.

**Cause.** `caddy add-package` replaces the binary **on disk**. It does not restart the running
process. So:

- `caddy list-modules` executes the *new* binary from disk, which has the module → prints it
- `systemctl reload` signals the *already-running* process, which is the *old* binary from before
  the swap, and tells it to load a config containing `dns duckdns` → it does not have that module →
  it rejects the config → the reload job fails

Two different binaries answering two different questions, which is exactly why the evidence looks
contradictory.

**Fix.** Reload never re-execs. Restart:

```bash
sudo systemctl restart caddy
```

**Generalisation worth keeping:** after anything that changes a binary rather than a config file,
restart rather than reload. `reload` is for configuration; `restart` is for code.

While iterating on the Caddyfile, prefer `validate` over `reload` — it gives a real parse error
instead of a generic job failure:

```bash
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

## TLS handshake fails with an internal error

```console
$ curl -I https://truck-town.duckdns.org
curl: (35) TLS connect error: error:0A000438:SSL routines::tlsv1 alert internal error
```

**Read this error for what it proves, not just what it says.** Reaching a TLS alert at all means
DNS resolved *and* a TCP connection to port 443 succeeded. So the record is published, the network
path works, and the resolver is not stripping the private address. Connectivity is fine. Only the
certificate is missing.

**Cause, in our case.** The Caddyfile said `trucktown.duckdns.org`; the actual registered name was
`truck-town.duckdns.org`. Caddy receives SNI for a hostname it has no site block for, cannot
produce a certificate to present, and aborts the handshake. It surfaces as an opaque internal
error rather than a helpful "unknown host", which is what makes it hard to read.

**Fix.** Make the names agree — and note there are *three* places, not one.

### The name has to agree in three places

| Place | Form | Requires |
|---|---|---|
| `/etc/caddy/Caddyfile` | `truck-town.duckdns.org` | `systemctl restart caddy` |
| `duckdns.service` (`domains=`) | `truck-town` — **bare label, no `.duckdns.org`** | `systemctl daemon-reload` |
| `net/net.gd` `DEFAULT_PUBLIC_SERVER_URL` | `wss://truck-town.duckdns.org/ws` | **rebuild and recopy** |

The third one is the trap. That constant is **compiled into the pck**, so fixing the source is not
enough:

```bash
cd ~/multiplayer-truck-town
sed -i 's|DEFAULT_PUBLIC_SERVER_URL := ".*"|DEFAULT_PUBLIC_SERVER_URL := "wss://truck-town.duckdns.org/ws"|' net/net.gd
export GODOT=~/bin/godot
./scripts/build_web.sh
sudo cp -R build/web/. /srv/trucktown/
```

Skip the rebuild and you get a page that loads perfectly over HTTPS and then fails to connect —
which reads as a relay problem and sends you debugging entirely the wrong service.

**The `domains=` field takes the bare label.** DuckDNS's API wants `domains=truck-town`, not
`domains=truck-town.duckdns.org`. Passing the full name silently updates nothing; the API returns
`KO` and the updater reports success because `curl -fsS` only fails on HTTP status, not on a body
that says no.

## The certificate never arrives — DNS-01 propagation timeout

This was the real one, and the only failure in this whole setup that is genuinely specific to being
on a campus network.

Caddy is running, the Caddyfile is correct, the name matches, and yet no certificate ever appears.
`journalctl -u caddy` shows the attempt looping:

```
{"level":"info","logger":"http.acme_client","msg":"trying to solve challenge",
 "identifier":"truck-town.duckdns.org","challenge_type":"dns-01"}

{"level":"error","logger":"tls.obtain","msg":"could not get certificate from issuer",
 "identifier":"truck-town.duckdns.org",
 "error":"[truck-town.duckdns.org] solving challenges: waiting for solver
  certmagic.solverWrapper to be ready: checking DNS propagation of
  \"_acme-challenge.truck-town.duckdns.org.\" (relative=_acme-challenge.truck-town
  zone=duckdns.org. resolvers=[127.0.0.53:53]): querying authoritative nameservers:
  dial tcp 15.223.21.81:53: i/o timeout"}

{"level":"error","logger":"tls.obtain","msg":"will retry","attempt":1,"retrying_in":60}
```

**Cause.** `15.223.21.81` is one of DuckDNS's authoritative nameservers. The sequence Caddy runs is:

1. Publish the `_acme-challenge` TXT record via the DuckDNS API — **this works** (HTTPS, port 443)
2. Verify the record is visible by querying DuckDNS's authoritative nameservers **directly on port
   53** — this times out
3. Never reach step 3, which would be telling Let's Encrypt to validate

Universities almost universally block outbound DNS to anything except their own resolvers. Normal
name resolution works fine, because that goes through the campus resolver; direct queries to
arbitrary nameservers on the internet do not.

The important part: **this is Caddy's own self-check failing, not the challenge.** Let's Encrypt's
validation servers are not behind the campus firewall and can read the TXT record without any
trouble. Caddy is refusing to hand off because it cannot personally confirm what it just published.

**Fix.** Skip the self-check and substitute a fixed wait:

```caddyfile
tls {
	dns duckdns YOUR_DUCKDNS_TOKEN
	propagation_delay 60s
	propagation_timeout -1
}
```

`propagation_timeout -1` disables propagation checking entirely. `propagation_delay 60s` waits a
fixed minute before handing off to Let's Encrypt — generous, since DuckDNS publishes essentially
instantly.

```bash
sudo systemctl restart caddy
sudo journalctl -u caddy -f
```

Expect roughly a minute of silence, then `certificate obtained successfully`.

An alternative that seems obvious and does not work here: adding `resolvers 1.1.1.1 8.8.8.8` to the
`tls` block. That changes *which* resolver is consulted, but it is still outbound DNS on port 53 to
a host that is not the campus resolver, so it hits the same firewall rule.

### The staging fallback

Watch for this in the same logs:

```
"ca":"https://acme-staging-v02.api.letsencrypt.org/directory"
```

After repeated production failures Caddy falls back to Let's Encrypt **staging**, which exists to
keep you from burning production rate limits while something is broken. It is a sensible behaviour
with one sharp edge: **staging certificates are signed by an untrusted root**, so even a
"successful" issuance leaves browsers rejecting the site — and now with a different error than the
one you were chasing.

Once the underlying mechanism is fixed, a restart normally returns to production. If it stays stuck
on staging, clear the ACME cache to force a clean start:

```bash
sudo systemctl stop caddy
sudo rm -rf /var/lib/caddy/.local/share/caddy/acme
sudo systemctl start caddy
```

This discards the cached staging account and any half-finished orders. It does not touch an already
valid production certificate, and Caddy simply re-obtains anything it needs.

## The page loads, but picking a truck says "Connection failed"

The most reassuring failure in the list, because it means TLS, DNS, and static serving are all
working. Caddy serves the page entirely on its own; it only involves the relay when the browser
opens the WebSocket. So the two halves fail independently, and you have just proven the first half.

In our case the answer was mundane: **the `trucktown.service` unit had never been created.**

```console
$ systemctl is-active trucktown
inactive
```

`systemctl is-active` reports `inactive` for a unit that does not exist, which reads identically to
a unit that exists and is stopped. `systemctl status` distinguishes them.

### Diagnostic ladder

Work down until something fails:

```bash
systemctl is-active trucktown          # is the service up?
sudo ss -lntp | grep 8910              # is anything listening?
```

Then test the proxy hop end to end:

```bash
curl -is -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" \
     -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     https://truck-town.duckdns.org/ws | head -5
```

| Response | Meaning | Fix |
|---|---|---|
| `101 Switching Protocols` | Proxy and relay both fine — the problem is client-side | Check `DEFAULT_PUBLIC_SERVER_URL` in the *built* pck, not the source |
| `502 Bad Gateway` | Caddy cannot reach `localhost:8910` | Relay is down, crashed, or bound to a different port |
| `404`, or a page of HTML | `handle_path /ws*` is not matching — you landed in the file server | Check the block order and the `/ws*` pattern in the Caddyfile |

**The fastest confirmation of all is the browser console.** A failed WebSocket appears as a red
line naming the exact URL it tried and the status it got. If the URL in that message is not the one
you expect, the pck is stale and needs rebuilding.

## Reading the logs

Both services log to the journal. These two commands answer most questions:

```bash
sudo journalctl -u caddy -f
sudo journalctl -u trucktown -f
```

### Caddy

A successful startup and issuance looks like:

```
msg=enabling automatic TLS certificate management domains=["truck-town.duckdns.org"]
logger=tls.obtain msg=acquiring lock identifier=truck-town.duckdns.org
logger=tls.obtain msg=obtaining certificate identifier=truck-town.duckdns.org
logger=http.acme_client msg=trying to solve challenge challenge_type=dns-01
logger=tls.obtain msg=certificate obtained successfully
```

Things worth recognising:

| Log line | Meaning |
|---|---|
| `Caddyfile input is not formatted` | Cosmetic only. `sudo caddy fmt --overwrite /etc/caddy/Caddyfile` |
| `server is listening only on the HTTPS port but has no TLS connection policies` | Normal; Caddy adds one automatically |
| `HTTP/2 skipped because it requires TLS` on `:80` | Normal; `:80` only does HTTP→HTTPS redirects |
| `admin endpoint started address=localhost:2019` | Correct — the admin API must stay on loopback |
| `waiting on internal rate limiter` | Normal ACME pacing, not an error |

### The relay

Startup, from `Net._start_dedicated_server()`:

```
Truck Town server listening on port 8910 (max 8 players)
```

If you do not see that line, the service is not running, regardless of what `systemctl` claims.

Each join, from `Net._register()`:

```
Peer 620806333 joined as Player (truck 0). Players: 1
Peer 1616897746 joined as Player (truck 1). Players: 2
```

And each departure, from `_on_peer_disconnected()`:

```
Peer 620806333 left. Players: 1
```

This is genuinely the most useful diagnostic in the project. The player count tells you whether the
relay sees what you think it sees, and watching it while someone taps a truck on their phone
localises a problem to one side of the connection in about two seconds.

Note that the `--headless` relay prints nothing per frame and nothing about transforms — the
synchronizers are silent by design. Absence of output after a join is correct behaviour, not a
hang.

## Things that look like errors and are not

- **`ObjectDB instances were leaked at exit`** on a client killed with `--quit-after`. An artefact
  of terminating mid-frame with an open peer and active tweens. See
  [../05-gotchas-and-verification.md](../05-gotchas-and-verification.md).
- **Caddy re-obtaining a certificate after a restart.** It checks validity on startup; if the cert
  is fine it uses the cached one and logs nothing interesting.
- **`storage cleaning happened too recently; skipping for now`.** Routine maintenance bookkeeping.

---

**See also:** [quick-guide.md](quick-guide.md) for the commands without the commentary,
[04-serving-the-box.md](04-serving-the-box.md) for what each piece is doing,
[02-secure-context-and-tls.md](02-secure-context-and-tls.md) for why HTTPS is non-negotiable,
[03-dns-01-and-duckdns.md](03-dns-01-and-duckdns.md) for how a private IP gets a real certificate,
and [quick-unhost.md](quick-unhost.md) to take it back down.
