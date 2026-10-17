-- | MIDI's own vocabulary, with the ranges in the types.
-- |
-- | Lifted from producing-with-your-feet's `Data.Midi`, which re-exports it.
-- | **Channels are one-based here**, as every manual and every device display
-- | writes them; the zero-based nibble exists only inside the byte builders at
-- | the bottom, so no table anywhere has to say which convention it is in.
module Helm.Midi
  ( Channel
  , makeChannel
  , unsafeChannel
  , unChannel
  , CC
  , makeCC
  , unsafeCC
  , unCC
  , MidiValue
  , makeMidiValue
  , unsafeMidiValue
  , unMidiValue
  , ProgramNumber
  , makeProgramNumber
  , unProgramNumber
  , Kind(..)
  , statusKind
  , statusChannel
  , controlChange
  , programChange
  , noteOn
  , noteOff
  ) where

import Prelude

import Data.Int.Bits (and, or, shr)
import Data.Maybe (Maybe(..))

-- | MIDI channel 1..16
newtype Channel = Channel Int

derive newtype instance Eq Channel
derive newtype instance Ord Channel
derive newtype instance Show Channel

makeChannel :: Int -> Maybe Channel
makeChannel n
  | n >= 1 && n <= 16 = Just (Channel n)
  | otherwise = Nothing

-- | For static tables, where the number is written by hand and known good.
unsafeChannel :: Int -> Channel
unsafeChannel = Channel

unChannel :: Channel -> Int
unChannel (Channel n) = n

-- | MIDI CC number 0..127
newtype CC = CC Int

derive newtype instance Eq CC
derive newtype instance Ord CC
derive newtype instance Show CC

makeCC :: Int -> Maybe CC
makeCC n
  | n >= 0 && n <= 127 = Just (CC n)
  | otherwise = Nothing

-- | Unsafe CC constructor for static definitions where values are known at compile time
unsafeCC :: Int -> CC
unsafeCC = CC

unCC :: CC -> Int
unCC (CC n) = n

-- | MIDI value 0..127
newtype MidiValue = MidiValue Int

derive newtype instance Eq MidiValue
derive newtype instance Ord MidiValue
derive newtype instance Show MidiValue

makeMidiValue :: Int -> Maybe MidiValue
makeMidiValue n
  | n >= 0 && n <= 127 = Just (MidiValue n)
  | otherwise = Nothing

-- | Unsafe MidiValue constructor for static definitions
unsafeMidiValue :: Int -> MidiValue
unsafeMidiValue = MidiValue

unMidiValue :: MidiValue -> Int
unMidiValue (MidiValue n) = n

-- | MIDI program number 0..127
newtype ProgramNumber = ProgramNumber Int

derive newtype instance Eq ProgramNumber
derive newtype instance Ord ProgramNumber
derive newtype instance Show ProgramNumber

makeProgramNumber :: Int -> Maybe ProgramNumber
makeProgramNumber n
  | n >= 0 && n <= 127 = Just (ProgramNumber n)
  | otherwise = Nothing

unProgramNumber :: ProgramNumber -> Int
unProgramNumber (ProgramNumber n) = n

-- | The high nibble of a channel-voice status byte.
data Kind
  = NoteOff
  | NoteOn
  | PolyPressure
  | ControlChange
  | ProgramChange
  | ChannelPressure
  | PitchBend

derive instance Eq Kind

-- | What kind of message a status byte starts. `Nothing` for system messages
-- | (SysEx, clock, …) and for data bytes, which carry no kind.
statusKind :: Int -> Maybe Kind
statusKind status = case shr status 4 of
  0x8 -> Just NoteOff
  0x9 -> Just NoteOn
  0xA -> Just PolyPressure
  0xB -> Just ControlChange
  0xC -> Just ProgramChange
  0xD -> Just ChannelPressure
  0xE -> Just PitchBend
  _ -> Nothing

-- | The channel a status byte addresses, one-based.
statusChannel :: Int -> Channel
statusChannel status = Channel (and status 0x0F + 1)

statusByte :: Int -> Channel -> Int
statusByte nibble (Channel ch) = or nibble (ch - 1)

controlChange :: Channel -> CC -> MidiValue -> Array Int
controlChange ch (CC cc) (MidiValue v) = [ statusByte 0xB0 ch, cc, v ]

programChange :: Channel -> ProgramNumber -> Array Int
programChange ch (ProgramNumber pc) = [ statusByte 0xC0 ch, pc ]

noteOn :: Channel -> Int -> Int -> Array Int
noteOn ch note velocity = [ statusByte 0x90 ch, and note 0x7F, and velocity 0x7F ]

noteOff :: Channel -> Int -> Array Int
noteOff ch note = [ statusByte 0x80 ch, and note 0x7F, 0 ]
