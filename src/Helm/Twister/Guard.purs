-- | **You cannot press a Twister encoder without turning it.**
-- |
-- | The knob rotates a little on the way down (Andrew, having used it:
-- | *"virtually impossible"* not to), so a press arrives with a nudge beside
-- | it, and which of the two comes first is not decidable. Wherever a press
-- | selects something and a turn sets it, taking a thing in hand would quietly
-- | move it.
-- |
-- | So **a turn is withheld until it is clear it was not part of a press**,
-- | and a press deafens its own encoder for as long as the finger is down and
-- | a moment after. Two windows, because the nudge can land on either side:
-- |
-- | - A turn waits `turnHold` (60 ms). Everything inside the window overwrites
-- |   the value, so what is delivered is where the knob ended up. A press
-- |   inside the window takes the turn with it.
-- | - A press arms the guard with no timer; only the release disarms it, after
-- |   `pressGuard` (300 ms). An earlier version timed the guard from the
-- |   press, so holding an encoder longer than that unguarded it under the
-- |   finger, and the nudge of letting go landed as a real turn.
-- |
-- | Dropped, not queued: a nudge is not a gesture that deserves to arrive
-- | late. The cost is that a slow turn's first move lands 60 ms late and a
-- | fast ride is thinned to about sixteen updates a second — more than a fader
-- | needs. Nothing withheld here is sample-critical.
-- |
-- | Lifted from producing-with-your-feet's `Component.App.handleTwisterMsg`,
-- | where it was woven through the component's state. Here it is a pure step
-- | function, so it can be tested and so every app on a Twister gets it, plus
-- | a small driver for apps that just want the filtered stream.
module Helm.Twister.Guard
  ( Timing
  , timing
  , Guard
  , empty
  , Event(..)
  , Step
  , step
  , guarded
  ) where

import Prelude

import Data.Foldable (for_)
import Data.Int (round)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Set (Set)
import Data.Set as Set
import Effect (Effect)
import Effect.Ref as Ref
import Effect.Timer (setTimeout)
import Helm.Twister (Knob, TwisterMsg(..), knobCC)

type Timing = { turnHold :: Number, pressGuard :: Number }

-- | The windows PWYF settled on.
timing :: Timing
timing = { turnHold: 60.0, pressGuard: 300.0 }

-- | Keyed by `knobCC`: the turns waiting to be delivered, the encoders still
-- | deaf from a press, and how many presses each encoder has had.
-- |
-- | The count is what makes a release's clock its own. PWYF's guard was a
-- | plain set, so press–release–press-and-hold let the *first* release's
-- | timer clear the guard under the second press's finger: the nudge of
-- | letting go then landed as a turn, the bug the press-without-a-timer fix
-- | had ended, back on any quick double press.
type Guard = { pending :: Map Int Int, deaf :: Set Int, presses :: Map Int Int }

empty :: Guard
empty = { pending: Map.empty, deaf: Set.empty, presses: Map.empty }

data Event
  = Heard TwisterMsg
  -- | A turn's window has closed.
  | TurnDue Knob
  -- | A release's window has closed; the count is the encoder's presses when
  -- | it opened, and a press since makes it stale.
  | GuardDue Knob Int

derive instance Eq Event

instance Show Event where
  show = case _ of
    Heard m -> "(Heard " <> show m <> ")"
    TurnDue k -> "(TurnDue " <> show k.layer <> "/" <> show k.index <> ")"
    GuardDue k n -> "(GuardDue " <> show k.layer <> "/" <> show k.index <> " " <> show n <> ")"

-- | What one event does: the new guard, the messages to pass on now, and the
-- | events to feed back after a delay.
type Step =
  { guard :: Guard
  , deliver :: Array TwisterMsg
  , after :: Array { ms :: Number, event :: Event }
  }

step :: Timing -> Event -> Guard -> Step
step t ev g = case ev of
  Heard (Turn k v)
    | Set.member (knobCC k) g.deaf -> quiet g
    | otherwise ->
        { guard: g { pending = Map.insert (knobCC k) v g.pending }
        -- One timer per burst, not per message.
        , deliver: []
        , after: if Map.member (knobCC k) g.pending then [] else [ { ms: t.turnHold, event: TurnDue k } ]
        }
  Heard m@(Press k) ->
    { guard: (deafen k g) { presses = Map.insert (knobCC k) (pressesOf k g + 1) g.presses }
    , deliver: [ m ]
    , after: []
    }
  -- Letting go is exactly as clumsy as pressing, so the release re-arms the
  -- guard rather than being ignored, and only then starts its clock.
  Heard m@(Release k) ->
    { guard: deafen k g, deliver: [ m ], after: [ { ms: t.pressGuard, event: GuardDue k (pressesOf k g) } ] }
  Heard m@(Side _) ->
    { guard: g, deliver: [ m ], after: [] }
  -- Gone means a press arrived inside the window and took it. That is the
  -- whole mechanism: the press does not have to beat the nudge, only land in
  -- the same tenth of a second.
  TurnDue k -> case Map.lookup (knobCC k) g.pending of
    Nothing -> quiet g
    Just v -> { guard: g { pending = Map.delete (knobCC k) g.pending }, deliver: [ Turn k v ], after: [] }
  GuardDue k n
    | n == pressesOf k g -> quiet (g { deaf = Set.delete (knobCC k) g.deaf })
    | otherwise -> quiet g
  where
  pressesOf k g' = fromMaybe 0 (Map.lookup (knobCC k) g'.presses)
  quiet g' = { guard: g', deliver: [], after: [] }
  deafen k g' = g' { pending = Map.delete (knobCC k) g'.pending, deaf = Set.insert (knobCC k) g'.deaf }

-- | The guard as a filter: hand it every parsed message, and `k` hears the
-- | ones that survive, when they survive. For apps that do not want to hold
-- | the guard in their own state.
guarded :: Timing -> (TwisterMsg -> Effect Unit) -> Effect (TwisterMsg -> Effect Unit)
guarded t k = do
  ref <- Ref.new empty
  let
    feed ev = do
      g <- Ref.read ref
      let s = step t ev g
      Ref.write s.guard ref
      for_ s.deliver k
      for_ s.after \a -> void $ setTimeout (round a.ms) (feed a.event)
  pure (feed <<< Heard)
