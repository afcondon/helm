// Helm's hub: the one process that holds the rig's MIDI controllers.
//
// Every app on the rig wants the MC6 and the Twister, and a browser tab cannot
// share them: the Twister has no read-back, so two writers are last-writer-
// wins and the loser is never told, and a background tab's timers are
// throttled to once a second, so a looper in a tab you are not looking at is a
// dead looper. The answer (DESIGN-LOOPER §21, "move the hub down"; plan
// `docs/kb/plans/quadrat-the-sampler.md`) is one daemon that holds the ports,
// with every app a client of it.
//
// This is phase 3b: **transport only.** The hub opens every MIDI input and
// output on the machine and relays them, byte for byte, over a WebSocket.
// The browser side is `Helm.WebMIDI.requestHubAccess`, which hands an app an
// object shaped like Web MIDI's `MIDIAccess`, so an app changes how it gets
// access and nothing else. What a press *means* moves in here in 3c.
//
// Protocol, JSON text frames:
//
//   hub -> app   {t:"ports", inputs:[{id,name}], outputs:[{id,name}]}
//                  on connect, and again whenever the machine's ports change.
//                  The app diffs the lists; the hub sends no per-port events.
//                {t:"msg", port, data:[bytes]}   every input message, to all.
//                {t:"error", text}               a send that could not go.
//                {t:"claims", claims:{port: client}}  who holds which output,
//                  on connect and whenever it changes.
//   app -> hub   {t:"hello", client}             names the app in /state.
//                {t:"send", port, data:[bytes], delayMs}
//                {t:"claim", port}               hold an output: only the
//                  holder's sends reach it. Granted if no live client holds it.
//                {t:"grant", port, to}           the holder hands it to `to`.
//                {t:"release", port}
//
// A port's id is its name (with " #2" for a second port of the same name),
// so it is the same across a replug and across a hub restart, which Web
// MIDI's ids are not.
//
// HTTP on the same port: GET /state for the Dashboard (ports, clients, counts).
//
// **Claims** are for a device with no read-back, the Twister first: two
// writers are last-writer-wins and the loser is never told. A claimed output
// takes the holder's sends only; anyone else's are dropped AND reported, to
// that sender, naming the holder, so losing is never silent. A claim is held
// by one connection, not by a name: two PWYF tabs are both "pwyf", and sharing
// the Twister between them is the problem this exists to end. It ends when
// that connection does. Unclaimed outputs take anyone's sends, as before.
//
// A claim is on a NAME, and most names are outputs. A name that is not a port
// claims a responsibility instead: `itajara:switches` is held by whichever
// process is answering the looper's footswitches, so a page that could also
// answer them reads `claims` and stands back. The hub treats both alike.
//
// Not yet: the MC6 session as a lease. PWYF opens and closes its own sessions
// around every write, so the hub cannot hold one without owning MC6 session
// framing, which is Helm's phase 3 (the MC6 code moving into Helm).

import http from "node:http";
import midi from "@julusian/midi";
import { WebSocketServer } from "ws";

const PORT = Number(process.env.PORT || 3039);
const POLL_MS = 1000;
const started = new Date().toISOString();

// ---- ports ------------------------------------------------------------------

// Names as the machine lists them, made unique: identity is the name, and a
// second device of the same model gets " #2".
const listNames = (probe) => {
  const seen = new Map();
  const out = [];
  for (let i = 0; i < probe.getPortCount(); i++) {
    const name = probe.getPortName(i);
    const n = (seen.get(name) || 0) + 1;
    seen.set(name, n);
    out.push({ id: n === 1 ? name : `${name} #${n}`, name, index: i });
  }
  return out;
};

const inProbe = new midi.Input();
const outProbe = new midi.Output();

let inputs = []; // [{id, name, index}]
let outputs = [];
const openInputs = new Map(); // id -> midi.Input
const openOutputs = new Map(); // id -> midi.Output

const counts = { in: 0, out: 0, errors: 0 };
const lastError = { text: "", at: "" };

const sameList = (a, b) =>
  a.length === b.length && a.every((p, i) => p.id === b[i].id && p.index === b[i].index);

// Every input is opened, always: the hub hears everything, and an app chooses
// what to listen to by which port's handler it sets. SysEx is let through (the
// MC6 talks in it); clock and active sensing are not, since no controller app
// wants 24 messages a beat it did not ask for.
const openAllInputs = () => {
  for (const [, inp] of openInputs) inp.closePort();
  openInputs.clear();
  for (const p of inputs) {
    const inp = new midi.Input();
    inp.ignoreTypes(false, true, true);
    inp.on("message", (_delta, data) => {
      counts.in++;
      broadcast({ t: "msg", port: p.id, data: Array.from(data) });
    });
    try {
      inp.openPort(p.index);
      openInputs.set(p.id, inp);
    } catch (e) {
      report(`could not open input ${p.id}: ${e.message}`);
    }
  }
};

// Outputs are opened on first send, and reopened by name after the list
// changes, because the index a port had is not the index it has now.
const outputFor = (id) => {
  const open = openOutputs.get(id);
  if (open) return open;
  const p = outputs.find((o) => o.id === id);
  if (!p) return null;
  const out = new midi.Output();
  out.openPort(p.index);
  openOutputs.set(id, out);
  return out;
};

const closeAllOutputs = () => {
  for (const [, out] of openOutputs) out.closePort();
  openOutputs.clear();
};

const portsMessage = () => ({
  t: "ports",
  inputs: inputs.map(({ id, name }) => ({ id, name })),
  outputs: outputs.map(({ id, name }) => ({ id, name })),
});

const scan = () => {
  const ins = listNames(inProbe);
  const outs = listNames(outProbe);
  const inChanged = !sameList(ins, inputs);
  const outChanged = !sameList(outs, outputs);
  if (!inChanged && !outChanged) return;
  const was = new Set([...inputs, ...outputs].map((p) => p.id));
  const now = new Set([...ins, ...outs].map((p) => p.id));
  for (const id of now) if (!was.has(id)) console.log(`port here: ${id}`);
  for (const id of was) if (!now.has(id)) console.log(`port gone: ${id}`);
  inputs = ins;
  outputs = outs;
  if (inChanged) openAllInputs();
  if (outChanged) closeAllOutputs();
  broadcast(portsMessage());
};

// ---- clients ----------------------------------------------------------------

const clients = new Set(); // {ws, name, since, sent, refused}
const claims = new Map(); // port id -> client (the connection, not its name)
let nextId = 1;

const claimsMessage = () => ({
  t: "claims",
  claims: Object.fromEntries([...claims].map(([port, c]) => [port, c.name])),
});

// A claim ends with its connection.
const dropClaimsOf = (client) => {
  let any = false;
  for (const [port, holder] of claims)
    if (holder === client) {
      claims.delete(port);
      console.log(`claim on ${port} lapsed: ${client.name} is gone`);
      any = true;
    }
  if (any) broadcast(claimsMessage());
};

const broadcast = (msg) => {
  const text = JSON.stringify(msg);
  for (const c of clients) if (c.ws.readyState === 1) c.ws.send(text);
};

const report = (text, client) => {
  counts.errors++;
  lastError.text = text;
  lastError.at = new Date().toISOString();
  console.error(text);
  if (client && client.ws.readyState === 1) client.ws.send(JSON.stringify({ t: "error", text }));
};

const sendNow = (client, port, data) => {
  const holder = claims.get(port);
  if (holder !== undefined && holder !== client) {
    client.refused = (client.refused || 0) + 1;
    // Said once per run of refusals, not per message: a Twister repaint is
    // thirty-two of them, and the point is that the sender learns, not that it
    // drowns.
    if (client.refused === 1 || client.lastRefusedPort !== port)
      report(`${port} is held by ${holder.name}; ${client.name}'s send was dropped`, client);
    client.lastRefusedPort = port;
    return;
  }
  client.lastRefusedPort = undefined;
  let out;
  try {
    out = outputFor(port);
  } catch (e) {
    return report(`could not open output ${port}: ${e.message}`, client);
  }
  if (!out) return report(`no output named ${port}`, client);
  try {
    out.sendMessage(data);
    counts.out++;
    client.sent++;
  } catch (e) {
    report(`send to ${port} failed: ${e.message}`, client);
  }
};

const onMessage = (client, text) => {
  let m;
  try {
    m = JSON.parse(text);
  } catch {
    return report("a frame that is not JSON", client);
  }
  switch (m.t) {
    case "hello":
      client.name = String(m.client || "unnamed");
      console.log(`client: ${client.name}`);
      return;
    case "claim": {
      const holder = claims.get(m.port);
      if (holder !== undefined && holder !== client)
        return report(`${m.port} is held by ${holder.name}; ${client.name} cannot claim it`, client);
      claims.set(m.port, client);
      console.log(`claim: ${m.port} -> ${client.name}`);
      broadcast(claimsMessage());
      return;
    }
    case "grant": {
      if (claims.get(m.port) !== client)
        return report(`${client.name} does not hold ${m.port}, so cannot grant it`, client);
      const to = [...clients].filter((c) => c.name === String(m.to));
      if (to.length !== 1)
        return report(`cannot grant ${m.port} to ${m.to}: ${to.length} clients have that name`, client);
      claims.set(m.port, to[0]);
      console.log(`grant: ${m.port} -> ${m.to} (from ${client.name})`);
      broadcast(claimsMessage());
      return;
    }
    case "release": {
      if (claims.get(m.port) === client) {
        claims.delete(m.port);
        console.log(`release: ${m.port} by ${client.name}`);
        broadcast(claimsMessage());
      }
      return;
    }
    case "send": {
      if (!Array.isArray(m.data) || m.data.length === 0) return report("a send with no bytes", client);
      const delay = Number(m.delayMs) || 0;
      if (delay > 1) setTimeout(() => sendNow(client, m.port, m.data), delay);
      else sendNow(client, m.port, m.data);
      return;
    }
    default:
      return report(`unknown frame ${m.t}`, client);
  }
};

// ---- server -----------------------------------------------------------------

const server = http.createServer((req, res) => {
  if (req.url === "/state") {
    res.writeHead(200, { "content-type": "application/json", "cache-control": "no-cache", "access-control-allow-origin": "*" });
    res.end(
      JSON.stringify({
        started,
        inputs: inputs.map((p) => p.id),
        outputs: outputs.map((p) => p.id),
        openOutputs: [...openOutputs.keys()],
        clients: [...clients].map((c) => ({ name: c.name, since: c.since, sent: c.sent, refused: c.refused })),
        claims: Object.fromEntries([...claims].map(([p, c]) => [p, `${c.name} (connection ${c.id})`])),
        counts,
        lastError,
      })
    );
    return;
  }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({ server });
wss.on("connection", (ws) => {
  const client = { ws, id: nextId++, name: "unnamed", since: new Date().toISOString(), sent: 0, refused: 0 };
  clients.add(client);
  ws.send(JSON.stringify(portsMessage()));
  ws.send(JSON.stringify(claimsMessage()));
  ws.on("message", (data) => onMessage(client, String(data)));
  ws.on("close", () => {
    clients.delete(client);
    dropClaimsOf(client);
    console.log(`client gone: ${client.name}`);
  });
});

scan();
const poll = setInterval(scan, POLL_MS);
server.listen(PORT, "127.0.0.1", () => {
  console.log(`helm hub on :${PORT}: ${inputs.length} inputs, ${outputs.length} outputs`);
  for (const p of inputs) console.log(`  in   ${p.id}`);
  for (const p of outputs) console.log(`  out  ${p.id}`);
});

// Drain on TERM (the bosun-daemon contract): close the ports so CoreMIDI is
// not left holding a client for a process that is gone.
const stop = () => {
  clearInterval(poll);
  for (const c of clients) c.ws.close(1001, "hub stopping");
  for (const [, inp] of openInputs) inp.closePort();
  closeAllOutputs();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1000).unref();
};
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
