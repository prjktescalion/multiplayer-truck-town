# Implementation notes

How single-player Truck Town became multiplayer, why each decision was made, and which things
turned out to be traps. Written for club members who want to read the code and change it.

| Document | Covers |
|---|---|
| [01-architecture.md](01-architecture.md) | The authority model, node topology, and why the server simulates nothing |
| [02-join-flow.md](02-join-flow.md) | A line-by-line trace of what happens when someone joins, spawns, and leaves |
| [03-changes-from-single-player.md](03-changes-from-single-player.md) | Every change to the original demo and the reason for it |
| [04-web-export-and-hosting.md](04-web-export-and-hosting.md) | The secure-context requirement, export settings, build sizes, deployment |
| [05-gotchas-and-verification.md](05-gotchas-and-verification.md) | Errors hit along the way, and how replication was actually proven to work |

## The 60-second version

Godot's high-level multiplayer (`MultiplayerSpawner`, `MultiplayerSynchronizer`, `@rpc`) does the
heavy lifting. Three decisions shape everything else:

1. **WebSocket transport, not ENet.** Browsers cannot open raw UDP sockets. Since phones join from
   Safari, `WebSocketMultiplayerPeer` is the only option, and it works for desktop too — one code
   path everywhere.

2. **Clients own their own trucks.** Each client simulates only its own truck and broadcasts the
   resulting transform. Nobody waits on a round trip to steer, which is what makes a phone over
   WiFi feel playable. Other players' trucks arrive as frozen kinematic bodies.

3. **The server is a dedicated relay.** Because clients are authoritative, the server simulates no
   physics at all — it forwards state and manages who exists. It holds no player, so it can run
   headless on a 512 MB cloud machine.

The cost of decision 2 is that a car-to-car collision resolves slightly differently on each screen.
For a club table with no competitive stakes, that is the right trade; see
[01-architecture.md](01-architecture.md) for what the alternative would have cost.
