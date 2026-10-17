-- | The Midifighter Twister, as a device: what it sends, what its lights take.
-- |
-- | Facts about the hardware, and nothing about what a knob means; that is
-- | each app's binding. Lifted from producing-with-your-feet's `Data.Twister`
-- | and `Component.Twister.Lights`, which had learned all of it the hard way.
-- |
-- | Sixteen encoders, each **both a knob and a button**, in four layers
-- | ("banks" in the Midifighter Utility; see `Helm.Layers`). The device shifts the CC by sixteen
-- | per layer, so layer *b* encoder *i* speaks on CC `16b + i`, on channel 1
-- | for the turn, channel 2 for the switch. The lights are addressed the same
-- | way: channel 1 sets the ring, channel 2 the colour.
-- |
-- | **Zero-based on both counts.** The device's own numbering is one-based on
-- | the layer; converting once here is cheaper than remembering which
-- | convention a given table is in. (Phase 1 of `docs/kb/plans/helm.md` asks
-- | for this to be settled against the device: what a turn of the top-left
-- | encoder of the first layer actually sends is CC 0 if this is right.)
-- |
-- | **The Twister stores a value per encoder per layer**, and those stores
-- | survive a reload. Four stores behind one knob is why PWYF stopped paging
-- | by layer and pinned the device to layer 0; that is a binding decision, but
-- | the fact it rests on lives here.
module Helm.Twister
  ( Knob
  , TwisterMsg(..)
  , layers
  , layering
  , encodersPerLayer
  , knobCC
  , layerOf
  , parse
  , ring
  , colour
  , ringBrightness
  , colourBrightness
  , layerSelect
  , port
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Helm.Layers (Chooser(..), Layering, Report(..))
import Helm.Midi (Kind(..), statusChannel, statusKind, unChannel)
import Helm.WebMIDI (PortMatch(..))

-- | Which encoder, on which layer. Zero-based.
type Knob = { layer :: Int, index :: Int }

data TwisterMsg
  -- | The encoder's absolute position, 0–127.
  = Turn Knob Int
  | Press Knob
  | Release Knob
  -- | A side button, as `CC - 8` on channel 5: 0, 1 and 2 are the three PWYF
  -- | has bound. **The channel is this unit's configuration**, not factory
  -- | default, and the side buttons that change layer are handled by the
  -- | device itself and never reported.
  | Side Int

derive instance Eq TwisterMsg

instance Show TwisterMsg where
  show = case _ of
    Turn k v -> "(Turn " <> showKnob k <> " " <> show v <> ")"
    Press k -> "(Press " <> showKnob k <> ")"
    Release k -> "(Release " <> showKnob k <> ")"
    Side n -> "(Side " <> show n <> ")"
    where
    showKnob k = show k.layer <> "/" <> show k.index

layers :: Int
layers = 4

encodersPerLayer :: Int
encodersPerLayer = 16

layering :: Layering
layering =
  { term: "bank"
  , count: layers
  , controlsPerLayer: encodersPerLayer
  , chooser: DeviceOrHost
  , report: InEveryMessage
  , valuesPerLayer: true
  }

knobCC :: Knob -> Int
knobCC k = k.layer * encodersPerLayer + k.index

knobOf :: Int -> Knob
knobOf cc = { layer: cc / encodersPerLayer, index: cc `mod` encodersPerLayer }

-- | Which layer a raw message came from — the one *certain* answer to "where
-- | is the device", since it travels in every encoder message. `Nothing` for
-- | messages that carry no layer (the side buttons' CC means something else).
layerOf :: Array Int -> Maybe Int
layerOf bytes = do
  status <- Array.index bytes 0
  cc <- Array.index bytes 1
  let ch = unChannel (statusChannel status)
  if statusKind status == Just ControlChange && (ch == 1 || ch == 2) then Just (cc / encodersPerLayer)
  else Nothing

parse :: Array Int -> Maybe TwisterMsg
parse bytes = do
  status <- Array.index bytes 0
  cc <- Array.index bytes 1
  val <- Array.index bytes 2
  if statusKind status /= Just ControlChange then Nothing
  else case unChannel (statusChannel status) of
    1 -> Just (Turn (knobOf cc) val)
    2
      | val == 127 -> Just (Press (knobOf cc))
      | otherwise -> Just (Release (knobOf cc))
    5 | cc >= 8 && cc <= 13 -> Just (Side (cc - 8))
    _ -> Nothing

-- | Set an encoder's ring, 0–127, without the device sending anything back.
ring :: Knob -> Int -> Array Int
ring k v = [ 0xB0, knobCC k, clamp 0 127 v ]

-- | Set an encoder's colour, as a position on the device's hue wheel, 0–127.
colour :: Knob -> Int -> Array Int
colour k hue = [ 0xB1, knobCC k, clamp 0 127 hue ]

-- | How bright an encoder's ring is, 0 (off) to 30 (full): channel 3, values
-- | 65–95.
-- |
-- | A ring at position 0 still shows its first LED, so this is the only way
-- | to make an encoder look *unused* rather than "at zero".
-- |
-- | Channel 3 is the device's animation channel. Verified 2026-10-17 on the
-- | Selene page's surfaces, whose unused encoders go dark.
ringBrightness :: Knob -> Int -> Array Int
ringBrightness k level = [ 0xB2, knobCC k, 65 + clamp 0 30 level ]

-- | How bright an encoder's colour LED is, 0 (off) to 30 (full): channel 3,
-- | values 17–47. Verified with `ringBrightness`.
colourBrightness :: Knob -> Int -> Array Int
colourBrightness k level = [ 0xB2, knobCC k, 17 + clamp 0 30 level ]

-- | Ask the device to show a layer: channel 4, CC 0–3, value 127.
-- |
-- | Verified 2026-10-17: PWYF sends it on hearing another layer, and the
-- | device goes back to layer 0 as soon as an encoder there is used.
layerSelect :: Int -> Array Int
layerSelect b = [ 0xB3, clamp 0 (layers - 1) b, 127 ]

-- | How to find the Twister among the ports.
port :: PortMatch
port = NameContains "Twister"
