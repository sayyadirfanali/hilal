module Hilal.Query
  ( getMosque
  , getTimings
  , saveTiming
  , searchMosques
  , getLastUpdated
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Database.SQLite.Simple (Connection, Only (..), execute, query, (:.) (..))

import Hilal.Types
    ( MosqueId,
      Mosque,
      Prayer,
      PrayerTime(ptJamaat, ptAzan),
      formatClock )

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

searchMosques :: Connection -> Int -> Text -> IO [Mosque]
searchMosques conn limit q =
  query conn
    "SELECT id, name, address, lat, lng, timezone FROM mosques \
    \WHERE (SELECT COUNT(*) FROM timings WHERE timings.mosque_id = mosques.id) = ? \
    \  AND (instr(lower(name), lower(?)) > 0 OR instr(lower(address), lower(?)) > 0) \
    \ORDER BY name COLLATE NOCASE \
    \LIMIT ?"
    (prayerCount, q, q, limit)
  where
    prayerCount = length [minBound .. maxBound :: Prayer]

getLastUpdated :: Connection -> MosqueId -> IO (Maybe UTCTime)
getLastUpdated conn mid = do
  rows <- query conn "SELECT MAX(updated_at) FROM timings WHERE mosque_id = ?" (Only mid)
  return $ case rows of
    [Only (Just t)] -> parseTimeM False defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack t)
    _               -> Nothing