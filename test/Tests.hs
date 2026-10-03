module Main (main) where

import Control.Monad (filterM, forM_)
import Data.Aeson (decode, object, (.=))
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Text.Lazy qualified as TL
import Data.Time (Day, LocalTime (..))
import Data.Time (TimeOfDay (..), UTCTime (..), fromGregorian)
import Data.Time.Zones (utcToLocalTimeTZ)
import Database.SQLite.Simple (Connection, Only (..), execute, execute_, query_)
import Lucid (renderText)
import Network.Wai (Application)
import System.IO.Temp (emptySystemTempFile)
import Test.Hspec
import Test.Hspec.Wai

import Hilal.App (app)
import Hilal.DB (withDb)
import Hilal.JSON (timingsJson)
import Hilal.Migrate (migrate)
import Hilal.Query (getMosque, getTimings, saveTiming, searchMosques)
import Hilal.Time (lookupZone, nextPrayer)
import Hilal.Types
import Hilal.Views (clockDigits, clockPeriod, mosquePage, mosquesPage, stylesheetPath)
import Data.List (sort)

thursday, friday :: Day
thursday = fromGregorian 2026 10 1
friday   = fromGregorian 2026 10 2

at :: Day -> Int -> Int -> LocalTime
at d h m = LocalTime d (TimeOfDay h m 0)

seed :: Connection -> IO ()
seed conn = do
  migrate conn
  execute_ conn
    "INSERT INTO mosques (id, name, address, lat, lng, timezone) VALUES \
    \  (1, 'Jama Masjid',         'Sector 6, Bhilai',      21.2036,  81.3700, 'Asia/Kolkata'), \
    \  (2, 'Sultan Ahmed Mosque', 'Sultanahmet, Istanbul', 41.0054,  28.9768, 'Europe/Istanbul'), \
    \  (3, 'Istiqlal Mosque',     'Gambir, Jakarta',       -6.1702, 106.8314, 'Asia/Jakarta'), \
    \  (4, 'Badshahi Mosque',     'Walled City, Lahore',   31.5879,  74.3099, 'Asia/Karachi')"
  forM_ allSix $ \(p, t) -> do
    saveTiming conn noon (MosqueId 2) p t
    saveTiming conn noon (MosqueId 3) p t
  forM_ (drop 1 allSix) $ uncurry (saveTiming conn noon (MosqueId 4))

withTestDb :: (Connection -> IO a) -> IO a
withTestDb action =
  withDb ":memory:" $ \conn -> do
    seed conn
    action conn

testApp :: IO Application
testApp = do
  path <- emptySystemTempFile "hilal-test.db"
  withDb path seed
  app path

jamaMasjid :: Mosque
jamaMasjid = Mosque {
  mosqueId = MosqueId 1
, mosqueName = "Jama Masjid"
, mosqueAddress = "Sector 6, Bhilai"
, mosqueLat = 21.2036
, mosqueLng = 81.3700
, mosqueTimezone = "Asia/Kolkata"
}

noon :: UTCTime
noon = UTCTime (fromGregorian 2026 9 30) (12 * 60 * 60)

timesAt :: Int -> PrayerTime
timesAt h = PrayerTime (TimeOfDay h 0 0) (TimeOfDay h 15 0)

allSix :: [(Prayer, PrayerTime)]
allSix = zip [minBound .. maxBound] (map timesAt [5, 13, 16, 18, 20, 13])

main :: IO ()
main = hspec $ do
  describe "prayer" $ do
    it "round-trips through text" $
      map (prayerFromText . prayerToText) [minBound .. maxBound]
        `shouldBe` map Just [minBound .. maxBound :: Prayer]

    it "rejects unknown text" $
      prayerFromText "dhuhr" `shouldBe` Nothing

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

  describe "hasAllTimings" $ do
    it "is true when all six prayers are set" $
      hasAllTimings allSix `shouldBe` True

    it "is false when any prayer is missing" $
      hasAllTimings (drop 1 allSix) `shouldBe` False

  describe "nextPrayer" $ do
    it "is Fajr before dawn" $
      nextPrayer (at thursday 4 0) allSix `shouldBe` Just (thursday, Fajr)

    it "is the first prayer whose Jamaat hasn't passed" $
      nextPrayer (at thursday 14 0) allSix `shouldBe` Just (thursday, Asr)

    it "stays the same through the Jamaat minute" $
      nextPrayer (LocalTime thursday (TimeOfDay 16 15 30)) allSix
        `shouldBe` Just (thursday, Asr)

    it "moves on the minute after Jamaat" $
      nextPrayer (at thursday 16 16) allSix `shouldBe` Just (thursday, Maghrib)

    it "is Jumu'ah, not Zuhr, on Fridays" $
      nextPrayer (at friday 12 0) allSix `shouldBe` Just (friday, Jumuah)

    it "is tomorrow's Fajr after Isha" $
      nextPrayer (at thursday 21 0) allSix `shouldBe` Just (friday, Fajr)

    it "skips prayers without timings" $
      nextPrayer (at thursday 14 0) (filter ((/= Asr) . fst) allSix)
        `shouldBe` Just (thursday, Maghrib)

    it "is nothing when no timings are set" $
      nextPrayer (at thursday 14 0) [] `shouldBe` Nothing

  describe "lookupZone" $ do
    it "finds a known zone" $
      isJust (lookupZone "Asia/Kolkata") `shouldBe` True

    it "rejects an unknown zone" $
      isNothing (lookupZone "Mars/Olympus") `shouldBe` True

    it "converts to local time, including daylight saving" $
      fmap (`utcToLocalTimeTZ` noon) (lookupZone "Europe/London")
        `shouldBe` Just (at (fromGregorian 2026 9 30) 13 0)

  describe "timingsJson" $ do
    it "encodes the agreed shape" $
      decode (timingsJson jamaMasjid [(Fajr, timesAt 5)]) `shouldBe` Just
        (object
          [ "mosque"   .= (1 :: Int)
          , "timezone" .= ("Asia/Kolkata" :: Text)
          , "timings"  .= object
              [ "fajr" .= object
                  [ "azan"   .= ("05:00" :: Text)
                  , "jamaat" .= ("05:15" :: Text)
                  ]
              ]
          ])

    it "changes when a time changes, so the ETag does too" $
      timingsJson jamaMasjid [(Fajr, timesAt 5)]
        `shouldNotBe` timingsJson jamaMasjid [(Fajr, timesAt 6)]

  describe "views" $ do
    it "shows the mosque's name" $
      renderText (mosquePage jamaMasjid []) `shouldSatisfy` TL.isInfixOf "Jama Masjid"

    it "escapes names, so admins can't inject HTML" $
      renderText (mosquePage jamaMasjid { mosqueName = "<b>x</b>" } [])
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

    it "lists mosques by name" $
      renderText (mosquesPage "" [jamaMasjid] False)
        `shouldSatisfy` TL.isInfixOf "Jama Masjid"

    it "escapes the search text" $
      renderText (mosquesPage "<script>" [] False)
        `shouldSatisfy` (not . TL.isInfixOf "<script>")

    it "shows the next prayer" $
      renderText (mosquePage jamaMasjid allSix (Just (at thursday 14 0)) Nothing)
        `shouldSatisfy` TL.isInfixOf "Asr Jamaat"

    it "shows no next prayer when the local time is unknown" $
      renderText (mosquePage jamaMasjid allSix Nothing Nothing)
        `shouldSatisfy` (not . TL.isInfixOf "Next")

  describe "migrate" $
    it "runs twice on the same database" $
      withDb ":memory:" $ \conn -> do
        migrate conn
        migrate conn

  describe "schema" $
    it "stores and reads back every prayer, matching its CHECK" $
      withTestDb $ \conn -> do
        forM_ [minBound .. maxBound :: Prayer] $ \p ->
          execute conn
            "INSERT INTO timings (mosque_id, prayer, azan_time, jamaat_time, updated_at) VALUES (1, ?, '05:00', '05:15', '2026-01-01T00:00:00Z')"
            (Only p)
        rows <- query_ conn "SELECT prayer FROM timings WHERE mosque_id = 1 ORDER BY rowid"
        map fromOnly rows `shouldBe` [minBound .. maxBound :: Prayer]

  describe "getMosque" $ do
    it "finds an existing mosque" $
      withTestDb $ \conn ->
        getMosque conn (MosqueId 1) `shouldReturn` Just jamaMasjid

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
        saveTiming conn noon (MosqueId 1) Fajr (timesAt 5)
        getTimings conn (MosqueId 1) `shouldReturn` [(Fajr, timesAt 5)]

    it "can't be saved for a mosque that doesn't exist" $
      withTestDb $ \conn ->
        saveTiming conn noon (MosqueId 99) Fajr (timesAt 5)
          `shouldThrow` anyException

    it "fail loudly if a stored time is malformed" $
      withTestDb $ \conn -> do
        execute_ conn
          "INSERT INTO timings (mosque_id, prayer, azan_time, jamaat_time, updated_at) VALUES (1, 'fajr', '5:30am', '05:45', '2026-01-01T00:00:00Z')"
        getTimings conn (MosqueId 1) `shouldThrow` anyException

  describe "getLastUpdated" $ do
    it "is the latest change to a mosque's timings" $
      withTestDb $ \conn ->
        getLastUpdated conn (MosqueId 2) `shouldReturn` Just noon

    it "is nothing for a mosque without timings" $
      withTestDb $ \conn ->
        getLastUpdated conn (MosqueId 1) `shouldReturn` Nothing

  describe "searchMosques" $ do
    let names = map mosqueName
    it "lists only mosques with all six timings, by name" $
      withTestDb $ \conn ->
        names <$> searchMosques conn 50 ""
          `shouldReturn` ["Istiqlal Mosque", "Sultan Ahmed Mosque"]

    it "ignores case" $
      withTestDb $ \conn ->
        names <$> searchMosques conn 50 "ISTANBUL" `shouldReturn` ["Sultan Ahmed Mosque"]

    it "matches by name" $
      withTestDb $ \conn ->
        names <$> searchMosques conn 50 "sultan" `shouldReturn` ["Sultan Ahmed Mosque"]

    it "matches by address" $
      withTestDb $ \conn ->
        names <$> searchMosques conn 50 "gamb" `shouldReturn` ["Istiqlal Mosque"]

    it "treats % and _ literally" $
      withTestDb $ \conn -> do
        searchMosques conn 50 "%" `shouldReturn` []
        searchMosques conn 50 "_" `shouldReturn` []

    it "respects the limit" $
      withTestDb $ \conn ->
        length <$> searchMosques conn 1 "" `shouldReturn` 1

    it "agrees with hasAllTimings on which mosques are listed" $
      withTestDb $ \conn -> do
        listed <- map mosqueId <$> searchMosques conn 50 ""
        complete <- filterM (fmap hasAllTimings . getTimings conn) (map MosqueId [1 .. 4])
        sort listed `shouldBe` complete

  with testApp $ do
    describe "GET /" $
      it "redirects to the mosque list" $
        get "/" `shouldRespondWith` 302
          { matchHeaders = ["Location" <:> "/mosques"] }

    describe "GET /health" $
      it "responds with ok" $
        get "/health" `shouldRespondWith` "ok"

    describe "GET /mosques" $ do
      it "lists mosques" $
        get "/mosques" `shouldRespondWith` 200

      it "searches" $
        get "/mosques?q=fateh" `shouldRespondWith` 200

      it "accepts an empty search" $
        get "/mosques?q=" `shouldRespondWith` 200

    describe "GET /mosques/:id" $ do
      it "shows an existing mosque" $
        get "/mosques/1" `shouldRespondWith` 200

      it "is 404 for a missing mosque" $
        get "/mosques/99" `shouldRespondWith` 404

      it "is 404 for an id that isn't a number" $
        get "/mosques/abc" `shouldRespondWith` 404

    describe "GET /api/mosques/:id/timings" $ do
      it "returns JSON for a mosque with all six timings" $
        get "/api/mosques/2/timings" `shouldRespondWith` 200
          { matchHeaders = ["Content-Type" <:> "application/json; charset=utf-8"] }

      it "is 304 when the client already has the current version" $ do
        response <- get "/api/mosques/2/timings"
        case lookup "ETag" (simpleHeaders response) of
          Nothing -> liftIO (expectationFailure "response had no ETag")
          Just etag ->
            request "GET" "/api/mosques/2/timings" [("If-None-Match", etag)] ""
              `shouldRespondWith` 304

      it "is 200 when the client's version is stale" $
        request "GET" "/api/mosques/2/timings" [("If-None-Match", "\"stale\"")] ""
          `shouldRespondWith` 200

      it "is 404 for a mosque without all six timings" $
        get "/api/mosques/4/timings" `shouldRespondWith` 404

      it "is 404 for a missing mosque" $
        get "/api/mosques/99/timings" `shouldRespondWith` 404

      it "is 404 for an id that isn't a number" $
        get "/api/mosques/abc/timings" `shouldRespondWith` 404

    describe "the stylesheet" $ do
      it "is served at its fingerprinted URL, cached for a year" $
        get (encodeUtf8 stylesheetPath) `shouldRespondWith` 200
          { matchHeaders = ["Cache-Control" <:> "public, max-age=31536000, immutable"] }

      it "is served for any fingerprint, so pages open before a deploy keep working" $
        get "/static/old-hash/app.css" `shouldRespondWith` 200

    describe "unknown URLs" $
      it "are 404" $
        get "/no-such-page" `shouldRespondWith` 404