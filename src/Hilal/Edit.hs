module Hilal.Edit
  ( MosqueForm (..)
  , ValidMosque (..)
  , emptyForm
  , formFromMosque
  , validateForm
  , changedTimings
  , creationLog
  , editLog
  , logLine
  ) where

import Data.Either (lefts, rights)
import Data.Maybe (catMaybes, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)

import Hilal.Location (Place (..))
import Hilal.Time (lookupZone)
import Hilal.Types
  ( Coords (..)
  , Mosque (..)
  , MosqueId (..)
  , Prayer
  , PrayerTime (..)
  , UserId (..)
  , formatClock
  , formatTimestamp
  , parseClock
  , prayerLabel
  , prayerToText
  )

-- The name always comes from Google Maps, never from what was typed.
data MosqueForm = MosqueForm
  { formName     :: Text
  , formAddress  :: Text
  , formTimezone :: Text
  , formLocation :: Text -- the place's link; only used when adding
  , formLat      :: Text -- the pin placed on the map; only used when adding
  , formLng      :: Text
  , formTimes    :: [(Prayer, (Text, Text))]
  }
  deriving (Show, Eq)

data ValidMosque = ValidMosque
  { validName     :: Text
  , validAddress  :: Text
  , validTimezone :: Text
  , validTimings  :: [(Prayer, PrayerTime)]
  }
  deriving (Show, Eq)

emptyForm :: MosqueForm
emptyForm =
  MosqueForm "" "" "Asia/Kolkata" "" "" "" (map (\p -> (p, ("", ""))) [minBound .. maxBound])

formFromMosque :: Mosque -> [(Prayer, PrayerTime)] -> MosqueForm
formFromMosque m timings =
  MosqueForm (mosqueName m) (mosqueAddress m) (mosqueTimezone m) "" "" "" (map getTimes [minBound .. maxBound])
  where
    getTimes p = (p, maybe ("", "") clockPair (lookup p timings))
    clockPair t = (formatClock (ptAzan t), formatClock (ptJamaat t))

validateForm :: MosqueForm -> Either [Text] ValidMosque
validateForm f
  | null errors = Right (ValidMosque name address zone (rights checked))
  | otherwise   = Left errors
  where
    name    = T.strip (formName f)
    address = T.strip (formAddress f)
    zone    = T.strip (formTimezone f)
    checked = map checkPrayer (formTimes f)
    errors  =
      catMaybes
        [ whenTrue (T.null name) "Please enter the mosque's name."
        , whenTrue (T.length name > 200) "The name is too long."
        , whenTrue (T.null address) "Please enter the address, for example \"Sector 6, Bhilai\"."
        , whenTrue (T.length address > 300) "The address is too long."
        , whenTrue (isNothing (lookupZone zone)) "Please choose a valid time zone."
        ]
        <> lefts checked
    whenTrue cond message = if cond then Just message else Nothing

checkPrayer :: (Prayer, (Text, Text)) -> Either Text (Prayer, PrayerTime)
checkPrayer (p, (azanText, jamaatText)) =
  case (parseClock (T.strip azanText), parseClock (T.strip jamaatText)) of
    (Just azan, Just jamaat)
      | jamaat >= azan -> Right (p, PrayerTime azan jamaat)
      | otherwise      -> Left (prayerLabel p <> ": Jamaat can't be earlier than Azan.")
    _ -> Left (prayerLabel p <> ": please enter both the Azan and Jamaat times.")

changedTimings :: [(Prayer, PrayerTime)] -> [(Prayer, PrayerTime)] -> [(Prayer, PrayerTime)]
changedTimings old = filter (\(p, t) -> lookup p old /= Just t)

logLine :: UTCTime -> UserId -> MosqueId -> Text -> Text
logLine now (UserId u) (MosqueId m) change =
  formatTimestamp now <> " user=" <> T.pack (show u) <> " mosque=" <> T.pack (show m) <> " " <> change

creationLog :: ValidMosque -> Place -> Coords -> [Text]
creationLog v p (Coords lat lng) =
  ( "created name=" <> quoted (validName v)
      <> " address=" <> quoted (validAddress v)
      <> " timezone=" <> quoted (validTimezone v)
      <> " google_place=" <> quoted (placeId p)
      <> " lat=" <> T.pack (show lat)
      <> " lng=" <> T.pack (show lng)
  )
    : map (\(pr, t) -> prayerToText pr <> ": " <> times t) (validTimings v)

editLog :: Mosque -> [(Prayer, PrayerTime)] -> ValidMosque -> [Text]
editLog m old v =
  catMaybes
    [ field "name" (mosqueName m) (validName v)
    , field "address" (mosqueAddress m) (validAddress v)
    , field "timezone" (mosqueTimezone m) (validTimezone v)
    ]
    <> map timingChange (changedTimings old (validTimings v))
  where
    field key before after
      | before == after = Nothing
      | otherwise       = Just (key <> ": " <> quoted before <> " -> " <> quoted after)
    timingChange (p, t) =
      prayerToText p <> ": " <> maybe "unset" times (lookup p old) <> " -> " <> times t

times :: PrayerTime -> Text
times t = formatClock (ptAzan t) <> "/" <> formatClock (ptJamaat t)

quoted :: Text -> Text
quoted = T.pack . show
