-- | The conformance cases for the Helm hub's protocol, DECLARED by hand:
-- | which frames are well formed, and what the hub does in each situation.
-- | `Hub.Check` holds the reference codec to the first; `hub/conformance.mjs`
-- | holds `hub.mjs` to the second; `hub/conformance-client.mjs` holds
-- | `Helm/WebMIDI.js` to the frames an app writes.
module Hub.Cases
  ( Direction(..)
  , FrameCase
  , Step(..)
  , Scenario
  , frameCases
  , appFrames
  , scenarios
  ) where

import Prelude

import Data.Tuple (Tuple(..))
import Hub.Protocol (FromHub(..), ToHub(..))

data Direction = App | Hub

derive instance Eq Direction

-- | One frame as text, and whether a strict reader accepts it.
type FrameCase =
  { name :: String
  , direction :: Direction
  , text :: String
  , accept :: Boolean
  , why :: String
  }

-- | One thing that happens in a scenario. Connections are called `a`, `b`
-- | and `c`; the hub numbers them 1, 2 and 3 in the order they connect.
data Step
  -- | Open a connection. The hub then says who it is, lists the ports and
  -- | the claims, and those three frames must be the next `Hears`.
  = Connects String
  | Says String ToHub
  -- | A frame given as text, for what the type cannot say.
  | SaysText String String
  | Hears String FromHub
  -- | An `error` frame, whatever its text. The text is for people, and the
  -- | vectors do not pin it.
  | HearsError String
  -- | Close the connection.
  | Leaves String

type Scenario =
  { name :: String
  , why :: String
  , steps :: Array Step
  }

-- ── Frames ─────────────────────────────────────────────────────────────────

frameCases :: Array FrameCase
frameCases =
  -- What an app says.
  [ app "hello" """{"t":"hello","client":"pwyf"}""" true "names the app"
  , app "send" """{"t":"send","port":"Midi Fighter Twister","data":[176,3,64],"delayMs":0}""" true "three bytes, now"
  , app "send-later" """{"t":"send","port":"sink","data":[144,60,100],"delayMs":12.5}""" true "a delay need not be whole"
  , app "send-sysex" """{"t":"send","port":"sink","data":[240,0,33,36,247],"delayMs":0}""" true "any length of message"
  , app "claim" """{"t":"claim","port":"itajara:switches"}""" true "a name need not be a port"
  , app "grant" """{"t":"grant","port":"sink","to":"quadrat"}""" true "hand it on"
  , app "release" """{"t":"release","port":"sink"}""" true "let it go"
  , app "want" """{"t":"want","port":"sink"}""" true "ask for it"
  , app "refuse" """{"t":"refuse","port":"sink","to":"quadrat","why":"recording"}""" true "say no, and why"
  , app "refuse-no-reason" """{"t":"refuse","port":"sink","to":"quadrat","why":""}""" true "the reason may be empty, not absent"
  , app "watch" """{"t":"watch","port":"sink"}""" true "see what is sent"
  , app "unwatch" """{"t":"unwatch","port":"sink"}""" true "stop seeing it"
  , app "ask" """{"t":"ask","port":"sink","text":"page 3"}""" true "a request for the holder"
  , app "key-order" """{"port":"sink","t":"claim"}""" true "the order of keys carries nothing"
  , app "not-json" """claim sink""" false "frames are JSON"
  , app "not-an-object" """["claim","sink"]""" false "a frame is an object"
  , app "no-kind" """{"port":"sink"}""" false "every frame says what it is"
  , app "unknown-kind" """{"t":"seize","port":"sink"}""" false "not something an app says"
  , app "hub-kind" """{"t":"wanted","port":"sink","by":"pwyf"}""" false "only the hub says this"
  , app "claim-no-port" """{"t":"claim"}""" false "the name is required"
  , app "claim-port-number" """{"t":"claim","port":3}""" false "a name is a string"
  , app "claim-extra-field" """{"t":"claim","port":"sink","force":true}""" false "no undeclared fields"
  , app "send-no-bytes" """{"t":"send","port":"sink","data":[],"delayMs":0}""" false "one byte at least"
  , app "send-byte-too-large" """{"t":"send","port":"sink","data":[256],"delayMs":0}""" false "a byte is 0 to 255"
  , app "send-byte-negative" """{"t":"send","port":"sink","data":[-1],"delayMs":0}""" false "a byte is 0 to 255"
  , app "send-byte-fraction" """{"t":"send","port":"sink","data":[1.5],"delayMs":0}""" false "a byte is whole"
  , app "send-no-delay" """{"t":"send","port":"sink","data":[176,3,64]}""" false "a writer always gives the delay"
  , app "send-negative-delay" """{"t":"send","port":"sink","data":[176,3,64],"delayMs":-1}""" false "never in the past"
  , app "grant-no-recipient" """{"t":"grant","port":"sink"}""" false "to whom is required"
  , app "refuse-no-reason-field" """{"t":"refuse","port":"sink","to":"quadrat"}""" false "why is required, though it may be empty"
  -- What the hub says.
  , hub "ports" """{"t":"ports","inputs":[{"id":"loop","name":"loop"}],"outputs":[{"id":"loop","name":"loop"},{"id":"sink #2","name":"sink"}]}""" true "a second port of one name gets a numbered id"
  , hub "ports-none" """{"t":"ports","inputs":[],"outputs":[]}""" true "a machine with no MIDI"
  , hub "msg" """{"t":"msg","port":"loop","data":[176,3,64]}""" true "an input message"
  , hub "error" """{"t":"error","text":"no output named nowhere"}""" true "text for people"
  , hub "claims" """{"t":"claims","claims":{"sink":"pwyf"},"holders":{"sink":2}}""" true "by name and by connection"
  , hub "claims-none" """{"t":"claims","claims":{},"holders":{}}""" true "nothing is held"
  , hub "you" """{"t":"you","id":1}""" true "this connection's number"
  , hub "wanted" """{"t":"wanted","port":"sink","by":"quadrat"}""" true "to the holder"
  , hub "refused" """{"t":"refused","port":"sink","by":"pwyf","why":"recording"}""" true "to the one who wanted"
  , hub "sent" """{"t":"sent","port":"sink","data":[176,3,64],"by":"pwyf"}""" true "to a watcher"
  , hub "sent-replayed" """{"t":"sent","port":"sink","data":[176,3,64],"by":""}""" true "what the output last showed, from nobody"
  , hub "asked" """{"t":"asked","port":"sink","by":"pwyf","text":"page 3"}""" true "to the holder"
  , hub "app-kind" """{"t":"claim","port":"sink"}""" false "only an app says this"
  , hub "you-fraction" """{"t":"you","id":1.5}""" false "an id is whole"
  , hub "ports-no-outputs" """{"t":"ports","inputs":[]}""" false "both lists, always"
  , hub "ports-port-without-name" """{"t":"ports","inputs":[{"id":"loop"}],"outputs":[]}""" false "a port has an id and a name"
  , hub "claims-no-holders" """{"t":"claims","claims":{}}""" false "both tables, always"
  , hub "claims-holder-name" """{"t":"claims","claims":{"sink":"pwyf"},"holders":{"sink":"pwyf"}}""" false "holders are connection numbers"
  , hub "msg-no-bytes" """{"t":"msg","port":"loop","data":[]}""" false "one byte at least"
  , hub "sent-no-sender" """{"t":"sent","port":"sink","data":[176,3,64]}""" false "by is required, though it may be empty"
  ]
  where
  app name text accept why = { name, direction: App, text, accept, why }
  hub name text accept why = { name, direction: Hub, text, accept, why }

-- | One of every frame an app writes, for holding the client: each is made
-- | by calling the client's API, and what goes on the wire must be this.
appFrames :: Array ToHub
appFrames =
  [ Hello { client: "alpha" }
  , Claim { port: "sink" }
  , Release { port: "sink" }
  , Want { port: "itajara:switches" }
  , Grant { port: "sink", to: "beta" }
  , Refuse { port: "sink", to: "beta", why: "recording" }
  , Watch { port: "sink" }
  , Unwatch { port: "sink" }
  , Ask { port: "sink", text: "page 3" }
  , Send { port: "sink", bytes: [ 176, 3, 64 ], delayMs: 0.0 }
  ]

-- ── Scenarios ──────────────────────────────────────────────────────────────

-- | The ports of `hub/fake-midi.mjs`, which the hub is run on for these.
fakePorts :: FromHub
fakePorts = Ports
  { inputs: [ { id: "loop", name: "loop" } ]
  , outputs: [ { id: "loop", name: "loop" }, { id: "sink", name: "sink" } ]
  }

nobody :: FromHub
nobody = Claims { claims: [], holders: [] }

held :: String -> String -> Int -> FromHub
held port client connection = Claims { claims: [ Tuple port client ], holders: [ Tuple port connection ] }

-- | Connect, hear the three opening frames, and give a name.
joins :: String -> Int -> String -> FromHub -> Array Step
joins who connection client claims =
  [ Connects who
  , Hears who (You { id: connection })
  , Hears who fakePorts
  , Hears who claims
  , Says who (Hello { client })
  ]

alpha :: Array Step
alpha = joins "a" 1 "alpha" nobody

-- | `a` is alpha and `b` is beta, and nothing is held.
both :: Array Step
both = alpha <> joins "b" 2 "beta" nobody

-- | Both are connected and alpha holds `name`.
alphaHolds :: String -> Array Step
alphaHolds name =
  both <>
    [ Says "a" (Claim { port: name })
    , Hears "a" (held name "alpha" 1)
    , Hears "b" (held name "alpha" 1)
    ]

cc :: Array Int
cc = [ 176, 3, 64 ]

scenarios :: Array Scenario
scenarios =
  [ scenario "connecting" "the hub says who you are, what ports there are, and who holds what" alpha
  , scenario "claim-a-free-name" "a claim on a free name is granted, and everyone is told" (alphaHolds "twister")
  , scenario "claim-a-held-name" "a claim on a held name is an error to the claimer, and nothing changes"
      ( alphaHolds "twister" <>
          [ Says "b" (Claim { port: "twister" })
          , HearsError "b"
          ]
      )
  , scenario "claim-again" "the holder claiming again is told the claims again"
      ( alphaHolds "twister" <>
          [ Says "a" (Claim { port: "twister" })
          , Hears "a" (held "twister" "alpha" 1)
          , Hears "b" (held "twister" "alpha" 1)
          ]
      )
  , scenario "want-a-free-name" "wanting a free name is a claim"
      ( both <>
          [ Says "b" (Want { port: "twister" })
          , Hears "a" (held "twister" "beta" 2)
          , Hears "b" (held "twister" "beta" 2)
          ]
      )
  , scenario "want-a-held-name" "wanting a held name is passed to the holder, and to nobody else"
      ( alphaHolds "twister" <>
          [ Says "b" (Want { port: "twister" })
          , Hears "a" (Wanted { port: "twister", by: "beta" })
          ]
      )
  , scenario "want-what-you-hold" "the holder wanting its own name hears nothing"
      (alphaHolds "twister" <> [ Says "a" (Want { port: "twister" }) ])
  , scenario "grant" "the holder hands the name on, and everyone is told"
      ( alphaHolds "twister" <>
          [ Says "b" (Want { port: "twister" })
          , Hears "a" (Wanted { port: "twister", by: "beta" })
          , Says "a" (Grant { port: "twister", to: "beta" })
          , Hears "a" (held "twister" "beta" 2)
          , Hears "b" (held "twister" "beta" 2)
          ]
      )
  , scenario "refuse" "the holder says no, and the wanter hears why"
      ( alphaHolds "twister" <>
          [ Says "b" (Want { port: "twister" })
          , Hears "a" (Wanted { port: "twister", by: "beta" })
          , Says "a" (Refuse { port: "twister", to: "beta", why: "recording" })
          , Hears "b" (Refused { port: "twister", by: "alpha", why: "recording" })
          ]
      )
  , scenario "grant-without-holding" "only the holder can grant"
      ( alphaHolds "twister" <>
          [ Says "b" (Grant { port: "twister", to: "beta" })
          , HearsError "b"
          ]
      )
  , scenario "grant-to-nobody" "a grant to a name no client has is an error, and the holder keeps it"
      ( alphaHolds "twister" <>
          [ Says "a" (Grant { port: "twister", to: "gamma" })
          , HearsError "a"
          ]
      )
  , scenario "release" "the holder lets go, and everyone is told"
      ( alphaHolds "twister" <>
          [ Says "a" (Release { port: "twister" })
          , Hears "a" nobody
          , Hears "b" nobody
          ]
      )
  , scenario "release-without-holding" "a release by anyone else does nothing"
      (alphaHolds "twister" <> [ Says "b" (Release { port: "twister" }) ])
  , scenario "the-holder-leaves" "a claim ends with its connection"
      ( alphaHolds "twister" <>
          [ Leaves "a"
          , Hears "b" nobody
          ]
      )
  , scenario "a-latecomer" "a new connection is told the claims as they stand"
      (alphaHolds "twister" <> joins "c" 3 "gamma" (held "twister" "alpha" 1))
  , scenario "ask-the-holder" "a request reaches the holder with the asker's name"
      ( alphaHolds "twister" <>
          [ Says "b" (Ask { port: "twister", text: "page 3" })
          , Hears "a" (Asked { port: "twister", by: "beta", text: "page 3" })
          ]
      )
  , scenario "ask-nobody" "asking a name nobody holds is an error"
      (both <> [ Says "b" (Ask { port: "twister", text: "page 3" }), HearsError "b" ])
  , scenario "an-input-message" "what arrives on an input goes to every app"
      ( both <>
          [ Says "a" (Send { port: "loop", bytes: cc, delayMs: 0.0 })
          , Hears "a" (Msg { port: "loop", bytes: cc })
          , Hears "b" (Msg { port: "loop", bytes: cc })
          ]
      )
  , scenario "watching" "a watcher is told what others send, and the sender is not"
      ( both <>
          [ Says "b" (Watch { port: "sink" })
          , Says "a" (Send { port: "sink", bytes: cc, delayMs: 0.0 })
          , Hears "b" (Sent { port: "sink", bytes: cc, by: "alpha" })
          , Says "a" (Watch { port: "sink" })
          , Hears "a" (Sent { port: "sink", bytes: cc, by: "" })
          , Says "a" (Send { port: "sink", bytes: [ 176, 3, 65 ], delayMs: 0.0 })
          , Hears "b" (Sent { port: "sink", bytes: [ 176, 3, 65 ], by: "alpha" })
          ]
      )
  , scenario "a-new-watcher-sees-the-picture" "the last value of each control is replayed, from nobody; notes are not kept"
      ( both <>
          [ Says "a" (Send { port: "sink", bytes: [ 176, 3, 10 ], delayMs: 0.0 })
          , Says "a" (Send { port: "sink", bytes: [ 176, 3, 20 ], delayMs: 0.0 })
          , Says "a" (Send { port: "sink", bytes: [ 144, 60, 100 ], delayMs: 0.0 })
          , Says "b" (Watch { port: "sink" })
          , Hears "b" (Sent { port: "sink", bytes: [ 176, 3, 20 ], by: "" })
          ]
      )
  , scenario "unwatching" "after unwatching, nothing more is told"
      ( both <>
          [ Says "b" (Watch { port: "sink" })
          , Says "b" (Unwatch { port: "sink" })
          , Says "a" (Send { port: "sink", bytes: cc, delayMs: 0.0 })
          ]
      )
  , scenario "send-to-a-held-output" "only the holder's sends reach a claimed output, and the loser is told"
      ( alphaHolds "sink" <>
          [ Says "a" (Watch { port: "sink" })
          , Says "b" (Send { port: "sink", bytes: cc, delayMs: 0.0 })
          , HearsError "b"
          ]
      )
  , scenario "the-holder-sends" "the holder's own sends go through and are seen by watchers"
      ( alphaHolds "sink" <>
          [ Says "b" (Watch { port: "sink" })
          , Says "a" (Send { port: "sink", bytes: cc, delayMs: 0.0 })
          , Hears "b" (Sent { port: "sink", bytes: cc, by: "alpha" })
          ]
      )
  , scenario "send-to-no-output" "a send to a name that is not an output is an error"
      (alpha <> [ Says "a" (Send { port: "nowhere", bytes: cc, delayMs: 0.0 }), HearsError "a" ])
  , scenario "send-with-no-bytes" "the hub refuses an empty send"
      (alpha <> [ SaysText "a" """{"t":"send","port":"sink","data":[],"delayMs":0}""", HearsError "a" ])
  , scenario "not-json" "a frame that is not JSON is an error"
      (alpha <> [ SaysText "a" "claim sink", HearsError "a" ])
  , scenario "unknown-frame" "a frame of no known kind is an error"
      (alpha <> [ SaysText "a" """{"t":"seize","port":"sink"}""", HearsError "a" ])
  ]
  where
  scenario name why steps = { name, why, steps }
