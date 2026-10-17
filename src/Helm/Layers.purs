-- | One set of physical controls standing for several sets of virtual ones.
-- |
-- | Most controllers do it and each has its own word: the Twister's and the
-- | MC6's *banks*, the BCR-2000's *encoder groups*. Helm calls it a **layer**
-- | in code, and keeps the device's word in `term` for anything a player
-- | reads. "Bank" and "page" are deliberately avoided: PWYF already means
-- | MC6 banks and its own looper pages by them, and a Twister bank quietly
-- | doubling as a looper page is a confusion this module exists to end.
-- |
-- | **The name is the least of it.** What actually went wrong on the Twister
-- | was not a word but three facts nobody had written down, and they are the
-- | fields here: who changes the layer, whether the device tells you, and
-- | whether each layer keeps its own values. A layer the device changes by
-- | itself, reports in every message, and stores values for is a different
-- | thing to bind against than one the host selects and the device forgets.
-- |
-- | A layer is something the *device* holds. An app that pages its own
-- | meanings over one layer — PWYF's looper does — is doing something else,
-- | and that is its own business.
-- |
-- | Not designed for seven devices up front: this is what the Twister needs,
-- | and the BCR-2000 (Phase 2 of `docs/kb/plans/helm.md`) is the test of it.
module Helm.Layers
  ( Layering
  , Chooser(..)
  , Report(..)
  ) where

-- | Who changes which layer is showing.
data Chooser
  -- | Only the device's own buttons.
  = DeviceOnly
  -- | The device's buttons, and the host by a message.
  | DeviceOrHost

-- | How the host learns which layer is showing.
data Report
  -- | It travels in every message the device sends (the Twister's CC block).
  = InEveryMessage
  -- | The device sends a message when the layer changes.
  | OnChange
  -- | It doesn't; the host can only know what it last asked for.
  | Never

type Layering =
  { -- | What the device's own manual and display call a layer.
    term :: String
  , count :: Int
  , controlsPerLayer :: Int
  , chooser :: Chooser
  , report :: Report
  -- | Whether the device keeps a value per control *per layer*. If it does,
  -- | changing layer changes what a control reports from, and those stores
  -- | survive a reload.
  , valuesPerLayer :: Boolean
  }
