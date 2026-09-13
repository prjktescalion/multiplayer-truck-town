# Quick guide: taking it all back down

Every command to return the box to roughly the state it was in before
[quick-guide.md](quick-guide.md), in an order that never leaves you half-exposed.

[06-teardown-deep-dive.md](06-teardown-deep-dive.md) explains what each step is undoing and why the
order matters. This file is the sequence.

**Time:** about ten minutes.

Replace `truck-town`, `enp2s0` and `youruser` with your own values throughout.

---

## Decide what you're actually doing

Three different jobs, and most people want the first:

| Goal | Do |
|---|---|
| Stop hosting for now, keep it easy to bring back | Steps 1–2 only |
| Remove the game, keep the box improvements | Steps 1–6 |
| Return the box to its prior state as closely as possible | Everything |

Stopping the services is instant and completely reversible. Everything after that trades
reversibility for tidiness.

---

## Step 1 — Stop serving, gracefully

Players get disconnected the moment the relay stops, and the client shows
*"Server closed the connection."* That is the designed behaviour, not an error — but if people are
mid-game, tell them first.

```bash
journalctl -u trucktown -f      # watch until nobody is connected
```

Then:

```bash
sudo systemctl stop trucktown caddy
sudo systemctl disable trucktown caddy
```

**If you only wanted to pause hosting, stop here.** `sudo systemctl enable --now caddy trucktown`
brings it all back.

---

## Step 2 — Stop the DuckDNS updater

Skip if you never created it.

```bash
sudo systemctl stop duckdns.timer duckdns.service
sudo systemctl disable duckdns.timer
```

---

## Step 3 — Remove the systemd units

```bash
sudo rm -f /etc/systemd/system/trucktown.service
sudo rm -f /etc/systemd/system/duckdns.service
sudo rm -f /etc/systemd/system/duckdns.timer
sudo systemctl daemon-reload
sudo systemctl reset-failed
```

`DynamicUser=yes` accounts are transient, so there is no leftover user or group to delete.

---

## Step 4 — Remove Caddy

The config holds your DuckDNS token, so this step is also credential cleanup — though the real
revocation is Step 8.

```bash
sudo apt purge -y caddy
sudo rm -f /etc/apt/sources.list.d/caddy-stable.list
sudo rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
sudo apt update

# ACME account keys, issued certificates, autosaved config
sudo rm -rf /var/lib/caddy
sudo rm -rf /etc/caddy
```

`apt purge` removes the packaged binary. The one `caddy add-package` installed lives at the same
path, so this clears it too — but check, because a manually downloaded binary would not be tracked
by apt:

```bash
command -v caddy || echo "caddy is gone"
```

---

## Step 5 — Remove the game content

```bash
sudo rm -rf /srv/trucktown /srv/trucktown-server
```

---

## Step 6 — Remove the Godot toolchain

Purely a disk-space decision — roughly 1.5 GB. Keep it if you might rebuild.

```bash
rm -rf ~/.local/share/godot/export_templates/4.7.1.stable
rm -f ~/bin/godot
rm -f ~/Godot_v4.7.1-stable_linux.x86_64.zip
rm -f ~/Godot_v4.7.1-stable_export_templates.tpz
```

And the clone, including its import cache and build output:

```bash
rm -rf ~/multiplayer-truck-town
```

If you want to keep the repo but drop the generated files:

```bash
cd ~/multiplayer-truck-town && rm -rf .godot build && git checkout net/net.gd
```

That last `checkout` reverts the `DEFAULT_PUBLIC_SERVER_URL` edit.

---

## Step 7 — The firewall

**Think before running this.** ufw is a net improvement to a box exposed on a campus network, and
nothing about removing the game requires removing it.

Keep it, but drop the rules you no longer need:

```bash
sudo ufw delete allow 80/tcp
sudo ufw delete allow 443/tcp
sudo ufw status verbose
```

Only if ufw was not enabled before you started and you genuinely want it gone:

```bash
sudo ufw disable          # never run this without confirming you can still reach the box
```

Same for `fail2ban`, if you installed it — worth keeping.

---

## Step 8 — External cleanup

None of this is on the box, so none of it is removed by anything above.

**Rotate the DuckDNS token.** It has been sitting in `/etc/caddy/Caddyfile`, probably in a systemd
unit, and almost certainly in your shell history. Deleting those files does not invalidate it.
Regenerate it on your DuckDNS account page — that is the actual revocation.

**Delete or re-point the subdomain.** Keeping it costs nothing and makes it trivial to host again.
If you delete it, the name stops resolving and becomes available to someone else.

**Clear your shell history** if you pasted the token into a terminal:

```bash
history | grep -n duckdns          # find them
history -d <line-number>           # remove individually
# or: rm -f ~/.bash_history && history -c
```

---

## Step 9 — Verify

```bash
sudo ss -lntp                      # no 8910, no caddy on 80/443
systemctl list-units --all | grep -E 'caddy|trucktown|duckdns'   # expect nothing
curl -sI --max-time 5 https://truck-town.duckdns.org || echo "unreachable, as expected"
dig +short truck-town.duckdns.org  # empty if you deleted the record
df -h ~                            # confirm the space came back
```

If you kept the repo, confirm the working tree is clean:

```bash
cd ~/multiplayer-truck-town && git status --short
```

---

## What you cannot undo

Every certificate Let's Encrypt issues is published in **Certificate Transparency logs**, which are
append-only and public forever. `truck-town.duckdns.org` and the fact that it existed are now a
permanent matter of public record, searchable at [crt.sh](https://crt.sh).

This is normal and applies to every HTTPS site on the internet. Revoking a certificate invalidates
it; it does not remove the log entry. Nothing about your box's address or contents is in there —
just the hostname and timestamps.

Worth knowing before you pick a subdomain name you'd rather not have published.
