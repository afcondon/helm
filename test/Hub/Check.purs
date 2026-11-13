-- | Holds the reference codec to the declared cases, and writes the vector
-- | file the hub and the client replay.
module Hub.Check (failures, summary, vectors) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as Json
import Data.Array as Array
import Data.Either (Either(..), isRight)
import Data.Tuple (Tuple(..))
import Foreign.Object as Object
import Hub.Cases (Direction(..), FrameCase, Scenario, Step(..), appFrames, frameCases, scenarios)
import Hub.Protocol (FromHub, ToHub, decodeFromHub, decodeToHub, encodeFromHub, encodeToHub, fromHubName, fromHubNames, toHubName, toHubNames)

failures :: Array String
failures =
  Array.concatMap frameFailures frameCases
    <> duplicateNames "frames" (map (\testCase -> directionName testCase.direction <> "/" <> testCase.name) frameCases)
    <> duplicateNames "scenarios" (map _.name scenarios)
    <> coverage "an app" toHubNames (map toHubName appFrames <> saidInScenarios)
    <> coverage "the hub" fromHubNames heardInScenarios
    <> Array.concatMap (roundTrip "app" encodeToHub decodeToHub) (appFrames <> Array.concatMap said scenarios)
    <> Array.concatMap (roundTrip "hub" encodeFromHub decodeFromHub) (Array.concatMap heard scenarios)

summary :: String
summary =
  show (Array.length frameCases) <> " frame cases, "
    <> show (Array.length appFrames)
    <> " app frames, "
    <> show (Array.length scenarios)
    <> " scenarios"

directionName :: Direction -> String
directionName = case _ of
  App -> "app"
  Hub -> "hub"

-- | The reference's verdict on a frame against the declared one.
frameFailures :: FrameCase -> Array String
frameFailures testCase =
  let
    accepted = case testCase.direction of
      App -> isRight (decodeToHub testCase.text)
      Hub -> isRight (decodeFromHub testCase.text)
  in
    if accepted == testCase.accept then []
    else
      [ directionName testCase.direction <> "/" <> testCase.name <> ": declared "
          <> (if testCase.accept then "accept" else "refuse")
          <> ", the reference disagrees"
      ]

-- | Writing a frame and reading it back gives the same value.
roundTrip :: forall a. Eq a => String -> (a -> Json) -> (String -> Either String a) -> a -> Array String
roundTrip label encode decode value =
  let
    written = Json.stringify (encode value)
  in
    if decode written == Right value then [] else [ label <> ": does not read back: " <> written ]

said :: Scenario -> Array ToHub
said scenario = Array.mapMaybe
  ( case _ of
      Says _ message -> pure message
      _ -> Array.head []
  )
  scenario.steps

heard :: Scenario -> Array FromHub
heard scenario = Array.mapMaybe
  ( case _ of
      Hears _ message -> pure message
      _ -> Array.head []
  )
  scenario.steps

saidInScenarios :: Array String
saidInScenarios = map toHubName (Array.concatMap said scenarios)

-- | Errors are heard through `HearsError`, which carries no frame.
heardInScenarios :: Array String
heardInScenarios = map fromHubName (Array.concatMap heard scenarios) <> [ "error" ]

-- | Every kind of frame appears in at least one case, so that a kind added
-- | to the type without a case fails here.
coverage :: String -> Array String -> Array String -> Array String
coverage who declared used =
  Array.filter (\name -> not (Array.elem name used)) declared
    <#> \name -> "nothing exercises what " <> who <> " says as " <> name

duplicateNames :: String -> Array String -> Array String
duplicateNames section names =
  if Array.length (Array.nub names) == Array.length names then []
  else [ section <> ": two cases share a name" ]

-- ── The vector file ────────────────────────────────────────────────────────

object :: Array (Tuple String Json) -> Json
object = Object.fromFoldable >>> Json.fromObject

text :: String -> String -> Tuple String Json
text key value = Tuple key (Json.fromString value)

stepJson :: Step -> Json
stepJson = case _ of
  Connects who -> object [ text "connects" who ]
  Says who message -> object [ text "says" who, Tuple "frame" (encodeToHub message) ]
  SaysText who frame -> object [ text "says" who, text "text" frame ]
  Hears who message -> object [ text "hears" who, Tuple "frame" (encodeFromHub message) ]
  HearsError who -> object [ text "hears" who, Tuple "frame" (object [ text "t" "error" ]), Tuple "anyText" (Json.fromBoolean true) ]
  Leaves who -> object [ text "leaves" who ]

vectors :: Json
vectors = object
  [ Tuple "helm-hub-vectors" (Json.fromNumber 1.0)
  , text "declaration" "conformance/HELM-HUB.md"
  , text "generatedBy" "Hub.Check in helm; do not edit by hand, run `make vectors`"
  , Tuple "appSays" (Json.fromArray (map Json.fromString toHubNames))
  , Tuple "hubSays" (Json.fromArray (map Json.fromString fromHubNames))
  , Tuple "frames" $ Json.fromArray $ frameCases <#> \testCase -> object
      [ text "name" testCase.name
      , text "from" (directionName testCase.direction)
      , text "text" testCase.text
      , text "expect" (if testCase.accept then "accept" else "refuse")
      , text "why" testCase.why
      ]
  , Tuple "appFrames" (Json.fromArray (map encodeToHub appFrames))
  , Tuple "scenarios" $ Json.fromArray $ scenarios <#> \scenario -> object
      [ text "name" scenario.name
      , text "why" scenario.why
      , Tuple "steps" (Json.fromArray (map stepJson scenario.steps))
      ]
  ]
