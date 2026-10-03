module Hilal.JSON
  ( timingsJson
  , notFoundJson
  ) where

import Data.Aeson (Value, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)

import Hilal.Types
  ( Mosque (..)
  , MosqueId (..)
  , Prayer
  , PrayerTime (..)
  , formatClock
  , prayerToText
  )

timingsJson :: Mosque -> [(Prayer, PrayerTime)] -> BL.ByteString
timingsJson mosque timings =
  encode $ object
    [ "mosque"   .= mid
    , "timezone" .= mosqueTimezone mosque
    , "timings"  .= object (map timing timings)
    ]
  where
    MosqueId mid = mosqueId mosque
    timing (p, t) =
      Key.fromText (prayerToText p) .= object
        [ "azan"   .= formatClock (ptAzan t)
        , "jamaat" .= formatClock (ptJamaat t)
        ]

notFoundJson :: Value
notFoundJson = object ["error" .= ("not found" :: Text)]