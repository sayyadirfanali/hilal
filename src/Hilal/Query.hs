module Hilal.Query
  ( getMosque
  , getTimings
  , saveTiming
  , searchMosques
  , getLastUpdated
  , createMosque
  , updateMosque
  , saveSignInCode
  , getSignInCode
  , incrementCodeAttempts
  , deleteSignInCode
  , deleteExpired
  , findOrCreateUser
  , isBlocked
  , makeSession
  , getSessionUser
  , killSession
  , followMosque
  , unfollowMosque
  , isFollowing
  , followedMosques
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.SQLite.Simple (Connection, Only (..), execute, lastInsertRowId, query, (:.) (..))

import Hilal.Types
  ( Coords (..)
  , Mosque
  , MosqueId (..)
  , Prayer
  , PrayerTime (ptAzan, ptJamaat)
  , SignInCode
  , User
  , UserId
  , formatClock
  , formatTimestamp
  , parseTimestamp
  )

getMosque :: Connection -> MosqueId -> IO (Maybe Mosque)
getMosque conn mid = do
  rows <- query conn
    "SELECT id, name, address, lat, lng, timezone FROM mosques WHERE id = ?" (Only mid)
  return $ case rows of
    [m] -> Just m
    _   -> Nothing

getTimings :: Connection -> MosqueId -> IO [(Prayer, PrayerTime)]
getTimings conn mid = do
  rows <- query conn
    "SELECT prayer, azan_time, jamaat_time FROM timings WHERE mosque_id = ?" (Only mid)
  return $ map toPair rows
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
    (mid, p, formatClock (ptAzan t), formatClock (ptJamaat t), formatTimestamp now)

-- Nothing means no limit; SQLite treats a negative LIMIT as none.
searchMosques :: Connection -> Maybe Int -> Text -> IO [Mosque]
searchMosques conn limit q =
  query conn
    "SELECT id, name, address, lat, lng, timezone FROM mosques \
    \WHERE (SELECT COUNT(*) FROM timings WHERE timings.mosque_id = mosques.id) = ? \
    \  AND (instr(lower(name), lower(?)) > 0 OR instr(lower(address), lower(?)) > 0) \
    \ORDER BY name COLLATE NOCASE \
    \LIMIT ?"
    (prayerCount, q, q, fromMaybe (-1) limit)
  where
    prayerCount = length [minBound .. maxBound :: Prayer]

getLastUpdated :: Connection -> MosqueId -> IO (Maybe UTCTime)
getLastUpdated conn mid = do
  rows <- query conn "SELECT MAX(updated_at) FROM timings WHERE mosque_id = ?" (Only mid)
  return $ case rows of
    [Only (Just t)] -> parseTimestamp t
    _               -> Nothing

createMosque :: Connection -> Text -> Text -> Text -> Coords -> IO MosqueId
createMosque conn name address timezone (Coords lat lng) = do
  execute conn
    "INSERT INTO mosques (name, address, lat, lng, timezone) VALUES (?, ?, ?, ?, ?)"
    (name, address, lat, lng, timezone)
  MosqueId <$> lastInsertRowId conn

updateMosque :: Connection -> MosqueId -> Text -> Text -> Text -> IO ()
updateMosque conn mid name address timezone =
  execute conn
    "UPDATE mosques SET name = ?, address = ?, timezone = ? WHERE id = ?"
    (name, address, timezone, mid)

saveSignInCode :: Connection -> UTCTime -> UTCTime -> Text -> Text -> IO ()
saveSignInCode conn now expires email hashed =
  execute conn
    "INSERT INTO sign_in_codes (email, code_hash, attempts, created_at, expires_at) \
    \VALUES (?, ?, 0, ?, ?) \
    \ON CONFLICT (email) DO UPDATE SET \
    \  code_hash  = excluded.code_hash, \
    \  attempts   = 0, \
    \  created_at = excluded.created_at, \
    \  expires_at = excluded.expires_at"
    (email, hashed, formatTimestamp now, formatTimestamp expires)

getSignInCode :: Connection -> Text -> IO (Maybe SignInCode)
getSignInCode conn email = do
  rows <- query conn
    "SELECT code_hash, attempts, created_at, expires_at FROM sign_in_codes WHERE email = ?"
    (Only email)
  return $ case rows of
    [c] -> Just c
    _   -> Nothing

incrementCodeAttempts :: Connection -> Text -> IO ()
incrementCodeAttempts conn email =
  execute conn "UPDATE sign_in_codes SET attempts = attempts + 1 WHERE email = ?" (Only email)

deleteSignInCode :: Connection -> Text -> IO ()
deleteSignInCode conn email =
  execute conn "DELETE FROM sign_in_codes WHERE email = ?" (Only email)

-- Timestamps share one fixed format, so comparing them as text compares them as times.
deleteExpired :: Connection -> UTCTime -> IO ()
deleteExpired conn now = do
  execute conn "DELETE FROM sign_in_codes WHERE expires_at <= ?" (Only (formatTimestamp now))
  execute conn "DELETE FROM sessions WHERE expires_at <= ?" (Only (formatTimestamp now))

findOrCreateUser :: Connection -> UTCTime -> Text -> IO User
findOrCreateUser conn now email = do
  execute conn
    "INSERT INTO users (email, created_at) VALUES (?, ?) ON CONFLICT (email) DO NOTHING"
    (email, formatTimestamp now)
  rows <- query conn "SELECT id, email FROM users WHERE email = ?" (Only email)
  case rows of
    [u] -> return u
    _   -> ioError (userError "findOrCreateUser: user missing after insert")

isBlocked :: Connection -> Text -> IO Bool
isBlocked conn email = do
  rows <- query conn "SELECT blocked FROM users WHERE email = ?" (Only email)
  return $ case rows of
    [Only b] -> b /= (0 :: Int)
    _        -> False

makeSession :: Connection -> UTCTime -> UTCTime -> UserId -> Text -> IO ()
makeSession conn now expires uid tokenHash =
  execute conn
    "INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)"
    (tokenHash, uid, formatTimestamp now, formatTimestamp expires)

getSessionUser :: Connection -> UTCTime -> Text -> IO (Maybe User)
getSessionUser conn now tokenHash = do
  rows <- query conn
    "SELECT users.id, users.email FROM sessions \
    \JOIN users ON users.id = sessions.user_id \
    \WHERE sessions.token_hash = ? AND sessions.expires_at > ? AND users.blocked = 0"
    (tokenHash, formatTimestamp now)
  return $ case rows of
    [u] -> Just u
    _   -> Nothing

killSession :: Connection -> Text -> IO ()
killSession conn tokenHash =
  execute conn "DELETE FROM sessions WHERE token_hash = ?" (Only tokenHash)

followMosque :: Connection -> UTCTime -> UserId -> MosqueId -> IO ()
followMosque conn now uid mid =
  execute conn
    "INSERT INTO follows (user_id, mosque_id, created_at) VALUES (?, ?, ?) \
    \ON CONFLICT (user_id, mosque_id) DO NOTHING"
    (uid, mid, formatTimestamp now)

unfollowMosque :: Connection -> UserId -> MosqueId -> IO ()
unfollowMosque conn uid mid =
  execute conn "DELETE FROM follows WHERE user_id = ? AND mosque_id = ?" (uid, mid)

isFollowing :: Connection -> UserId -> MosqueId -> IO Bool
isFollowing conn uid mid = do
  rows <- query conn
    "SELECT 1 FROM follows WHERE user_id = ? AND mosque_id = ?"
    (uid, mid) :: IO [Only Int]
  return (not (null rows))

followedMosques :: Connection -> UserId -> IO [Mosque]
followedMosques conn uid =
  query conn
    "SELECT mosques.id, mosques.name, mosques.address, mosques.lat, mosques.lng, mosques.timezone \
    \FROM follows JOIN mosques ON mosques.id = follows.mosque_id \
    \WHERE follows.user_id = ? \
    \ORDER BY mosques.name COLLATE NOCASE"
    (Only uid)
