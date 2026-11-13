// Drives the real hub (hub.mjs, on hub/fake-midi.mjs) through every vector
// Glassbox generates from conformance/machines/helm-claim.json: for each
// state, request and assignment of facts, the hub must refuse or not as the
// machine says, and leave the name held or free as the machine says.
//
// Run: node hub/conformance-machine.mjs   (from helm/), or `make conformance`.
//
// What a vector's parts mean here:
//   from     "held": connection a (alpha) has claimed the name. "free": nobody has.
//   facts    by-holder: the request is sent by a; otherwise by b (beta).
//            recipient-known: `to` names the other client; otherwise "nobody".
//   outcome  "refuse": the sender hears an error. Otherwise it hears none.
//   current  whether GET /state then lists the name as claimed.
// The refusal's tag is not checked: the hub's errors carry text for people
// and no tag.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { barrier, connect, here, sleep, startHub, state } from "./conformance-lib.mjs";

const file = JSON.parse(readFileSync(here("../conformance/machine-vectors/helm-claim.json"), "utf8"));
assert.equal(file["glassbox-vectors"], 1, "a vector format this replayer understands");
assert.ok(file.vectors.length > 0, "no vectors: nothing would be tested");

const NAME = "a-name";

const frameFor = (event, to) =>
  ({
    claim: { t: "claim", port: NAME },
    want: { t: "want", port: NAME },
    release: { t: "release", port: NAME },
    grant: { t: "grant", port: NAME, to },
    refuse: { t: "refuse", port: NAME, to, why: "" },
    ask: { t: "ask", port: NAME, text: "" },
  })[event];

const drive = async (vector, port) => {
  const hub = await startHub(port);
  const sockets = [];
  try {
    const a = await connect(port);
    const b = await connect(port);
    sockets.push(a, b);
    a.ws.send(JSON.stringify({ t: "hello", client: "alpha" }));
    b.ws.send(JSON.stringify({ t: "hello", client: "beta" }));
    if (vector.from === "held") a.ws.send(JSON.stringify({ t: "claim", port: NAME }));
    await barrier(a);
    await barrier(b);
    assert.equal(NAME in (await state(port)).claims, vector.from === "held", "the starting state could not be set up");
    a.heard.length = 0;
    b.heard.length = 0;

    const byHolder = vector.facts["by-holder"] === true;
    const sender = byHolder ? a : b;
    if (vector.event === "holder-gone") {
      a.ws.close();
      for (let tries = 0; (await state(port)).clients.length !== 1; tries++) {
        if (tries > 100) throw new Error("the hub did not notice the connection close");
        await sleep(10);
      }
    } else {
      const to = vector.facts["recipient-known"] === false ? "nobody" : byHolder ? "beta" : "alpha";
      sender.ws.send(JSON.stringify(frameFor(vector.event, to)));
      await barrier(sender);
    }

    const refused = sender.heard.some((frame) => frame.t === "error");
    assert.equal(refused, vector.outcome === "refuse", `the sender ${refused ? "heard" : "did not hear"} an error`);
    const held = NAME in (await state(port)).claims;
    assert.equal(held ? "held" : "free", vector.current, "the name's state afterwards");
  } finally {
    for (const socket of sockets) socket.ws.terminate();
    hub.kill();
  }
};

let failed = 0;
const skipped = [];
for (const [index, vector] of file.vectors.entries()) {
  const label = `${vector.from} + ${vector.event} ${JSON.stringify(vector.facts)}`;
  // Nobody holds a free name, so there is no holder to disconnect.
  if (vector.from === "free" && vector.event === "holder-gone") {
    skipped.push(label);
    continue;
  }
  try {
    await drive(vector, 39500 + index);
  } catch (error) {
    failed++;
    console.log(`FAIL  ${label}: ${error.message}`);
  }
}
for (const label of skipped) console.log(`skipped, cannot be driven: ${label}`);
console.log(`machine: ${file.vectors.length} vectors, ${skipped.length} skipped; ${failed} failures`);
process.exit(failed ? 1 : 0);
