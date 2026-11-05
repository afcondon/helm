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
  , requestHubAccess
  , requestHubAccessAff
  , claimOutput
  , releaseOutput
  , claimName
  , releaseName
  , holderOf
  , holding
  , viaHub
  , wantName
  , grantName
  , refuseWant
  , onWanted
  , onRefused
  , onClaims
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
import Effect.Uncurried (EffectFn1, EffectFn2, EffectFn3, EffectFn4, EffectFn5, mkEffectFn1, runEffectFn1, runEffectFn2, runEffectFn3, runEffectFn4, runEffectFn5)

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
foreign import requestHubAccessImpl :: EffectFn5 String String Number (EffectFn1 MIDIAccess Unit) (EffectFn1 String Unit) Unit
foreign import claimOutputImpl :: EffectFn2 MIDIAccess MIDIOutput Unit
foreign import claimNameImpl :: EffectFn2 MIDIAccess String Unit
foreign import releaseNameImpl :: EffectFn2 MIDIAccess String Unit
foreign import holderOfImpl :: EffectFn2 MIDIAccess String (Nullable String)
foreign import holdingImpl :: EffectFn2 MIDIAccess String Boolean
foreign import viaHubImpl :: EffectFn1 MIDIAccess Boolean
foreign import wantNameImpl :: EffectFn2 MIDIAccess String Unit
foreign import grantNameImpl :: EffectFn3 MIDIAccess String String Unit
foreign import refuseWantImpl :: EffectFn4 MIDIAccess String String String Unit
foreign import onWantedImpl :: EffectFn2 MIDIAccess (String -> String -> Effect Unit) (Effect Unit)
foreign import onRefusedImpl :: EffectFn2 MIDIAccess (String -> String -> String -> Effect Unit) (Effect Unit)
foreign import onClaimsImpl :: EffectFn2 MIDIAccess (Effect Unit) (Effect Unit)
foreign import releaseOutputImpl :: EffectFn2 MIDIAccess MIDIOutput Unit
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

-- | Access through **Helm's hub** (`hub/hub.mjs`): the daemon that holds the
-- | rig's controllers so that every app can share them. What comes back is a
-- | `MIDIAccess` like any other, and everything in this module works on it,
-- | so moving an app onto the hub changes this one call.
-- |
-- | `client` names the app in the hub's `/state`. If the hub has not answered
-- | within `waitMs` the request fails, saying so; it never falls back to Web
-- | MIDI, because two owners of one controller is what the hub ends. After
-- | access is granted the hub may go and come back: its ports disconnect and
-- | reconnect, as after a replug, and an app that re-opens on `onStateChange`
-- | recovers by itself.
requestHubAccess :: { url :: String, client :: String, waitMs :: Number } -> (Either String MIDIAccess -> Effect Unit) -> Effect Unit
requestHubAccess { url, client, waitMs } k =
  runEffectFn5 requestHubAccessImpl url client waitMs (mkEffectFn1 (k <<< Right)) (mkEffectFn1 (k <<< Left))

requestHubAccessAff :: { url :: String, client :: String, waitMs :: Number } -> Aff MIDIAccess
requestHubAccessAff opts = makeAff \cb -> do
  requestHubAccess opts case _ of
    Left msg -> cb (Left (error msg))
    Right access -> cb (Right access)
  pure nonCanceler

-- | **Hold an output, so only this app's messages reach it** — on the hub.
-- |
-- | For a device with no read-back, the Twister first: two writers are
-- | last-writer-wins and the loser is never told. While this app holds the
-- | output, anyone else's sends to it are dropped and the sender is told who
-- | holds it. The claim belongs to this connection: it is made again after the
-- | hub reconnects, and ends when the page goes. A second tab of the same app
-- | does not share it.
-- |
-- | Through the browser's Web MIDI there is no one to claim from, and this
-- | does nothing.
claimOutput :: MIDIAccess -> MIDIOutput -> Effect Unit
claimOutput = runEffectFn2 claimOutputImpl

releaseOutput :: MIDIAccess -> MIDIOutput -> Effect Unit
releaseOutput = runEffectFn2 releaseOutputImpl

-- | **Claim a responsibility rather than a port**, on the hub.
-- |
-- | A claim is on a name, and most names are outputs; this is for the ones
-- | that are not: `itajara:switches`, the looper's footswitches, is held by
-- | whichever process is answering them, so a page that could also answer
-- | them knows to stand back instead of acting on every press a second time.
-- | Declared, not inferred: the holder says so, and the claim ends with its
-- | connection, so a holder that dies hands the duty back by itself.
claimName :: MIDIAccess -> String -> Effect Unit
claimName = runEffectFn2 claimNameImpl

releaseName :: MIDIAccess -> String -> Effect Unit
releaseName = runEffectFn2 releaseNameImpl

-- | The client holding a name on the hub, as the hub last said. `Nothing`
-- | through the browser's Web MIDI, where nothing is ever held.
holderOf :: MIDIAccess -> String -> Effect (Maybe String)
holderOf access name = toMaybe <$> runEffectFn2 holderOfImpl access name

-- | Whether **this connection** holds a name: not just a client with this
-- | app's name, which a second tab also has. `false` through Web MIDI.
holding :: MIDIAccess -> String -> Effect Boolean
holding = runEffectFn2 holdingImpl

-- | Whether this access goes through Helm's hub, where things can be held.
-- | Through the browser's Web MIDI nothing is held and nobody holds anything,
-- | so an app there treats every device as its own.
viaHub :: MIDIAccess -> Effect Boolean
viaHub = runEffectFn1 viaHubImpl

-- | **Ask for a name.** Free, it is claimed. Held, the holder is told who
-- | wants it (`onWanted`) and answers with `grantName` or `refuseWant`; the
-- | hub decides nothing. A grant arrives as a change of claims (`onClaims`),
-- | a refusal through `onRefused`.
wantName :: MIDIAccess -> String -> Effect Unit
wantName = runEffectFn2 wantNameImpl

-- | Hand a name this connection holds to the client called `to`.
grantName :: MIDIAccess -> String -> String -> Effect Unit
grantName = runEffectFn3 grantNameImpl

-- | Say no to a want, with the reason, which the wanter is told.
refuseWant :: MIDIAccess -> String -> String -> String -> Effect Unit
refuseWant = runEffectFn4 refuseWantImpl

-- | Hear that a client (by name) wants a name this connection holds. Returns
-- | the unsubscribe.
onWanted :: MIDIAccess -> (String -> String -> Effect Unit) -> Effect (Effect Unit)
onWanted = runEffectFn2 onWantedImpl

-- | Hear that a holder refused this connection's want: name, holder, reason.
onRefused :: MIDIAccess -> (String -> String -> String -> Effect Unit) -> Effect (Effect Unit)
onRefused = runEffectFn2 onRefusedImpl

-- | Hear that who holds what has changed (and once more with each reconnect).
onClaims :: MIDIAccess -> Effect Unit -> Effect (Effect Unit)
onClaims = runEffectFn2 onClaimsImpl

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
