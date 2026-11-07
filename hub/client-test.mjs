// Run: node hub/client-test.mjs (from helm/). Two onStateChange subscribers on hub access must both hear a port arrive.
import { WebSocketServer } from "ws";
const W = await import("../src/Helm/WebMIDI.js");
const wss = new WebSocketServer({ port: 3941 });
wss.on("connection", (s) => {
  s.send(JSON.stringify({ t: "ports", inputs: [{ id: "MC6", name: "MC6" }], outputs: [] }));
  setTimeout(() => s.send(JSON.stringify({ t: "ports", inputs: [{ id: "MC6", name: "MC6" }, { id: "Twister", name: "Twister" }], outputs: [] })), 100);
});
const heard = { first: [], second: [] };
W.requestHubAccessImpl("ws://127.0.0.1:3941", "test", 2000, (access) => {
  const un1 = W.onStateChangeImpl(access, (c) => heard.first.push(c.name));
  W.onStateChangeImpl(access, (c) => heard.second.push(c.name));
  setTimeout(() => {
    un1();
    access.inputs.delete("Twister"); // not via the hub; just checking un1 removed only the first
    console.log(JSON.stringify(heard));
    const ok = heard.first.join() === "Twister" && heard.second.join() === "Twister";
    console.log(ok ? "PASS both subscribers heard the new port" : "FAIL");
    process.exit(ok ? 0 : 1);
  }, 400);
}, (e) => { console.log("FAIL", e); process.exit(1); });
