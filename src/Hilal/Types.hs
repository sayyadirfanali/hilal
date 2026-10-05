module Hilal.Types
  ( Prayer (..)
  , prayerToText
  , prayerFromText
  , prayerLabel
  , PrayerTime (..)
  , hasAllTimings
  , parseClock
  , formatClock
  , formatTimestamp
  , parseTimestamp
  , MosqueId (..)
  , Mosque (..)
  , UserId (..)
  , User (..)
  , SignInCode (..)
  ) where

import Data.Int (Int64)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (TimeOfDay, UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Database.SQLite.Simple.FromField (FromField (..), ResultError (ConversionFailed), returnError)
import Database.SQLite.Simple.ToField (ToField (..))
import Database.SQLite.Simple.FromRow (FromRow (..), RowParser, field, fieldWith)

data Prayer
  = Fajr
  | Zuhr
  | Asr
  | Maghrib
  | Isha
  | Jumuah -- separate from Zuhr
  deriving (Show, Eq, Ord, Enum, Bounded)

prayerToText :: Prayer -> Text
prayerToText p = case p of
  Fajr    -> "fajr"
  Zuhr    -> "zuhr"
  Asr     -> "asr"
  Maghrib -> "maghrib"
  Isha    -> "isha"
  Jumuah  -> "jumuah"

prayerFromText :: Text -> Maybe Prayer
prayerFromText t = find ((== t) . prayerToText) [minBound .. maxBound]

prayerLabel :: Prayer -> Text
prayerLabel p = case p of
  Fajr    -> "Fajr"
  Zuhr    -> "Zuhr"
  Asr     -> "Asr"
  Maghrib -> "Maghrib"
  Isha    -> "Isha"
  Jumuah  -> "Jumu'ah"

instance ToField Prayer where
  toField = toField . prayerToText

instance FromField Prayer where
  fromField f = do
    t <- fromField f
    case prayerFromText t of
      Just p  -> pure p
      Nothing -> returnError ConversionFailed f ("unknown prayer: " <> T.unpack t)

data PrayerTime = PrayerTime
  { ptAzan   :: TimeOfDay -- local Azan time in mosque
  , ptJamaat :: TimeOfDay
  }
  deriving (Show, Eq)

instance FromRow PrayerTime where
  fromRow = PrayerTime <$> clockField <*> clockField

clockField :: RowParser TimeOfDay
clockField = fieldWith $ \f -> do
  t <- fromField f
  case parseClock t of
    Just tod -> pure tod
    Nothing -> returnError ConversionFailed f ("incorrect clock time: " <> T.unpack t)

parseClock :: Text -> Maybe TimeOfDay
parseClock = parseTimeM False defaultTimeLocale "%H:%M" . T.unpack

formatClock :: TimeOfDay -> Text
formatClock = T.pack . formatTime defaultTimeLocale "%H:%M"

formatTimestamp :: UTCTime -> Text
formatTimestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

parseTimestamp :: Text -> Maybe UTCTime
parseTimestamp = parseTimeM False defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" . T.unpack

timestampField :: RowParser UTCTime
timestampField = fieldWith $ \f -> do
  t <- fromField f
  case parseTimestamp t of
    Just u  -> pure u
    Nothing -> returnError ConversionFailed f ("incorrect timestamp: " <> T.unpack t)

hasAllTimings :: [(Prayer, PrayerTime)] -> Bool
hasAllTimings timings = all (`elem` map fst timings) [minBound .. maxBound]

newtype MosqueId = MosqueId Int64
  deriving (Show, Eq, Ord, FromField, ToField)

data Mosque = Mosque
  { mosqueId       :: MosqueId
  , mosqueName     :: Text
  , mosqueAddress  :: Text
  , mosqueLat      :: Maybe Double -- latitude, if known
  , mosqueLng      :: Maybe Double -- longitude, if known
  , mosqueTimezone :: Text         -- Asia/Kolkata
  }
  deriving (Show, Eq)

instance FromRow Mosque where
  fromRow = Mosque <$> field <*> field <*> field <*> field <*> field <*> field

newtype UserId = UserId Int64
  deriving (Show, Eq, Ord, FromField, ToField)

data User = User
  { userId    :: UserId
  , userEmail :: Text
  }
  deriving (Show, Eq)

instance FromRow User where
  fromRow = User <$> field <*> field

data SignInCode = SignInCode
  { codeHash      :: Text
  , codeAttempts  :: Int
  , codeCreatedAt :: UTCTime
  , codeExpiresAt :: UTCTime
  }
  deriving (Show, Eq)

instance FromRow SignInCode where
  fromRow = SignInCode <$> field <*> field <*> timestampField <*> timestampField