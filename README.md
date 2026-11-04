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
