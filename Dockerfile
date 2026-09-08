# The server binary is exported on your machine by `scripts/build_server.sh` before deploying,
# because Godot and its 1.3 GB of export templates don't belong in a deploy image.
FROM debian:bookworm-slim

RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY build/server/ /app/
RUN chmod +x /app/truck-town-server

EXPOSE 8910

# The dedicated server export carries the "dedicated_server" feature tag, which `net.gd` detects,
# so it starts listening without needing --server.
ENTRYPOINT ["/app/truck-town-server", "--headless", "--", "--server", "--port=8910"]
