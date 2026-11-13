-- | Writes `conformance/vectors/helm-hub.json` to standard output.
module Hub.Generate (main) where

import Prelude

import Data.Argonaut.Core (Json)
import Effect (Effect)
import Effect.Console (log)
import Hub.Check (vectors)

foreign import pretty :: Json -> String

main :: Effect Unit
main = log (pretty vectors)
