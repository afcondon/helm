-- | The one Web MIDI FFI, for every app that talks to a controller.
-- |
-- | Four apps carried their own (PWYF, Binnacle, Calypso, Quadrat), and each
-- | had found a different subset of the ways Web MIDI fails silently. This is
-- | the union:
-- |
-- | - **Port ids are normalised to strings.** The iOS shim reports numbers,
-- |   which display identically and compare unequal.
-- | - **Ports are deduplicated by id.** The same shim lists one real port
-- |   several times over.
-- | - **`onStateChange` says which port changed**, because a port that comes
-- |   back is a new object and the old handle is dead without saying so.
-- | - **Access is requested by callback, never awaited** from a handler: the
-- |   permission prompt is outside the page, and an awaited request stalls
-- |   the whole action queue until someone notices it.
-- | - **Sends can carry a timestamp** on the performance clock, which is how a
-- |   lookahead scheduler stays jitter-free.
-- |
-- | Which port is the Twister is a question for a device profile, answered
-- | with a `PortMatch`; nothing here knows any device's name.
module Helm.WebMIDI
  ( MIDIAccess
  , MIDIInput
  , MIDIOutput
  , MidiPort
  , PortChange
  , PortMatch(..)
  , requestAccess
  , requestAccessAff
  , outputs
  , inputs
  , findOutput
  , findInput
  , outputPort
  , inputPort
  , send
  , sendAt
  , now
  , onMessage
  , onStateChange
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe)
import Data.Nullable (Nullable, toMaybe)
import Effect (Effect)
import Effect.Aff (Aff, makeAff, nonCanceler)
import Effect.Exception (error)
import Effect.Uncurried (EffectFn1, EffectFn2, EffectFn3, mkEffectFn1, runEffectFn1, runEffectFn2, runEffectFn3)

foreign import data MIDIAccess :: Type
foreign import data MIDIOutput :: Type
foreign import data MIDIInput :: Type

type MidiPort =
  { id :: String
  , name :: String
  }

-- | A connect or disconnect, as reported by `statechange`.
type PortChange =
  { id :: String
  , name :: String
  -- | "connected" or "disconnected".
  , state :: String
  -- | "input" or "output".
  , portType :: String
  }

-- | How to pick a port.
-- |
-- | `Exactly` is a stored selection: it matches the port's id or its whole
-- | name, so a choice saved before a reconnect still finds the port after.
-- | `NameContains` is a device profile's guess: the first port whose name
-- | includes the text, which survives the interface's own spelling of it.
-- | `NameContains ""` is the first port of all.
data PortMatch
  = Exactly String
  | NameContains String

foreign import requestAccessImpl :: EffectFn3 Boolean (EffectFn1 MIDIAccess Unit) (EffectFn1 String Unit) Unit
foreign import outputsImpl :: EffectFn1 MIDIAccess (Array MidiPort)
foreign import inputsImpl :: EffectFn1 MIDIAccess (Array MidiPort)
foreign import findOutputImpl :: EffectFn2 MIDIAccess { tag :: String, value :: String } (Nullable MIDIOutput)
foreign import findInputImpl :: EffectFn2 MIDIAccess { tag :: String, value :: String } (Nullable MIDIInput)
foreign import portOfImpl :: forall port. port -> MidiPort
foreign import sendImpl :: EffectFn2 MIDIOutput (Array Int) Unit
foreign import sendAtImpl :: EffectFn3 MIDIOutput (Array Int) Number Unit
foreign import nowImpl :: Effect Number
foreign import onMessageImpl :: EffectFn2 MIDIInput (EffectFn1 (Array Int) Unit) (Effect Unit)
foreign import onStateChangeImpl :: EffectFn2 MIDIAccess (EffectFn1 PortChange Unit) (Effect Unit)

-- | Ask for access and carry on. The callback runs when the prompt is answered
-- | — which may be never, and must not hold anything up meanwhile. `sysex` is
-- | needed for device configuration (the MC6, the BCR) and not for playing.
requestAccess :: { sysex :: Boolean } -> (Either String MIDIAccess -> Effect Unit) -> Effect Unit
requestAccess { sysex } k =
  runEffectFn3 requestAccessImpl sysex (mkEffectFn1 (k <<< Right)) (mkEffectFn1 (k <<< Left))

-- | The same, as an `Aff`. **Fork it**; awaiting it inline from a Halogen
-- | handler is the stall `requestAccess` exists to avoid.
requestAccessAff :: { sysex :: Boolean } -> Aff MIDIAccess
requestAccessAff opts = makeAff \cb -> do
  requestAccess opts case _ of
    Left msg -> cb (Left (error msg))
    Right access -> cb (Right access)
  pure nonCanceler

-- | Ports, with duplicates removed: identity is the id, first sighting wins.
outputs :: MIDIAccess -> Effect (Array MidiPort)
outputs access = dedupe <$> runEffectFn1 outputsImpl access

inputs :: MIDIAccess -> Effect (Array MidiPort)
inputs access = dedupe <$> runEffectFn1 inputsImpl access

dedupe :: Array MidiPort -> Array MidiPort
dedupe = Array.nubByEq \a b -> a.id == b.id

matchRecord :: PortMatch -> { tag :: String, value :: String }
matchRecord = case _ of
  Exactly value -> { tag: "exactly", value }
  NameContains value -> { tag: "contains", value }

findOutput :: MIDIAccess -> PortMatch -> Effect (Maybe MIDIOutput)
findOutput access m = toMaybe <$> runEffectFn2 findOutputImpl access (matchRecord m)

findInput :: MIDIAccess -> PortMatch -> Effect (Maybe MIDIInput)
findInput access m = toMaybe <$> runEffectFn2 findInputImpl access (matchRecord m)

-- | Which port a handle is, normalised as `outputs` lists it — so a port
-- | found by `NameContains` can be stored as `Exactly` its id.
outputPort :: MIDIOutput -> MidiPort
outputPort = portOfImpl

inputPort :: MIDIInput -> MidiPort
inputPort = portOfImpl

send :: MIDIOutput -> Array Int -> Effect Unit
send = runEffectFn2 sendImpl

-- | Send at an absolute time on the performance clock (`now`). A time already
-- | past sends at once.
sendAt :: MIDIOutput -> Number -> Array Int -> Effect Unit
sendAt out atMs bytes = runEffectFn3 sendAtImpl out bytes atMs

-- | The clock `sendAt` reads: `performance.now()`, in milliseconds.
now :: Effect Number
now = nowImpl

-- | Every message from an input, as raw bytes. Decoding is a device
-- | profile's job. One listener per input: subscribing again replaces the
-- | last, and the returned unsubscribe only ever removes its own.
onMessage :: MIDIInput -> (Array Int -> Effect Unit) -> Effect (Effect Unit)
onMessage input k = runEffectFn2 onMessageImpl input (mkEffectFn1 k)

-- | Fires when any port connects or disconnects, naming it. Re-open the port
-- | you had selected when it comes back; the old handle is dead.
onStateChange :: MIDIAccess -> (PortChange -> Effect Unit) -> Effect (Effect Unit)
onStateChange access k = runEffectFn2 onStateChangeImpl access (mkEffectFn1 k)
