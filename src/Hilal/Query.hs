module Hilal.Query
  ( getMosque
  , getTimings
  , saveTiming
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Database.SQLite.Simple (Connection, Only (..), execute, query, (:.) (..))
import Hilal.Types

getMosque :: Connection -> MosqueId -> IO (Maybe Mosque)
getMosque conn mid = do
  rows <- query conn
    "SELECT id, name, address, lat, lng, timezone FROM mosques WHERE id = ?" (Only mid)
  pure $ case rows of
    [m] -> Just m
    _   -> Nothing

getTimings :: Connection -> MosqueId -> IO [(Prayer, PrayerTime)]
getTimings conn mid = do
  rows <- query conn
    "SELECT prayer, azan_time, jamaat_time FROM timings WHERE mosque_id = ?" (Only mid)
  pure $ map toPair rows
  where
    toPair (Only p :. t) = (p, t)

saveTiming :: Connection -> UTCTime -> MosqueId -> Prayer -> PrayerTime -> IO ()
saveTiming conn now mid p t =
  execute conn
    "INSERT INTO timings (mosque_id, prayer, azan_time, jamaat_time, updated_at) \
    \VALUES (?, ?, ?, ?, ?) \
    \ON CONFLICT (mosque_id, prayer) DO UPDATE SET \
    \  azan_time   = excluded.azan_time, \
    \  jamaat_time = excluded.jamaat_time, \
    \  updated_at  = excluded.updated_at"
    (mid, p, formatClock (ptAzan t), formatClock (ptJamaat t), timestamp now)

timestamp :: UTCTime -> Text
timestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"