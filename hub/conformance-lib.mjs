// What the hub's replays share: starting the real hub on fake MIDI, a
// connection that records what it hears, and a barrier that says the hub
// has read everything a connection has sent.

import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { WebSocket } from "ws";

export const here = (path) => fileURLToPath(new URL(path, import.meta.url));

export const HEAR_MS = 1500;
export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export const state = async (port) => (await fetch(`http://127.0.0.1:${port}/state`)).json();

export const startHub = async (port) => {
  // HELM_HUB_UNDER_TEST names another file in hub/, for checking that this
  // replay fails when the hub is changed.
  const hub = spawn(process.execPath, [here(process.env.HELM_HUB_UNDER_TEST || "hub.mjs")], {
    env: { ...process.env, PORT: String(port), HELM_HUB_FAKE_MIDI: "1" },
    stdio: "ignore",
  });
  for (let tries = 0; tries < 100; tries++) {
    try {
      await state(port);
      return hub;
    } catch {
      await sleep(20);
    }
  }
  hub.kill();
  throw new Error("the hub did not start");
};

// One connection: frames heard, in order, and a way to know the hub has
// read everything this connection has said so far.
export const connect = async (port) => {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const client = { ws, heard: [], waiting: null, barriers: new Map(), count: 0 };
  ws.on("message", (data) => {
    const frame = JSON.parse(String(data));
    // The reply to a barrier (below) is not part of the scenario.
    if (frame.t === "error")
      for (const [nonce, done] of client.barriers)
        if (frame.text.includes(nonce)) {
          client.barriers.delete(nonce);
          return done();
        }
    client.heard.push(frame);
    if (client.waiting) client.waiting();
  });
  await new Promise((resolve, reject) => {
    ws.on("open", resolve);
    ws.on("error", reject);
  });
  return client;
};

// Frames on one connection are read in order, so when the hub answers this
// one, it has read every frame sent before it. Asking a name nobody holds
// always answers, with an error that names it.
export const barrier = (client) =>
  new Promise((resolve, reject) => {
    const nonce = `barrier-${process.pid}-${++client.count}`;
    const timer = setTimeout(() => reject(new Error("the hub did not answer a barrier")), HEAR_MS);
    client.barriers.set(nonce, () => {
      clearTimeout(timer);
      resolve();
    });
    client.ws.send(JSON.stringify({ t: "ask", port: nonce, text: "" }));
  });

export const next = (client) =>
  new Promise((resolve, reject) => {
    if (client.heard.length) return resolve(client.heard.shift());
    const timer = setTimeout(() => {
      client.waiting = null;
      reject(new Error("heard nothing"));
    }, HEAR_MS);
    client.waiting = () => {
      clearTimeout(timer);
      client.waiting = null;
      resolve(client.heard.shift());
    };
  });
