-- | Writes `conformance/vectors/helm-hub.json` to standard output.
module Hub.Generate (main, appTable, hubTable) where

import Prelude

import Data.Argonaut.Core (Json)
import Effect (Effect)
import Effect.Console (log)
import Hawser.Document as Document
import Hub.Check (vectors)
import Hub.Protocol (fromHubRows, toHubRows)

foreign import pretty :: Json -> String

main :: Effect Unit
main = log (pretty vectors)

-- | The two tables of `conformance/HELM-HUB.md`, which `hub/declaration.mjs`
-- | writes into it and checks.
appTable :: String
appTable = Document.table "`t`" toHubRows

hubTable :: String
hubTable = Document.table "`t`" fromHubRows
