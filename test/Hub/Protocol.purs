-- | The REFERENCE for the Helm hub's protocol: every JSON frame that passes
-- | between the hub (`hub/hub.mjs`) and an app (`src/Helm/WebMIDI.js`), as
-- | two data types and one codec. The declaration is
-- | `conformance/HELM-HUB.md`; the vectors both ends replay are generated
-- | from here by `make vectors`.
-- |
-- | Written by hand, in the plainest way, as one half of a spike: see
-- | `docs/kb/plans/wire-declarations.md`, step 1. It lives under `test/` so
-- | that Helm's consumers gain no dependency from it yet.
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
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as Json
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..), note)
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object

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

-- | The value of `t` for each frame.
toHubName :: ToHub -> String
toHubName = case _ of
  Hello _ -> "hello"
  Send _ -> "send"
  Claim _ -> "claim"
  Grant _ -> "grant"
  Release _ -> "release"
  Want _ -> "want"
  Refuse _ -> "refuse"
  Watch _ -> "watch"
  Unwatch _ -> "unwatch"
  Ask _ -> "ask"

fromHubName :: FromHub -> String
fromHubName = case _ of
  Ports _ -> "ports"
  Msg _ -> "msg"
  Error _ -> "error"
  Claims _ -> "claims"
  You _ -> "you"
  Wanted _ -> "wanted"
  Refused _ -> "refused"
  Sent _ -> "sent"
  Asked _ -> "asked"

-- | Every `t` an app may send, and every `t` the hub may. The vector file
-- | carries both lists, and each end's replay checks it knows them all.
toHubNames :: Array String
toHubNames = [ "hello", "send", "claim", "grant", "release", "want", "refuse", "watch", "unwatch", "ask" ]

fromHubNames :: Array String
fromHubNames = [ "ports", "msg", "error", "claims", "you", "wanted", "refused", "sent", "asked" ]

-- ── Encoding ───────────────────────────────────────────────────────────────

frame :: String -> Array (Tuple String Json) -> Json
frame name fields = Json.fromObject (Object.fromFoldable (Array.cons (Tuple "t" (Json.fromString name)) fields))

string :: String -> String -> Tuple String Json
string key value = Tuple key (Json.fromString value)

bytesField :: Array Int -> Tuple String Json
bytesField bytes = Tuple "data" (Json.fromArray (map (Int.toNumber >>> Json.fromNumber) bytes))

portJson :: Port -> Json
portJson port = Json.fromObject (Object.fromFoldable [ string "id" port.id, string "name" port.name ])

encodeToHub :: ToHub -> Json
encodeToHub message = frame (toHubName message) case message of
  Hello m -> [ string "client" m.client ]
  Send m -> [ string "port" m.port, bytesField m.bytes, Tuple "delayMs" (Json.fromNumber m.delayMs) ]
  Claim m -> [ string "port" m.port ]
  Grant m -> [ string "port" m.port, string "to" m.to ]
  Release m -> [ string "port" m.port ]
  Want m -> [ string "port" m.port ]
  Refuse m -> [ string "port" m.port, string "to" m.to, string "why" m.why ]
  Watch m -> [ string "port" m.port ]
  Unwatch m -> [ string "port" m.port ]
  Ask m -> [ string "port" m.port, string "text" m.text ]

encodeFromHub :: FromHub -> Json
encodeFromHub message = frame (fromHubName message) case message of
  Ports m ->
    [ Tuple "inputs" (Json.fromArray (map portJson m.inputs))
    , Tuple "outputs" (Json.fromArray (map portJson m.outputs))
    ]
  Msg m -> [ string "port" m.port, bytesField m.bytes ]
  Error m -> [ string "text" m.text ]
  Claims m ->
    [ Tuple "claims" (Json.fromObject (Object.fromFoldable (map (map Json.fromString) m.claims)))
    , Tuple "holders" (Json.fromObject (Object.fromFoldable (map (map (Int.toNumber >>> Json.fromNumber)) m.holders)))
    ]
  You m -> [ Tuple "id" (Json.fromNumber (Int.toNumber m.id)) ]
  Wanted m -> [ string "port" m.port, string "by" m.by ]
  Refused m -> [ string "port" m.port, string "by" m.by, string "why" m.why ]
  Sent m -> [ string "port" m.port, bytesField m.bytes, string "by" m.by ]
  Asked m -> [ string "port" m.port, string "by" m.by, string "text" m.text ]

-- ── Decoding ───────────────────────────────────────────────────────────────
--
-- Strict: a frame has exactly the fields its `t` declares, each of the
-- declared type. The hub and the client are more forgiving than this when
-- they read; the declaration is what a WRITER must produce.

type Fields = Object Json

opened :: String -> Either String (Tuple String Fields)
opened source = do
  json <- jsonParser source
  fields <- note "not an object" (Json.toObject json)
  name <- field "t" Json.toString "a string" fields
  pure (Tuple name fields)

field :: forall a. String -> (Json -> Maybe a) -> String -> Fields -> Either String a
field key read expected fields =
  case Object.lookup key fields of
    Nothing -> Left ("no " <> key)
    Just json -> note (key <> " is not " <> expected) (read json)

text :: String -> Fields -> Either String String
text key = field key Json.toString "a string"

number :: String -> Fields -> Either String Number
number key = field key Json.toNumber "a number"

whole :: Json -> Maybe Int
whole = Json.toNumber >=> Int.fromNumber

byte :: Json -> Maybe Int
byte json = whole json >>= \value -> if value >= 0 && value <= 255 then Just value else Nothing

-- | One byte at least, each 0 to 255.
bytesOf :: Fields -> Either String (Array Int)
bytesOf fields = do
  bytes <- field "data" (Json.toArray >=> traverse byte) "an array of bytes" fields
  if Array.null bytes then Left "data is empty" else Right bytes

portOf :: Json -> Maybe Port
portOf json = do
  fields <- Json.toObject json
  id <- Object.lookup "id" fields >>= Json.toString
  name <- Object.lookup "name" fields >>= Json.toString
  if Object.size fields == 2 then Just { id, name } else Nothing

table :: forall a. (Json -> Maybe a) -> Json -> Maybe (Array (Tuple String a))
table read json = Json.toObject json >>= \entries ->
  traverse (\(Tuple key value) -> Tuple key <$> read value) (Object.toUnfoldable entries)

-- | The frame has no field beyond `t` and those named.
only :: Array String -> Fields -> Either String Unit
only keys fields =
  case Array.find (\key -> not (Array.elem key (Array.cons "t" keys))) (Object.keys fields) of
    Just extra -> Left ("an undeclared field, " <> extra)
    Nothing -> Right unit

decodeToHub :: String -> Either String ToHub
decodeToHub = opened >=> \(Tuple name fields) -> case name of
  "hello" -> only [ "client" ] fields *> (Hello <$> ({ client: _ } <$> text "client" fields))
  "send" -> only [ "port", "data", "delayMs" ] fields *> do
    port <- text "port" fields
    bytes <- bytesOf fields
    delayMs <- number "delayMs" fields
    if delayMs < 0.0 then Left "delayMs is negative" else Right (Send { port, bytes, delayMs })
  "claim" -> only [ "port" ] fields *> (Claim <$> ({ port: _ } <$> text "port" fields))
  "grant" -> only [ "port", "to" ] fields *> (Grant <$> ({ port: _, to: _ } <$> text "port" fields <*> text "to" fields))
  "release" -> only [ "port" ] fields *> (Release <$> ({ port: _ } <$> text "port" fields))
  "want" -> only [ "port" ] fields *> (Want <$> ({ port: _ } <$> text "port" fields))
  "refuse" -> only [ "port", "to", "why" ] fields *>
    (Refuse <$> ({ port: _, to: _, why: _ } <$> text "port" fields <*> text "to" fields <*> text "why" fields))
  "watch" -> only [ "port" ] fields *> (Watch <$> ({ port: _ } <$> text "port" fields))
  "unwatch" -> only [ "port" ] fields *> (Unwatch <$> ({ port: _ } <$> text "port" fields))
  "ask" -> only [ "port", "text" ] fields *> (Ask <$> ({ port: _, text: _ } <$> text "port" fields <*> text "text" fields))
  other -> Left ("an app never says " <> other)

decodeFromHub :: String -> Either String FromHub
decodeFromHub = opened >=> \(Tuple name fields) -> case name of
  "ports" -> only [ "inputs", "outputs" ] fields *> do
    inputs <- field "inputs" (Json.toArray >=> traverse portOf) "a list of ports" fields
    outputs <- field "outputs" (Json.toArray >=> traverse portOf) "a list of ports" fields
    pure (Ports { inputs, outputs })
  "msg" -> only [ "port", "data" ] fields *> (Msg <$> ({ port: _, bytes: _ } <$> text "port" fields <*> bytesOf fields))
  "error" -> only [ "text" ] fields *> (Error <$> ({ text: _ } <$> text "text" fields))
  "claims" -> only [ "claims", "holders" ] fields *> do
    claims <- field "claims" (table Json.toString) "a table of names" fields
    holders <- field "holders" (table whole) "a table of connection ids" fields
    pure (Claims { claims, holders })
  "you" -> only [ "id" ] fields *> (You <$> ({ id: _ } <$> field "id" whole "a whole number" fields))
  "wanted" -> only [ "port", "by" ] fields *> (Wanted <$> ({ port: _, by: _ } <$> text "port" fields <*> text "by" fields))
  "refused" -> only [ "port", "by", "why" ] fields *>
    (Refused <$> ({ port: _, by: _, why: _ } <$> text "port" fields <*> text "by" fields <*> text "why" fields))
  "sent" -> only [ "port", "data", "by" ] fields *>
    (Sent <$> ({ port: _, bytes: _, by: _ } <$> text "port" fields <*> bytesOf fields <*> text "by" fields))
  "asked" -> only [ "port", "by", "text" ] fields *>
    (Asked <$> ({ port: _, by: _, text: _ } <$> text "port" fields <*> text "by" fields <*> text "text" fields))
  other -> Left ("the hub never says " <> other)
