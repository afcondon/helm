# Helm

Every hardware controller, under one banner. Shared by
producing-with-your-feet and Triggerfish; neither owns it.

Plan: `~/work/afc-work/docs/kb/plans/helm.md`.

| Layer | Here | Status |
|---|---|---|
| Device profiles — how messages decode, what the lights take, the quirks | `Helm.Twister`, `Helm.Twister.Guard` | Twister, Phase 1 |
| The one Web MIDI FFI | `Helm.WebMIDI`, `Helm.Midi` | Phase 1 |
| Device configs — typed model compiled to the device | — | BCR-2000 (Phase 2), MC6 (Phase 3) |
| Bindings — what a knob *means* | stays in each app | — |

```
spago build && spago test
```

Consumers reach it by path (`extraPackages: helm: { path: ../helm }`).

## Licence

MIT. See `LICENSE`.

## The hub

`hub/hub.mjs` is the one process that holds the rig's MIDI controllers, so
that PWYF, Quadrat and Triggerfish can share them (plan:
`docs/kb/plans/quadrat-the-sampler.md`, phase 3). It opens every MIDI port on
the machine and relays them over a WebSocket on **:3039**; `GET /state` says
which ports, which apps, and what went wrong last.

An app asks for access with `Helm.WebMIDI.requestHubAccess` instead of
`requestAccess` and gets a `MIDIAccess` like any other: every function in
`Helm.WebMIDI` works on it unchanged. It never falls back to Web MIDI.

Supervised by Bosun in the Atlantis group (`helm-hub`). `npm install` once in
`hub/`; no build step.

**Claims.** A device with no read-back (the Twister) can be held by one app:
`Helm.WebMIDI.claimOutput access out` sends `{t:"claim"}` and the hub then
passes only that connection's sends to the port. Anyone else's are dropped
and reported to the sender, naming the holder, once per run of refusals, and
counted as `refused` in `/state`. A claim belongs to a *connection*, not a
name, so a second tab of the same app is refused too; it lapses when the
connection closes, and the holder can hand it on by name (`grant`). The hub
client re-claims after a reconnect. Inputs are not claimed: every client still
hears the Twister's knobs. Tested on hardware 2026-11-05.

**Asking for a held name.** `wantName` claims a free name; for a held one the
hub passes `wanted` to the holder, which answers with `grantName` or
`refuseWant` (the wanter hears `refused`, with the reason). The hub decides
nothing: who *ought* to hold a name is the holders' business. Each client is
told its own connection id, and claims carry holders by id as well as by name,
so `holding access name` answers "is it this connection", which two tabs with
one name could not tell from `holderOf`. `onClaims`, `onWanted` and
`onRefused` are the listeners.

**Watching an output.** `watchPort` tells a client every message the hub
delivers to that output, from whoever sends it (`onSent`: port, bytes), and
first replays the last value sent on each of its control changes, so a
watcher starts from the device's picture. Sends the hub refused are not
passed on. This is how a screen shows a controller it does not hold (PWYF's
Twister minimap while the looper's process holds it): subscribe to what the
device is shown, never reconstruct it. `askHolder` relays a request to
whoever holds a name (`onAsked`: name, asker, text); the hub does not read
the text.
