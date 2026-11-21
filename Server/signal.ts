// The watch party's signalling server: it puts apps that name the same room in touch, and
// passes along what they tell each other while they set up a direct connection. That is all it
// does. It never sees who is watching what: room names are derived from a secret it is not
// given, and what it relays is encrypted with a key derived from the same secret.
//
// One file, no dependencies. Runs wherever Deno runs:
//
//   deno run --allow-net --allow-env Server/signal.ts
//
// Settings (environment variables):
//   PORT          port to listen on (default 8787)
//   HOST          address to listen on (default 0.0.0.0; use 127.0.0.1 for a local check)
//   ROOM_LIMIT    people per room (default 8; the app connects everyone to everyone)
//   ICE_SERVERS   JSON list of the STUN/TURN servers the apps should use, in the form
//                 [{"urls":["stun:stun.example.org:3478"]}]. "[]" for none. Default: two public
//                 STUN servers. Takes precedence over the two below.
//   TURN_URLS     comma-separated TURN addresses of a relay you run (coturn with use-auth-secret)
//   TURN_SECRET   that relay's shared secret; each app is given a credential valid for six hours
//
// It must be reached over https (wss) from anywhere but the machine it runs on: put it behind a
// host or proxy that terminates TLS.

type IceServer = { urls: string[]; username?: string; credential?: string };
type Client = { socket: WebSocket; room?: string; peer?: string; recent: number[] };

const port = Number(Deno.env.get("PORT") ?? "8787");
const hostname = Deno.env.get("HOST") ?? "0.0.0.0";
const roomLimit = Number(Deno.env.get("ROOM_LIMIT") ?? "8");
const maxConnections = 5000;
const maxFrameLength = 64 * 1024;
// A connection setup is a few dozen frames; this is far above any honest use.
const framesPerTenSeconds = 400;
const idPattern = /^[a-z0-9-]{1,64}$/;
const roomPattern = /^[a-f0-9]{32}$/;

const defaultStun: IceServer[] = [
  { urls: ["stun:stun.cloudflare.com:3478"] },
  { urls: ["stun:stun.l.google.com:19302"] },
];

const rooms = new Map<string, Map<string, Client>>();
let connections = 0;

async function iceServers(): Promise<IceServer[]> {
  const fixed = Deno.env.get("ICE_SERVERS");
  if (fixed !== undefined) {
    try {
      const parsed = JSON.parse(fixed);
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }
  const servers = [...defaultStun];
  const turnUrls = (Deno.env.get("TURN_URLS") ?? "").split(",").map((url) => url.trim()).filter((url) => url);
  const secret = Deno.env.get("TURN_SECRET");
  if (turnUrls.length > 0 && secret) {
    // coturn's time-limited credentials: the user name is when it expires, the password its HMAC.
    const username = String(Math.floor(Date.now() / 1000) + 6 * 3600);
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
    const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(username)));
    const credential = btoa(String.fromCharCode(...signature));
    servers.push({ urls: turnUrls, username, credential });
  }
  return servers;
}

function send(client: Client, frame: Record<string, unknown>) {
  if (client.socket.readyState === WebSocket.OPEN) {
    client.socket.send(JSON.stringify(frame));
  }
}

function leave(client: Client) {
  const { room, peer } = client;
  client.room = undefined;
  if (!room || !peer) return;
  const members = rooms.get(room);
  // Only if this connection is still the one the room knows the person by: someone who
  // reconnects is already there again under the same name.
  if (!members || members.get(peer) !== client) return;
  members.delete(peer);
  if (members.size === 0) {
    rooms.delete(room);
    return;
  }
  for (const other of members.values()) send(other, { t: "peer-left", peer });
}

async function join(client: Client, room: unknown, peer: unknown) {
  if (typeof room !== "string" || typeof peer !== "string" || !roomPattern.test(room) || !idPattern.test(peer) || client.room) {
    send(client, { t: "error", code: "bad-request" });
    return;
  }
  const members = rooms.get(room) ?? new Map<string, Client>();
  const previous = members.get(peer);
  if (!previous && members.size >= roomLimit) {
    send(client, { t: "error", code: "room-full" });
    return;
  }
  const ice = await iceServers();
  if (client.socket.readyState !== WebSocket.OPEN) return;
  rooms.set(room, members);
  members.set(peer, client);
  client.room = room;
  client.peer = peer;
  const others = [...members.keys()].filter((id) => id !== peer);
  send(client, { t: "joined", peers: others, ice });
  if (previous) {
    // The same person again (their connection dropped and came back): the others already know them.
    previous.room = undefined;
    try { previous.socket.close(); } catch { /* already gone */ }
  } else {
    for (const id of others) send(members.get(id)!, { t: "peer-joined", peer });
  }
}

function handle(client: Client, text: string) {
  const now = Date.now();
  client.recent = client.recent.filter((time) => now - time < 10_000);
  client.recent.push(now);
  if (text.length > maxFrameLength || client.recent.length > framesPerTenSeconds) {
    client.socket.close(1008, "too much");
    return;
  }
  let frame: Record<string, unknown>;
  try {
    frame = JSON.parse(text);
  } catch {
    return;
  }
  switch (frame.t) {
    case "join":
      join(client, frame.room, frame.peer);
      break;
    case "to": {
      const target = client.room && typeof frame.peer === "string" ? rooms.get(client.room)?.get(frame.peer) : undefined;
      if (target && target !== client && typeof frame.data === "string") {
        send(target, { t: "from", peer: client.peer, data: frame.data });
      }
      break;
    }
    case "leave":
      client.socket.close();
      break;
  }
}

const page = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Watch party</title>
<body style="font: 16px/1.5 system-ui; max-width: 34em; margin: 4em auto; padding: 0 1em">
<h1 style="font-size: 1.4em">You have been invited to a watch party</h1>
<p>This link is an invitation, not a web page. Copy it from the address bar, then in the app choose
<b>File › Join Watch Party…</b> and paste it there.</p>`;

Deno.serve({ port, hostname }, (request) => {
  if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    const path = new URL(request.url).pathname;
    if (path === "/healthz") return new Response("ok\n");
    return new Response(page, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
  }
  if (connections >= maxConnections) return new Response("busy\n", { status: 503 });
  const { socket, response } = Deno.upgradeWebSocket(request);
  const client: Client = { socket, recent: [] };
  connections += 1;
  // Someone who connects and never says which room they want is not kept.
  const unjoined = setTimeout(() => {
    if (!client.room) socket.close(1008, "no room");
  }, 15_000);
  socket.onmessage = (event) => {
    if (typeof event.data === "string") handle(client, event.data);
  };
  socket.onclose = () => {
    clearTimeout(unjoined);
    connections -= 1;
    leave(client);
  };
  socket.onerror = () => {};
  return response;
});
