module Main (main) where

import Control.Monad (forM_)
import Data.Text.Encoding (encodeUtf8)
import Data.Time (TimeOfDay (..), UTCTime (..), fromGregorian)
import Database.SQLite.Simple (Connection, Only (..), execute, execute_, query_)
import Lucid (renderText)
import Network.Wai (Application)
import System.IO.Temp (emptySystemTempFile)
import Test.Hspec
import Test.Hspec.Wai
import Data.Text.Lazy qualified as TL

import Hilal.App (app)
import Hilal.DB (withDb)
import Hilal.Migrate (migrate)
import Hilal.Query
import Hilal.Types
import Hilal.Views (clockDigits, clockPeriod, mosquePage, stylesheetPath)

testApp :: IO Application
testApp = do
  path <- emptySystemTempFile "hilal-test.db"
  withDb path $ \conn -> do
    migrate conn
    execute_ conn
      "INSERT INTO mosques (id, name, address, lat, lng, timezone) \
      \VALUES (1, 'Jama Masjid', 'Old Delhi', 28.6507, 77.2334, 'Asia/Kolkata')"
    saveTiming conn noon (MosqueId 1) Fajr (timesAt 5)
  app path

withTestDb :: (Connection -> IO a) -> IO a
withTestDb action =
  withDb ":memory:" $ \conn -> do
    migrate conn
    execute_ conn
      "INSERT INTO mosques (id, name, address, lat, lng, timezone) VALUES (1, 'Jama Masjid', 'Delhi', 0, 0, 'Asia/Kolkata')"
    action conn

noon :: UTCTime
noon = UTCTime (fromGregorian 2026 9 30) (12 * 60 * 60)

timesAt :: Int -> PrayerTime
timesAt h = PrayerTime (TimeOfDay h 0 0) (TimeOfDay h 15 0)

main :: IO ()
main = hspec $ do
  describe "migrate" $
    it "runs twice on the same database" $
      withDb ":memory:" $ \conn -> do
        migrate conn
        migrate conn

  describe "prayer" $ do
    it "round-trips through text" $
      map (prayerFromText . prayerToText) [minBound .. maxBound]
        `shouldBe` map Just [minBound .. maxBound :: Prayer]

    it "rejects unknown text" $
      prayerFromText "dhuhr" `shouldBe` Nothing

    it "stores and reads back every prayer, matching the schema's CHECK" $
      withTestDb $ \conn -> do
        forM_ [minBound .. maxBound :: Prayer] $ \p ->
          execute conn
            "INSERT INTO timings (mosque_id, prayer, azan_time, jamaat_time, updated_at) \
            \VALUES (1, ?, '05:00', '05:15', '2026-01-01T00:00:00Z')"
            (Only p)
        rows <- query_ conn "SELECT prayer FROM timings ORDER BY rowid"
        map fromOnly rows `shouldBe` [minBound .. maxBound :: Prayer]

  describe "clock" $ do
    it "round-trips HH:MM" $
      (formatClock <$> parseClock "05:30") `shouldBe` Just "05:30"

    it "zero-pads when formatting" $
      formatClock (TimeOfDay 5 7 0) `shouldBe` "05:07"

    it "rejects an hour past 23" $
      parseClock "25:00" `shouldBe` Nothing

    it "rejects a minute past 59" $
      parseClock "12:60" `shouldBe` Nothing

    it "rejects trailing text" $
      parseClock "05:30pm" `shouldBe` Nothing

  describe "getMosque" $ do
    it "finds an existing mosque" $
      withTestDb $ \conn ->
        getMosque conn (MosqueId 1) `shouldReturn`
          Just (Mosque (MosqueId 1) "Jama Masjid" "Delhi" 0 0 "Asia/Kolkata")

    it "returns Nothing for a missing mosque" $
      withTestDb $ \conn ->
        getMosque conn (MosqueId 99) `shouldReturn` Nothing

  describe "timings" $ do
    it "are empty for a mosque that has entered none" $
      withTestDb $ \conn ->
        getTimings conn (MosqueId 1) `shouldReturn` []

    it "can be saved and read back" $
      withTestDb $ \conn -> do
        saveTiming conn noon (MosqueId 1) Fajr (timesAt 5)
        getTimings conn (MosqueId 1) `shouldReturn` [(Fajr, timesAt 5)]

    it "are replaced when saved twice for the same prayer" $
      withTestDb $ \conn -> do
        saveTiming conn noon (MosqueId 1) Fajr (timesAt 5)
        saveTiming conn noon (MosqueId 1) Fajr (timesAt 6)
        getTimings conn (MosqueId 1) `shouldReturn` [(Fajr, timesAt 6)]

    it "belong only to their own mosque" $
      withTestDb $ \conn -> do
        execute_ conn
          "INSERT INTO mosques (id, name, address, lat, lng, timezone) \
          \VALUES (2, 'Other', 'Elsewhere', 0, 0, 'Asia/Kolkata')"
        saveTiming conn noon (MosqueId 1) Fajr (timesAt 5)
        saveTiming conn noon (MosqueId 2) Asr (timesAt 16)
        getTimings conn (MosqueId 1) `shouldReturn` [(Fajr, timesAt 5)]

    it "can't be saved for a mosque that doesn't exist" $
      withTestDb $ \conn ->
        saveTiming conn noon (MosqueId 99) Fajr (timesAt 5)
          `shouldThrow` anyException

    it "fail loudly if a stored time is malformed" $
      withTestDb $ \conn -> do
        execute_ conn
          "INSERT INTO timings (mosque_id, prayer, azan_time, jamaat_time, updated_at) \
          \VALUES (1, 'fajr', '5:30am', '05:45', '2026-01-01T00:00:00Z')"
        getTimings conn (MosqueId 1) `shouldThrow` anyException

  describe "views" $ do
    let mosque = Mosque (MosqueId 1) "Jama Masjid" "Old Delhi" 0 0 "Asia/Kolkata"

    it "shows the mosque's name" $
      renderText (mosquePage mosque []) `shouldSatisfy` TL.isInfixOf "Jama Masjid"

    it "escapes names, so admins can't inject HTML" $
      renderText (mosquePage mosque { mosqueName = "<b>x</b>" } [])
        `shouldSatisfy` (not . TL.isInfixOf "<b>x</b>")

    it "shows morning times in 12-hour format" $
      (clockDigits (TimeOfDay 5 5 0), clockPeriod (TimeOfDay 5 5 0))
        `shouldBe` ("5:05", "AM")

    it "shows just past midnight as 12, AM" $
      (clockDigits (TimeOfDay 0 15 0), clockPeriod (TimeOfDay 0 15 0))
        `shouldBe` ("12:15", "AM")

    it "shows just past noon as 12, PM" $
      (clockDigits (TimeOfDay 12 30 0), clockPeriod (TimeOfDay 12 30 0))
        `shouldBe` ("12:30", "PM")

  with testApp $ do
    describe "GET /health" $
      it "responds with ok" $
        get "/health" `shouldRespondWith` "ok"

    describe "GET /mosques/:id" $ do
      it "shows an existing mosque" $
        get "/mosques/1" `shouldRespondWith` 200

      it "is 404 for a missing mosque" $
        get "/mosques/99" `shouldRespondWith` 404

      it "is 404 for an id that isn't a number" $
        get "/mosques/abc" `shouldRespondWith` 404

    describe "the stylesheet" $ do
      it "is served at its fingerprinted URL, cached for a year" $
        get (encodeUtf8 stylesheetPath) `shouldRespondWith` 200
          { matchHeaders = ["Cache-Control" <:> "public, max-age=31536000, immutable"] }

      it "is served for any fingerprint, so pages open before a deploy keep working" $
        get "/static/old-hash/app.css" `shouldRespondWith` 200

    describe "unknown URLs" $
      it "are 404" $
        get "/no-such-page" `shouldRespondWith` 404