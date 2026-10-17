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
