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
