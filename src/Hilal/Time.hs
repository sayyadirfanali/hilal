module Hilal.Time
  ( lookupZone
  , nextPrayer
  ) where

import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Time (Day, DayOfWeek (Friday), LocalTime (..), TimeOfDay (..), addDays, dayOfWeek)
import Data.Time.Zones (TZ)
import Data.Time.Zones.All (tzByName)

import Hilal.Types (Prayer (..), PrayerTime (..))

lookupZone :: Text -> Maybe TZ
lookupZone = tzByName . encodeUtf8

nextPrayer :: LocalTime -> [(Prayer, PrayerTime)] -> Maybe (Day, Prayer)
nextPrayer (LocalTime today now) timings =
  case [p | p <- prayersOn today, Just t <- [lookup p timings], minute now <= minute (ptJamaat t)] of
    p : _ -> Just (today, p)
    [] -> case [p | p <- prayersOn tomorrow, isJust (lookup p timings)] of
      p : _ -> Just (tomorrow, p)
      []    -> Nothing
  where
    tomorrow = addDays 1 today
    minute t = (todHour t, todMin t)

prayersOn :: Day -> [Prayer]
prayersOn day
  | dayOfWeek day == Friday = [Fajr, Jumuah, Asr, Maghrib, Isha]
  | otherwise               = [Fajr, Zuhr, Asr, Maghrib, Isha]