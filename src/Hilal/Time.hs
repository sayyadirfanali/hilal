module Hilal.Time
  ( lookupZone
  , zoneNames
  , nextPrayer
  , upcomingToday
  ) where

import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time (Day, DayOfWeek (Friday), LocalTime (..), TimeOfDay (..), addDays, dayOfWeek)
import Data.Time.Zones (TZ)
import Data.Time.Zones.All (TZLabel, toTZName, tzByName)

import Hilal.Types (Prayer (..), PrayerTime (..))

lookupZone :: Text -> Maybe TZ
lookupZone = tzByName . encodeUtf8

zoneNames :: [Text]
zoneNames = map (decodeUtf8 . toTZName) [minBound .. maxBound :: TZLabel]

nextPrayer :: LocalTime -> [(Prayer, PrayerTime)] -> Maybe (Day, Prayer)
nextPrayer (LocalTime today now) timings =
  case filter notPassed (scheduled today) of
    (p, _) : _ -> Just (today, p)
    [] -> case scheduled tomorrow of
      (p, _) : _ -> Just (tomorrow, p)
      []         -> Nothing
  where
    tomorrow = addDays 1 today
    scheduled day = mapMaybe withTiming (prayersOn day)
    withTiming p = (\t -> (p, t)) <$> lookup p timings
    notPassed (_, t) = minute now <= minute (ptJamaat t)

upcomingToday :: LocalTime -> [(Prayer, PrayerTime)] -> [Prayer]
upcomingToday (LocalTime today now) timings =
  filter ahead (prayersOn today)
  where
    ahead p = maybe False (\t -> minute now <= minute (ptJamaat t)) (lookup p timings)

prayersOn :: Day -> [Prayer]
prayersOn day
  | dayOfWeek day == Friday = [Fajr, Jumuah, Asr, Maghrib, Isha]
  | otherwise               = [Fajr, Zuhr, Asr, Maghrib, Isha]

minute :: TimeOfDay -> (Int, Int)
minute t = (todHour t, todMin t)
