module Test.Main where

import Prelude

import Data.Array (foldl)
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Console (log)
import Helm.Midi (controlChange, unsafeCC, unsafeChannel, unsafeMidiValue)
import Helm.Twister (TwisterMsg(..), layerOf, colour, colourBrightness, parse, ring, ringBrightness)
import Helm.Twister.Guard (Event(..), empty, step, timing)
import Test.Assert (assertEqual)

-- | Run events through the guard and collect everything it delivered.
-- | Delays are not simulated: a test feeds the due events itself, in the
-- | order the clock would.
run :: Array Event -> Array TwisterMsg
run evs = (foldl go { g: empty, out: [] } evs).out
  where
  go acc ev = let s = step timing ev acc.g in { g: s.guard, out: acc.out <> s.deliver }

main :: Effect Unit
main = do
  let k0 = { layer: 0, index: 0 }
      k5 = { layer: 1, index: 5 }

  -- Decoding
  assertEqual { actual: parse [ 0xB0, 0, 64 ], expected: Just (Turn k0 64) }
  assertEqual { actual: parse [ 0xB0, 21, 3 ], expected: Just (Turn k5 3) }
  assertEqual { actual: parse [ 0xB1, 21, 127 ], expected: Just (Press k5) }
  assertEqual { actual: parse [ 0xB1, 21, 0 ], expected: Just (Release k5) }
  assertEqual { actual: parse [ 0xB4, 9, 127 ], expected: Just (Side 1) }
  assertEqual { actual: parse [ 0x90, 0, 64 ], expected: Nothing }
  assertEqual { actual: layerOf [ 0xB0, 50, 1 ], expected: Just 3 }
  assertEqual { actual: layerOf [ 0xB4, 9, 127 ], expected: Nothing }

  -- Lights
  assertEqual { actual: ring k5 200, expected: [ 0xB0, 21, 127 ] }
  assertEqual { actual: colour k5 40, expected: [ 0xB1, 21, 40 ] }
  assertEqual { actual: ringBrightness k5 0, expected: [ 0xB2, 21, 65 ] }
  assertEqual { actual: colourBrightness k5 99, expected: [ 0xB2, 21, 47 ] }
  assertEqual
    { actual: controlChange (unsafeChannel 16) (unsafeCC 7) (unsafeMidiValue 100)
    , expected: [ 0xBF, 7, 100 ]
    }

  -- A burst of turns is delivered once, at where it ended up.
  assertEqual
    { actual: run [ Heard (Turn k0 60), Heard (Turn k0 61), Heard (Turn k0 62), TurnDue k0 ]
    , expected: [ Turn k0 62 ]
    }
  -- Only the first turn of a burst starts a timer.
  assertEqual
    { actual: (step timing (Heard (Turn k0 61)) (step timing (Heard (Turn k0 60)) empty).guard).after
    , expected: []
    }
  -- A press inside the window takes the nudge with it.
  assertEqual
    { actual: run [ Heard (Turn k0 63), Heard (Press k0), TurnDue k0 ]
    , expected: [ Press k0 ]
    }
  -- Held down: deaf for as long as the finger is, however long that is.
  assertEqual
    { actual: run [ Heard (Press k0), Heard (Turn k0 66), Heard (Release k0), Heard (Turn k0 65) ]
    , expected: [ Press k0, Release k0 ]
    }
  -- After the release's window, turns are heard again.
  assertEqual
    { actual: run [ Heard (Press k0), Heard (Release k0), GuardDue k0 1, Heard (Turn k0 70), TurnDue k0 ]
    , expected: [ Press k0, Release k0, Turn k0 70 ]
    }
  -- One encoder's press deafens only that encoder.
  assertEqual
    { actual: run [ Heard (Press k0), Heard (Turn k5 10), TurnDue k5 ]
    , expected: [ Press k0, Turn k5 10 ]
    }

  -- A stale release clock does not clear a later press's guard: press,
  -- release, press and hold, and the first release's window closes under
  -- the finger.
  assertEqual
    { actual: run
        [ Heard (Press k0), Heard (Release k0), Heard (Press k0), GuardDue k0 1
        , Heard (Turn k0 66), TurnDue k0
        ]
    , expected: [ Press k0, Release k0, Press k0 ]
    }

  log "helm: all tests pass"
