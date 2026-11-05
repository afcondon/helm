// The one Web MIDI FFI. Everything here is a fix somebody paid for; the notes
// say who and why, and `Helm.WebMIDI` carries the longer versions.

// The spec says MIDIPort.id is a DOMString, and Chrome obliges. The Web MIDI
// shim in Web MIDI Browser on iOS returns a NUMBER, which stringifies
// identically for display and then fails `===` against the stored selection.
// So normalise to a string at the boundary, and fall back to the name for
// implementations that omit id altogether. (PWYF, 2026-08.)
const portId = (p) => {
  const id = p && p.id;
  if (id === undefined || id === null || id === "") return String(p && p.name);
  return String(id);
};

const portOf = (p) => ({ id: portId(p), name: String(p.name || "") });

// Never awaited from a handler: `requestMIDIAccess` does not resolve until the
// permission prompt is answered, and the prompt is in browser chrome where the
// page cannot show it. Callers get a callback and carry on. (Quadrat.)
export const requestAccessImpl = (sysex, onOk, onFail) => {
  if (!navigator.requestMIDIAccess) {
    onFail("Web MIDI is not available here (it needs a secure origin)");
    return;
  }
  navigator.requestMIDIAccess({ sysex }).then(
    (access) => onOk(access),
    (err) => onFail(String((err && err.message) || err))
  );
};

const list = (ports) => {
  const out = [];
  ports.forEach((p) => out.push(portOf(p)));
  return out;
};

export const outputsImpl = (access) => list(access.outputs);
export const inputsImpl = (access) => list(access.inputs);

// `match` is { tag: "exactly" | "contains", value }. "exactly" matches the
// normalised id or the whole name, as PWYF's stored selections need;
// "contains" is the first port whose name includes the text, as a device
// profile needs ("Twister", "IAC").
const find = (ports, match) => {
  let chosen = null;
  ports.forEach((p) => {
    if (chosen) return;
    const name = String(p.name || "");
    const hit =
      match.tag === "exactly"
        ? portId(p) === match.value || name === match.value
        : match.value === "" || name.indexOf(match.value) >= 0;
    if (hit) chosen = p;
  });
  return chosen;
};

export const findOutputImpl = (access, match) => find(access.outputs, match);
export const findInputImpl = (access, match) => find(access.inputs, match);

export const portOfImpl = (p) => portOf(p);

export const sendImpl = (out, bytes) => out.send(bytes);

// A timestamp on the performance clock; the browser holds the message until
// then. A past timestamp sends at once. (Binnacle.)
export const sendAtImpl = (out, bytes, atMs) => out.send(bytes, atMs);

export const nowImpl = () => performance.now();

// One listener per input, by assignment — which is also what opens the port
// implicitly in Chrome. The unsubscribe clears the handler only if it is still
// ours, so a re-subscribe is not clobbered by the old one's teardown.
// (Binnacle.)
export const onMessageImpl = (input, handler) => {
  const cb = (ev) => handler(Array.from(ev.data || []));
  input.onmidimessage = cb;
  return () => {
    if (input.onmidimessage === cb) input.onmidimessage = null;
  };
};

// Which port changed, and how. A port that reappears is a different MIDIPort
// object, and the handle held from before is dead and silent; knowing *which*
// port came back is what lets the app re-open the one it had selected. (PWYF.)
export const onStateChangeImpl = (access, handler) => {
  const cb = (ev) => {
    const p = ev && ev.port;
    handler({
      id: p ? portId(p) : "",
      name: p && p.name ? String(p.name) : "",
      state: p && p.state ? String(p.state) : "",
      portType: p && p.type ? String(p.type) : ""
    });
  };
  access.onstatechange = cb;
  return () => {
    if (access.onstatechange === cb) access.onstatechange = null;
  };
};

// ---- the hub ------------------------------------------------------------------
//
// Access through Helm's hub (`hub/hub.mjs`) instead of the browser: an object
// shaped like `MIDIAccess`, so every function above works on it unchanged and
// an app changes how it asks for access and nothing else. The hub holds the
// ports; this relays them.
//
// What it promises, as Web MIDI does:
// - `inputs` / `outputs` are Maps with `forEach`, of ports with `id`, `name`,
//   `type`, `state`; an input's `onmidimessage` gets `{ data }`; an output has
//   `send(bytes, atMs)`.
// - `onstatechange` fires with `{ port }` for each port that comes or goes,
//   including every port when the hub itself goes away and comes back, so an
//   app re-opens what it had chosen exactly as it does after a replug.
//
// Where it is better: a port's id is its name, the same after a replug and a
// hub restart, and a port object that stays is the same object.
//
// Access is granted on the first port list. If the hub is not there within
// `waitMs`, the request fails and says so: it never falls back to Web MIDI,
// since two owners of one controller is the problem the hub exists to end.
export const requestHubAccessImpl = (url, client, waitMs, onOk, onFail) => {
  const access = { inputs: new Map(), outputs: new Map(), onstatechange: null, sysexEnabled: true };
  // Who holds what, as the hub last said: name -> client name.
  access.claims = {};
  // Outputs this app has claimed. A claim ends with its connection, so they
  // are claimed again on every reconnect.
  const claimed = new Set();
  const say = (msg) => {
    if (ws && ws.readyState === 1) ws.send(JSON.stringify(msg));
  };
  access.claim = (id) => {
    claimed.add(id);
    say({ t: "claim", port: id });
  };
  access.release = (id) => {
    claimed.delete(id);
    say({ t: "release", port: id });
  };
  // This connection's id, and who holds what by connection: so an app can
  // tell "I hold it" from "another tab with my name holds it".
  access.self = null;
  access.holders = {};
  access.want = (id) => say({ t: "want", port: id });
  access.grant = (id, to) => say({ t: "grant", port: id, to });
  access.refuse = (id, to, why) => say({ t: "refuse", port: id, to, why });
  // Listeners: (port, by) when someone wants a name we hold; (port, by, why)
  // when a holder refused us; () whenever the claims change.
  access.onWanted = new Set();
  access.onRefused = new Set();
  access.onClaims = new Set();
  let ws = null;
  let granted = false;
  let failed = false;
  let warned = false;

  const fire = (port) => {
    if (access.onstatechange) access.onstatechange({ port });
  };

  const makeInput = (id, name) => ({ id, name, type: "input", state: "connected", connection: "open", onmidimessage: null });
  const makeOutput = (id, name) => ({
    id,
    name,
    type: "output",
    state: "connected",
    connection: "open",
    send(data, atMs) {
      if (!ws || ws.readyState !== 1) {
        if (!warned) console.warn("Helm hub: not connected; a send to " + id + " was dropped");
        warned = true;
        return;
      }
      const delayMs = typeof atMs === "number" ? Math.max(0, atMs - performance.now()) : 0;
      ws.send(JSON.stringify({ t: "send", port: id, data: Array.from(data), delayMs }));
    }
  });

  const update = (map, listed, make) => {
    const ids = new Set(listed.map((p) => p.id));
    for (const [id, port] of Array.from(map.entries())) {
      if (!ids.has(id)) {
        map.delete(id);
        port.state = "disconnected";
        fire(port);
      }
    }
    for (const p of listed) {
      if (!map.has(p.id)) {
        const port = make(p.id, p.name);
        map.set(p.id, port);
        fire(port);
      }
    }
  };

  const dropAll = () => {
    update(access.inputs, [], makeInput);
    update(access.outputs, [], makeOutput);
  };

  const connect = () => {
    ws = new WebSocket(url);
    ws.onopen = () => {
      warned = false;
      ws.send(JSON.stringify({ t: "hello", client }));
      claimed.forEach((id) => ws.send(JSON.stringify({ t: "claim", port: id })));
    };
    ws.onmessage = (ev) => {
      let m;
      try {
        m = JSON.parse(ev.data);
      } catch (e) {
        return;
      }
      if (failed) return;
      if (m.t === "ports") {
        update(access.inputs, m.inputs || [], makeInput);
        update(access.outputs, m.outputs || [], makeOutput);
        if (!granted) {
          granted = true;
          onOk(access);
        }
      } else if (m.t === "msg") {
        const port = access.inputs.get(m.port);
        if (port && port.onmidimessage) port.onmidimessage({ data: Uint8Array.from(m.data) });
      } else if (m.t === "you") {
        access.self = m.id;
      } else if (m.t === "claims") {
        access.claims = m.claims || {};
        access.holders = m.holders || {};
        access.onClaims.forEach((k) => k());
      } else if (m.t === "wanted") {
        access.onWanted.forEach((k) => k(String(m.port), String(m.by)));
      } else if (m.t === "refused") {
        access.onRefused.forEach((k) => k(String(m.port), String(m.by), String(m.why || "")));
      } else if (m.t === "error") {
        console.error("Helm hub: " + m.text);
      }
    };
    // Before access is granted, keep trying until `waitMs` runs out; after,
    // for ever, since an app holding access expects its ports to come back.
    //
    // From whichever of `close` and `error` arrives, once: a browser fires
    // both for a refused connection, and Node's WebSocket only `error`.
    const socket = ws;
    let ended = false;
    const lost = () => {
      if (ended || socket !== ws) return;
      ended = true;
      dropAll();
      if (!failed) setTimeout(connect, 1000);
    };
    ws.onclose = lost;
    ws.onerror = lost;
  };

  setTimeout(() => {
    if (granted) return;
    failed = true;
    if (ws) ws.close();
    onFail("Helm's hub is not answering at " + url + " (is it running?)");
  }, waitMs);
  connect();
};

// Claims exist only on the hub. Through the browser's Web MIDI there is no one
// to claim from, so these do nothing there.
export const claimOutputImpl = (access, out) => {
  if (access && typeof access.claim === "function") access.claim(portId(out));
};

export const releaseOutputImpl = (access, out) => {
  if (access && typeof access.release === "function") access.release(portId(out));
};

export const claimNameImpl = (access, name) => {
  if (access && typeof access.claim === "function") access.claim(name);
};

export const releaseNameImpl = (access, name) => {
  if (access && typeof access.release === "function") access.release(name);
};

export const viaHubImpl = (access) => !!(access && typeof access.want === "function");

export const holdingImpl = (access, name) =>
  !!(access && access.self !== null && access.holders && access.holders[name] === access.self);

export const wantNameImpl = (access, name) => {
  if (access && typeof access.want === "function") access.want(name);
};

export const grantNameImpl = (access, name, to) => {
  if (access && typeof access.grant === "function") access.grant(name, to);
};

export const refuseWantImpl = (access, name, to, why) => {
  if (access && typeof access.refuse === "function") access.refuse(name, to, why);
};

// Each returns its own unsubscribe. Through Web MIDI nothing is ever said.
const listen = (set, k) => {
  if (!set) return () => {};
  set.add(k);
  return () => set.delete(k);
};

export const onWantedImpl = (access, k) =>
  listen(access && access.onWanted, (port, by) => k(port)(by)());

export const onRefusedImpl = (access, k) =>
  listen(access && access.onRefused, (port, by, why) => k(port)(by)(why)());

export const onClaimsImpl = (access, k) => listen(access && access.onClaims, () => k());

export const holderOfImpl = (access, name) => {
  const c = access && access.claims;
  return c && typeof c[name] === "string" ? c[name] : null;
};
