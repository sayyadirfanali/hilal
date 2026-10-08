module Hilal.JSON
  ( timingsJson
  , followedJson
  , notFoundJson
  , notSignedInJson
  ) where

import Data.Aeson (Value, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)

import Hilal.Azan (Recording, recordingName)
import Hilal.Types
  ( Mosque (..)
  , MosqueId (..)
  , Prayer
  , PrayerTime (..)
  , formatClock
  , prayerToText
  )

-- The recordings it lists can be fetched from /mosques/:id/azan and /mosques/:id/azan-fajr.
timingsJson :: Mosque -> [Recording] -> [(Prayer, PrayerTime)] -> BL.ByteString
timingsJson mosque recordings timings =
  encode $ object
    [ "mosque"     .= mid
    , "timezone"   .= mosqueTimezone mosque
    , "timings"    .= object (map timing timings)
    , "recordings" .= map recordingName recordings
    ]
  where
    MosqueId mid = mosqueId mosque
    timing (p, t) =
      Key.fromText (prayerToText p) .= object
        [ "azan"   .= formatClock (ptAzan t)
        , "jamaat" .= formatClock (ptJamaat t)
        ]

followedJson :: [Mosque] -> Value
followedJson mosques =
  object ["mosques" .= map entry mosques]
  where
    entry Mosque { mosqueId = MosqueId mid, mosqueName = name } =
      object
        [ "id"   .= mid
        , "name" .= name
        ]

notFoundJson :: Value
notFoundJson = object ["error" .= ("not found" :: Text)]

notSignedInJson :: Value
notSignedInJson = object ["error" .= ("not signed in" :: Text)]

