// Holds the client half (src/Helm/WebMIDI.js) to
// conformance/vectors/helm-hub.json: each frame an app writes is made by
// calling the client's own API against a stand-in hub, and what arrives
// must be the declared frame. The declaration is conformance/HELM-HUB.md.
//
// Run: node hub/conformance-client.mjs   (from helm/), or `make conformance`.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { WebSocketServer } from "ws";

const here = (path) => fileURLToPath(new URL(path, import.meta.url));
const vectors = JSON.parse(readFileSync(here("../conformance/vectors/helm-hub.json"), "utf8"));
assert.equal(vectors["helm-hub-vectors"], 1, "a vector format this replayer understands");
assert.ok(vectors.appFrames.length > 0, "no app frames: nothing would be tested");

// HELM_CLIENT_UNDER_TEST names another file, for checking that this replay
// fails when the client is changed.
const clientFile = here(process.env.HELM_CLIENT_UNDER_TEST || "../src/Helm/WebMIDI.js");
const client = await import(clientFile);
const source = readFileSync(clientFile, "utf8");

// How each kind of frame is made through the client's API.
const make = {
  claim: (access, f) => access.claim(f.port),
  release: (access, f) => access.release(f.port),
  want: (access, f) => access.want(f.port),
  grant: (access, f) => access.grant(f.port, f.to),
  refuse: (access, f) => access.refuse(f.port, f.to, f.why),
  watch: (access, f) => access.watch(f.port),
  unwatch: (access, f) => access.unwatch(f.port),
  ask: (access, f) => access.ask(f.port, f.text),
  send: (access, f) => access.outputs.get(f.port).send(Uint8Array.from(f.data)),
};

const failures = [];

// Every kind an app may say has a way to be said here, so a kind added to
// the declaration without a client call fails.
for (const kind of vectors.appSays)
  if (kind !== "hello" && !make[kind]) failures.push(`no client call is known for ${kind}`);

// Every kind the hub may say is read somewhere in the client. A check of
// the source text, since most kinds have no effect visible from outside.
for (const kind of vectors.hubSays)
  if (!source.includes(`m.t === "${kind}"`)) failures.push(`the client does not read ${kind}`);

const hello = vectors.appFrames.find((f) => f.t === "hello");
const calls = vectors.appFrames.filter((f) => f.t !== "hello");
const outputs = [...new Set(calls.filter((f) => f.t === "send").map((f) => f.port))];

const heard = [];
const server = new WebSocketServer({ port: 39399 });
server.on("connection", (socket) => {
  socket.on("message", (data) => heard.push(JSON.parse(String(data))));
  socket.send(JSON.stringify({ t: "ports", inputs: [], outputs: outputs.map((id) => ({ id, name: id })) }));
});

const finish = () => {
  for (const failure of failures) console.log(`FAIL  ${failure}`);
  console.log(`client: ${vectors.appFrames.length} app frames, ${vectors.hubSays.length} hub kinds; ${failures.length} failures`);
  process.exit(failures.length ? 1 : 0);
};

client.requestHubAccessImpl(
  "ws://127.0.0.1:39399",
  hello.client,
  2000,
  (access) => {
    for (const frame of calls) if (make[frame.t]) make[frame.t](access, frame);
    setTimeout(() => {
      const expected = [hello, ...calls];
      expected.forEach((frame, index) => {
        try {
          assert.deepStrictEqual(heard[index], frame);
        } catch {
          failures.push(`${frame.t}: the client wrote ${JSON.stringify(heard[index])}, declared ${JSON.stringify(frame)}`);
        }
      });
      if (heard.length !== expected.length) failures.push(`the client wrote ${heard.length} frames, declared ${expected.length}`);
      finish();
    }, 300);
  },
  (error) => {
    failures.push(`the client did not get access: ${error}`);
    finish();
  }
);
