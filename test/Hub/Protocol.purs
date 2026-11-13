-- | The REFERENCE for the Helm hub's protocol: every JSON frame that passes
-- | between the hub (`hub/hub.mjs`) and an app (`src/Helm/WebMIDI.js`), as
-- | two data types and one codec. The declaration is
-- | `conformance/HELM-HUB.md`; the vectors both ends replay are generated
-- | from here by `make vectors`.
-- |
-- | Each message is described once, as a name and its fields, and Hawser
-- | derives the codec, the document and the mechanical cases from that. The
-- | two sum types are written by hand over the descriptions, so a frame is
-- | an ordinary constructor. Until 2026-11-13 the codec was written out by
-- | hand as well; the descriptions replaced it without changing the vector
-- | file. It lives under `test/` so that Helm's consumers gain no
-- | dependency from it yet.
module Hub.Protocol
  ( ToHub(..)
  , FromHub(..)
  , Port
  , encodeToHub
  , decodeToHub
  , encodeFromHub
  , decodeFromHub
  , toHubName
  , fromHubName
  , toHubNames
  , fromHubNames
  , toHubRows
  , fromHubRows
  , toHubMechanical
  , fromHubMechanical
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Bifunctor (lmap)
import Data.Either (Either)
import Data.Tuple (Tuple)
import Hawser.Json as J
import Hawser.Message (Message, field, message, recordOf)
import Hawser.Value (Value, arrayOf, bytes, named, notNegative, number, string, tableOf, whole)

-- | A MIDI port as the hub names it. `id` is the name, with " #2" for a
-- | second port of the same name.
type Port = { id :: String, name :: String }

-- | What an app says to the hub.
data ToHub
  -- | Names the app. Sent once, on connecting.
  = Hello { client :: String }
  -- | Bytes for an output, now or `delayMs` from now.
  | Send { port :: String, bytes :: Array Int, delayMs :: Number }
  -- | Hold a name. Granted if no other live connection holds it.
  | Claim { port :: String }
  -- | The holder hands the name to the one client called `to`.
  | Grant { port :: String, to :: String }
  -- | The holder lets the name go.
  | Release { port :: String }
  -- | Ask for a name: a claim if it is free, otherwise passed to the holder.
  | Want { port :: String }
  -- | The holder says no to `to`, who wanted the name.
  | Refuse { port :: String, to :: String, why :: String }
  -- | Be told every message the hub delivers to this output.
  | Watch { port :: String }
  | Unwatch { port :: String }
  -- | A request to whoever holds the name. The hub relays `text` unread.
  | Ask { port :: String, text :: String }

derive instance Eq ToHub

-- | What the hub says to an app.
data FromHub
  -- | The machine's ports. On connecting, and whenever they change.
  = Ports { inputs :: Array Port, outputs :: Array Port }
  -- | A message that arrived on an input. To every app.
  | Msg { port :: String, bytes :: Array Int }
  -- | Something this app asked for could not be done. `text` is for people.
  | Error { text :: String }
  -- | Who holds which name: by client name, and by connection id.
  | Claims { claims :: Array (Tuple String String), holders :: Array (Tuple String Int) }
  -- | This connection's id. Once, on connecting.
  | You { id :: Int }
  -- | To a holder: `by` wants the name.
  | Wanted { port :: String, by :: String }
  -- | To a wanter: the holder, `by`, said no.
  | Refused { port :: String, by :: String, why :: String }
  -- | To a watcher: `by` sent this to the output. `by` is empty when the hub
  -- | is replaying what the output last showed.
  | Sent { port :: String, bytes :: Array Int, by :: String }
  -- | To a holder: `by` asks this of it.
  | Asked { port :: String, by :: String, text :: String }

derive instance Eq FromHub

-- ── The fields ─────────────────────────────────────────────────────────────

-- | The key that says which frame this is.
tag :: String
tag = "t"

-- | A name: an output, or a responsibility such as `itajara:switches`.
name :: Value String
name = named "name" string

port :: Value Port
port = recordOf "{id, name}" $ { id: _, name: _ }
  <$> field "id" _.id string "the name, with \" #2\" for a second port of the same name"
  <*> field "name" _.name string "the name as the machine lists it"

-- ── What an app says ───────────────────────────────────────────────────────

hello :: Message { client :: String }
hello = message "hello" "Names the app. Once, on connecting." $
  { client: _ } <$> field "client" _.client string "the app's name"

send :: Message { port :: String, bytes :: Array Int, delayMs :: Number }
send = message "send" "Bytes for an output, now or later." $
  { port: _, bytes: _, delayMs: _ }
    <$> field "port" _.port name "the output"
    <*> field "data" _.bytes bytes "the MIDI message"
    <*> field "delayMs" _.delayMs (notNegative 0.0 "negative-delay" number) "how long from now"

claim :: Message { port :: String }
claim = message "claim" "Hold a name. Granted if no other live connection holds it." $
  { port: _ } <$> field "port" _.port name "the name"

grant :: Message { port :: String, to :: String }
grant = message "grant" "The holder hands the name to the one client called `to`." $
  { port: _, to: _ }
    <$> field "port" _.port name "the name"
    <*> field "to" _.to string "the client to hold it next"

release :: Message { port :: String }
release = message "release" "The holder lets the name go." $
  { port: _ } <$> field "port" _.port name "the name"

want :: Message { port :: String }
want = message "want" "Ask for a name: a claim if it is free, otherwise passed to the holder." $
  { port: _ } <$> field "port" _.port name "the name"

refuse :: Message { port :: String, to :: String, why :: String }
refuse = message "refuse" "The holder says no to `to`. `why` may be empty." $
  { port: _, to: _, why: _ }
    <$> field "port" _.port name "the name"
    <*> field "to" _.to string "the client that wanted it"
    <*> field "why" _.why string "the reason, for people"

watch :: Message { port :: String }
watch = message "watch" "Be told every message the hub delivers to this output." $
  { port: _ } <$> field "port" _.port name "the output"

unwatch :: Message { port :: String }
unwatch = message "unwatch" "Stop being told." $
  { port: _ } <$> field "port" _.port name "the output"

ask :: Message { port :: String, text :: String }
ask = message "ask" "A request to whoever holds the name. The hub relays `text` unread." $
  { port: _, text: _ }
    <$> field "port" _.port name "the name"
    <*> field "text" _.text string "the request"

-- | Total, so a constructor without a description does not compile.
encodeToHub :: ToHub -> Json
encodeToHub = case _ of
  Hello m -> J.encode tag hello m
  Send m -> J.encode tag send m
  Claim m -> J.encode tag claim m
  Grant m -> J.encode tag grant m
  Release m -> J.encode tag release m
  Want m -> J.encode tag want m
  Refuse m -> J.encode tag refuse m
  Watch m -> J.encode tag watch m
  Unwatch m -> J.encode tag unwatch m
  Ask m -> J.encode tag ask m

toHubKinds :: Array (J.Kind ToHub)
toHubKinds =
  [ J.kind hello Hello
  , J.kind send Send
  , J.kind claim Claim
  , J.kind want Want
  , J.kind grant Grant
  , J.kind refuse Refuse
  , J.kind release Release
  , J.kind watch Watch
  , J.kind unwatch Unwatch
  , J.kind ask Ask
  ]

-- | Strict: exactly the described fields, each of its type and rule.
decodeToHub :: String -> Either String ToHub
decodeToHub = J.decode tag toHubKinds >>> lmap J.failureText

toHubNames :: Array String
toHubNames = map J.kindName toHubKinds

-- | The value of `t` for a frame.
toHubName :: ToHub -> String
toHubName = encodeToHub >>> J.nameOf tag

-- | The rows of the declaration's table.
toHubRows :: Array String
toHubRows = map J.kindRow toHubKinds

-- | The cases that follow from the descriptions alone, one good example of
-- | each kind and every way of spoiling it.
toHubMechanical :: Array J.Case
toHubMechanical =
  J.mechanical tag hello { client: "pwyf" }
    <> J.mechanical tag send { port: "sink", bytes: [ 176, 3, 64 ], delayMs: 0.0 }
    <> J.mechanical tag claim { port: "sink" }
    <> J.mechanical tag grant { port: "sink", to: "quadrat" }
    <> J.mechanical tag release { port: "sink" }
    <> J.mechanical tag want { port: "sink" }
    <> J.mechanical tag refuse { port: "sink", to: "quadrat", why: "recording" }
    <> J.mechanical tag watch { port: "sink" }
    <> J.mechanical tag unwatch { port: "sink" }
    <> J.mechanical tag ask { port: "sink", text: "page 3" }

-- ── What the hub says ──────────────────────────────────────────────────────

you :: Message { id :: Int }
you = message "you" "To a new connection: its connection number. Once." $
  { id: _ } <$> field "id" _.id whole "the connection's number"

ports :: Message { inputs :: Array Port, outputs :: Array Port }
ports = message "ports" "To a new connection, and to everyone on a change: the machine's ports." $
  { inputs: _, outputs: _ }
    <$> field "inputs" _.inputs (arrayOf port) "every input"
    <*> field "outputs" _.outputs (arrayOf port) "every output"

claims :: Message { claims :: Array (Tuple String String), holders :: Array (Tuple String Int) }
claims = message "claims" "To a new connection, and to everyone on a change: who holds what." $
  { claims: _, holders: _ }
    <$> field "claims" _.claims (tableOf string) "each held name, to its holder's client name"
    <*> field "holders" _.holders (tableOf whole) "each held name, to its holder's connection number"

msg :: Message { port :: String, bytes :: Array Int }
msg = message "msg" "To everyone: a message that arrived on an input." $
  { port: _, bytes: _ }
    <$> field "port" _.port name "the input"
    <*> field "data" _.bytes bytes "the MIDI message"

error :: Message { text :: String }
error = message "error" "To the app at fault: something it asked for could not be done." $
  { text: _ } <$> field "text" _.text string "what went wrong, for people"

wanted :: Message { port :: String, by :: String }
wanted = message "wanted" "To the holder: `by` wants the name." $
  { port: _, by: _ }
    <$> field "port" _.port name "the name"
    <*> field "by" _.by string "the client that wants it"

refused :: Message { port :: String, by :: String, why :: String }
refused = message "refused" "To the wanter: the holder, `by`, said no." $
  { port: _, by: _, why: _ }
    <$> field "port" _.port name "the name"
    <*> field "by" _.by string "the holder"
    <*> field "why" _.why string "the reason, for people"

sent :: Message { port :: String, bytes :: Array Int, by :: String }
sent = message "sent" "To watchers, not the sender: `by` sent this to the output. An empty `by` is the hub saying what the output last showed." $
  { port: _, bytes: _, by: _ }
    <$> field "port" _.port name "the output"
    <*> field "data" _.bytes bytes "the MIDI message"
    <*> field "by" _.by string "the sender, or empty"

asked :: Message { port :: String, by :: String, text :: String }
asked = message "asked" "To the holder: `by` asks this of it." $
  { port: _, by: _, text: _ }
    <$> field "port" _.port name "the name"
    <*> field "by" _.by string "the asker"
    <*> field "text" _.text string "the request"

-- | Total, so a constructor without a description does not compile.
encodeFromHub :: FromHub -> Json
encodeFromHub = case _ of
  Ports m -> J.encode tag ports m
  Msg m -> J.encode tag msg m
  Error m -> J.encode tag error m
  Claims m -> J.encode tag claims m
  You m -> J.encode tag you m
  Wanted m -> J.encode tag wanted m
  Refused m -> J.encode tag refused m
  Sent m -> J.encode tag sent m
  Asked m -> J.encode tag asked m

fromHubKinds :: Array (J.Kind FromHub)
fromHubKinds =
  [ J.kind you You
  , J.kind ports Ports
  , J.kind claims Claims
  , J.kind msg Msg
  , J.kind error Error
  , J.kind wanted Wanted
  , J.kind refused Refused
  , J.kind sent Sent
  , J.kind asked Asked
  ]

decodeFromHub :: String -> Either String FromHub
decodeFromHub = J.decode tag fromHubKinds >>> lmap J.failureText

fromHubNames :: Array String
fromHubNames = map J.kindName fromHubKinds

fromHubName :: FromHub -> String
fromHubName = encodeFromHub >>> J.nameOf tag

fromHubRows :: Array String
fromHubRows = map J.kindRow fromHubKinds

fromHubMechanical :: Array J.Case
fromHubMechanical =
  J.mechanical tag you { id: 1 }
    <> J.mechanical tag ports { inputs: [ loop ], outputs: [ loop ] }
    <> J.mechanical tag claims { claims: [], holders: [] }
    <> J.mechanical tag msg { port: "loop", bytes: [ 176, 3, 64 ] }
    <> J.mechanical tag error { text: "no output named nowhere" }
    <> J.mechanical tag wanted { port: "sink", by: "quadrat" }
    <> J.mechanical tag refused { port: "sink", by: "pwyf", why: "recording" }
    <> J.mechanical tag sent { port: "sink", bytes: [ 176, 3, 64 ], by: "pwyf" }
    <> J.mechanical tag asked { port: "sink", by: "pwyf", text: "page 3" }
  where
  loop = { id: "loop", name: "loop" }
