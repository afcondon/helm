// Replays the scenarios of conformance/vectors/helm-hub.json against the
// real hub (hub.mjs), run on hub/fake-midi.mjs so that no MIDI port is
// touched. The declaration is conformance/HELM-HUB.md.
//
// Run: node hub/conformance.mjs   (from helm/), or `make conformance`.
// Not finding the vector file is a failure, not a skip.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { barrier, connect, here, next, sleep, startHub, state } from "./conformance-lib.mjs";

const vectors = JSON.parse(readFileSync(here("../conformance/vectors/helm-hub.json"), "utf8"));
assert.equal(vectors["helm-hub-vectors"], 1, "a vector format this replayer understands");
assert.ok(vectors.scenarios.length > 0, "no scenarios: nothing would be tested");

// The declaration names every kind of frame the vectors know.
const declaration = readFileSync(here("../conformance/HELM-HUB.md"), "utf8");
for (const kind of [...vectors.appSays, ...vectors.hubSays])
  assert.ok(declaration.includes(`| \`${kind}\` |`), `conformance/HELM-HUB.md has no row for ${kind}`);

const replay = async (scenario, port) => {
  const hub = await startHub(port);
  const clients = new Map();
  try {
    for (const [index, step] of scenario.steps.entries()) {
      const at = `step ${index + 1} ${JSON.stringify(step)}`;
      try {
        if (step.connects) {
          clients.set(step.connects, await connect(port));
        } else if (step.says) {
          const client = clients.get(step.says);
          client.ws.send(step.text !== undefined ? step.text : JSON.stringify(step.frame));
          await barrier(client);
        } else if (step.hears) {
          const frame = await next(clients.get(step.hears));
          if (step.anyText) {
            assert.equal(frame.t, step.frame.t);
            assert.equal(typeof frame.text, "string");
          } else assert.deepStrictEqual(frame, step.frame);
        } else if (step.leaves) {
          clients.get(step.leaves).ws.close();
          clients.delete(step.leaves);
          for (let tries = 0; (await state(port)).clients.length !== clients.size; tries++) {
            if (tries > 100) throw new Error("the hub did not notice the connection close");
            await sleep(10);
          }
        } else throw new Error("a step this replayer does not understand");
      } catch (error) {
        throw new Error(`${at}: ${error.message}`);
      }
    }
    // Nothing more: once the hub has read all that was said, every frame it
    // sent must have been expected by a step.
    for (const [name, client] of clients) {
      await barrier(client);
      assert.deepStrictEqual(client.heard, [], `${name} heard more than the scenario says`);
    }
  } finally {
    for (const client of clients.values()) client.ws.terminate();
    hub.kill();
  }
};

let failed = 0;
for (const [index, scenario] of vectors.scenarios.entries()) {
  try {
    await replay(scenario, 39400 + index);
  } catch (error) {
    failed++;
    console.log(`FAIL  ${scenario.name}: ${error.message}`);
  }
}
console.log(`hub: ${vectors.scenarios.length} scenarios; ${failed} failures`);
process.exit(failed ? 1 : 0);
