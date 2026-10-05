module Main (main) where

import Control.Monad (filterM, forM_)
import Data.Aeson (decode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Internal (c2w)
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit)
import Data.Either (isLeft)
import Data.IORef (IORef, modifyIORef, newIORef, readIORef)
import Data.List (sort)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.Lazy qualified as TL
import Data.Time (Day, LocalTime (..), TimeOfDay (..), UTCTime (..), addUTCTime, fromGregorian)
import Data.Time.Zones (utcToLocalTimeTZ)
import Database.SQLite.Simple (Connection, Only (..), execute, execute_, query_)
import Lucid (renderText)
import Network.HTTP.Types (Header)
import Network.Wai (Application)
import System.IO.Temp (emptySystemTempFile)
import Test.Hspec
import Test.Hspec.Wai

import Hilal.App (Config (..), app)
import Hilal.Auth (CodeCheck (..), canResend, checkCode, newCode, normaliseEmail, safeNext, sameOrigin, sessionToken, sha256)
import Hilal.DB (withDb)
import Hilal.Edit (MosqueForm (..), ValidMosque (..), changedTimings, editLog, emptyForm, validateForm)
import Hilal.JSON (timingsJson)
import Hilal.Migrate (migrate)
import Hilal.Query
  ( createMosque
  , deleteSignInCode
  , findOrCreateUser
  , followMosque
  , followedMosques
  , getLastUpdated
  , getMosque
  , getSessionUser
  , getSignInCode
  , getTimings
  , incrementCodeAttempts
  , isBlocked
  , isFollowing
  , killSession
  , makeSession
  , saveSignInCode
  , saveTiming
  , searchMosques
  , unfollowMosque
  , updateMosque
  )
import Hilal.Time (lookupZone, nextPrayer, upcomingToday)
import Hilal.Types
import Hilal.Views (FollowState (..), clockDigits, clockPeriod, homePage, mosqueFormPage, mosquePage, mosquesPage, stylesheetPath)

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

testConfig :: FilePath -> Config
testConfig path = Config
  { configDb            = path
  , configSecureCookies = False
  , configSuperadmin    = "admin@example.com"
  , configSendCode      = \_ _ -> return ()
  , configLogEdit       = \_ -> return ()
  }

testApp :: IO Application
testApp = do
  path <- emptySystemTempFile "hilal-test.db"
  withDb path seed
  app (testConfig path)

data TestState = TestState
  { stateCodes :: IORef [(Text, Text)]
  , stateLog   :: IORef [Text]
  }

authApp :: IO (TestState, Application)
authApp = do
  path <- emptySystemTempFile "hilal-test.db"
  withDb path seed
  codes <- newIORef []
  logs  <- newIORef []
  application <- app (testConfig path)
    { configSendCode = \email code -> modifyIORef codes ((email, code) :)
    , configLogEdit  = \line -> modifyIORef logs (line :)
    }
  return (TestState codes logs, application)

postForm :: ByteString -> [Header] -> BL.ByteString -> WaiSession st SResponse
postForm path headers =
  request "POST" path (("Content-Type", "application/x-www-form-urlencoded") : headers)

readCodes :: WaiSession TestState [(Text, Text)]
readCodes = getState >>= liftIO . readIORef . stateCodes

readLog :: WaiSession TestState [Text]
readLog = getState >>= liftIO . readIORef . stateLog

signIn :: WaiSession TestState ByteString
signIn = do
  _ <- postForm "/sign-in" [] "email=reader%40example.com"
  codes <- readCodes
  case lookup "reader@example.com" codes of
    Nothing -> do
      liftIO (expectationFailure "no code was sent")
      return ""
    Just code -> do
      response <- postForm "/sign-in/code" []
        ("email=reader%40example.com&code=" <> BL.fromStrict (encodeUtf8 code))
      return (maybe "" (BS.takeWhile (\c -> c /= c2w ';')) (lookup "Set-Cookie" (simpleHeaders response)))

homeBody :: ByteString -> WaiSession st ByteString
homeBody cookie = do
  response <- request "GET" "/" [("Cookie", cookie)] ""
  return (BL.toStrict (simpleBody response))

newMosqueBody :: BL.ByteString
newMosqueBody =
  "name=Noor+Masjid&address=Supela%2C+Bhilai&timezone=Asia%2FKolkata\
  \&fajr_azan=05:00&fajr_jamaat=05:15&zuhr_azan=13:00&zuhr_jamaat=13:15\
  \&asr_azan=16:30&asr_jamaat=16:45&maghrib_azan=18:00&maghrib_jamaat=18:05\
  \&isha_azan=19:30&isha_jamaat=19:45&jumuah_azan=13:00&jumuah_jamaat=13:30"

editMosqueBody :: BL.ByteString
editMosqueBody =
  "name=Sultan+Ahmed+Mosque&address=Sultanahmet%2C+Istanbul&timezone=Europe%2FIstanbul\
  \&fajr_azan=05:00&fajr_jamaat=05:15&zuhr_azan=13:00&zuhr_jamaat=13:15\
  \&asr_azan=16:00&asr_jamaat=16:30&maghrib_azan=18:00&maghrib_jamaat=18:15\
  \&isha_azan=20:00&isha_jamaat=20:15&jumuah_azan=13:00&jumuah_jamaat=13:15"

jamaMasjid :: Mosque
jamaMasjid = Mosque {
  mosqueId = MosqueId 1
, mosqueName = "Jama Masjid"
, mosqueAddress = "Sector 6, Bhilai"
, mosqueLat = Just 21.2036
, mosqueLng = Just 81.3700
, mosqueTimezone = "Asia/Kolkata"
}

validForm :: MosqueForm
validForm =
  MosqueForm "Noor Masjid" "Supela, Bhilai" "Asia/Kolkata"
    (map (\(p, t) -> (p, (formatClock (ptAzan t), formatClock (ptJamaat t)))) allSix)

setTimes :: Prayer -> (Text, Text) -> MosqueForm -> MosqueForm
setTimes prayer times f =
  f { formTimes = map (\(p, ts) -> if p == prayer then (p, times) else (p, ts)) (formTimes f) }

noon :: UTCTime
noon = UTCTime (fromGregorian 2026 9 30) (12 * 60 * 60)

later :: UTCTime
later = addUTCTime 600 noon

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

  describe "upcomingToday" $ do
    it "lists the prayers still ahead" $
      upcomingToday (at thursday 14 0) allSix `shouldBe` [Asr, Maghrib, Isha]

    it "uses Jumu'ah instead of Zuhr on Fridays" $
      upcomingToday (at friday 12 0) allSix `shouldBe` [Jumuah, Asr, Maghrib, Isha]

  describe "lookupZone" $ do
    it "finds a known zone" $
      isJust (lookupZone "Asia/Kolkata") `shouldBe` True

    it "rejects an unknown zone" $
      isNothing (lookupZone "Mars/Olympus") `shouldBe` True

    it "converts to local time, including daylight saving" $
      fmap (`utcToLocalTimeTZ` noon) (lookupZone "Europe/London")
        `shouldBe` Just (at (fromGregorian 2026 9 30) 13 0)

  describe "validateForm" $ do
    it "accepts a complete form" $
      validateForm validForm
        `shouldBe` Right (ValidMosque "Noor Masjid" "Supela, Bhilai" "Asia/Kolkata" allSix)

    it "requires a name" $
      validateForm validForm { formName = "   " } `shouldSatisfy` isLeft

    it "requires an address" $
      validateForm validForm { formAddress = "" } `shouldSatisfy` isLeft

    it "requires every prayer" $
      validateForm (setTimes Isha ("", "") validForm) `shouldSatisfy` isLeft

    it "rejects a Jamaat earlier than its Azan" $
      validateForm (setTimes Asr ("16:30", "16:00") validForm) `shouldSatisfy` isLeft

    it "rejects an unknown time zone" $
      validateForm validForm { formTimezone = "Asia/Kolkatta" } `shouldSatisfy` isLeft

    it "starts adding with every prayer blank" $
      validateForm emptyForm `shouldSatisfy` isLeft

  describe "changedTimings" $
    it "keeps only prayers whose times differ" $
      changedTimings allSix (map (\(p, t) -> if p == Asr then (p, timesAt 17) else (p, t)) allSix)
        `shouldBe` [(Asr, timesAt 17)]

  describe "editLog" $ do
    let valid = ValidMosque "Jama Masjid" "Sector 6, Bhilai" "Asia/Kolkata" allSix

    it "records nothing when nothing changed" $
      editLog jamaMasjid allSix valid `shouldBe` []

    it "records a changed name, quoted" $
      editLog jamaMasjid allSix valid { validName = "Jama Masjid Bhilai" }
        `shouldBe` ["name: \"Jama Masjid\" -> \"Jama Masjid Bhilai\""]

    it "records a changed timing" $
      editLog jamaMasjid allSix valid { validTimings = map (\(p, t) -> if p == Asr then (p, timesAt 17) else (p, t)) allSix }
        `shouldBe` ["asr: 16:00/16:15 -> 17:00/17:15"]

  describe "checkCode" $ do
    let stored = SignInCode (sha256 "123456") 0 noon later

    it "accepts the right code" $
      checkCode noon "123456" stored `shouldBe` CodeOk

    it "rejects a wrong code" $
      checkCode noon "654321" stored `shouldBe` CodeWrong

    it "rejects an expired code, even if it's right" $
      checkCode later "123456" stored `shouldBe` CodeExpired

    it "locks after five wrong attempts, even for the right code" $
      checkCode noon "123456" stored { codeAttempts = 5 } `shouldBe` CodeLocked

  describe "canResend" $ do
    let stored = SignInCode (sha256 "123456") 0 noon later

    it "refuses within a minute" $
      canResend (addUTCTime 30 noon) stored `shouldBe` False

    it "allows after a minute" $
      canResend (addUTCTime 60 noon) stored `shouldBe` True

  describe "newCode" $
    it "is six digits" $ do
      code <- newCode
      (T.length code, T.all isDigit code) `shouldBe` (6, True)

  describe "normaliseEmail" $ do
    it "trims and lowercases" $
      normaliseEmail "  Reader@Example.COM " `shouldBe` Just "reader@example.com"

    it "rejects text without an @" $
      normaliseEmail "not-an-email" `shouldBe` Nothing

    it "rejects spaces inside" $
      normaliseEmail "a b@example.com" `shouldBe` Nothing

  describe "sessionToken" $ do
    it "reads the session cookie among others" $
      sessionToken "theme=dark; hilal_session=abc123" `shouldBe` Just "abc123"

    it "is nothing without the cookie" $
      sessionToken "theme=dark" `shouldBe` Nothing

  describe "sameOrigin" $ do
    it "allows requests without an Origin" $
      sameOrigin Nothing (Just "localhost:8080") `shouldBe` True

    it "allows a matching Origin" $
      sameOrigin (Just "http://localhost:8080") (Just "localhost:8080") `shouldBe` True

    it "rejects another site" $
      sameOrigin (Just "https://evil.example") (Just "localhost:8080") `shouldBe` False

    it "rejects a null Origin" $
      sameOrigin (Just "null") (Just "localhost:8080") `shouldBe` False

  describe "safeNext" $ do
    it "keeps a path on this site" $
      safeNext "/mosques/2" `shouldBe` "/mosques/2"

    it "rejects another site" $
      safeNext "https://evil.example" `shouldBe` "/mosques"

    it "rejects a protocol-relative address" $
      safeNext "//evil.example" `shouldBe` "/mosques"

    it "falls back when empty" $
      safeNext "" `shouldBe` "/mosques"

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
      renderText (mosquePage jamaMasjid [] Nothing Nothing Nothing) `shouldSatisfy` TL.isInfixOf "Jama Masjid"

    it "escapes names, so admins can't inject HTML" $
      renderText (mosquePage jamaMasjid { mosqueName = "<b>x</b>" } [] Nothing Nothing Nothing)
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
      renderText (mosquePage jamaMasjid allSix (Just (at thursday 14 0)) Nothing Nothing)
        `shouldSatisfy` TL.isInfixOf "Asr Jamaat"

    it "shows no next prayer when the local time is unknown" $
      renderText (mosquePage jamaMasjid allSix Nothing Nothing Nothing)
        `shouldSatisfy` (not . TL.isInfixOf "Next")

    it "escapes values typed into the mosque form" $
      renderText (mosqueFormPage "Add a mosque" "/mosques/new" [] emptyForm { formName = "<b>x</b>" } [] False)
        `shouldSatisfy` (not . TL.isInfixOf "<b>x</b>")

    it "offers to follow a listed mosque" $
      renderText (mosquePage jamaMasjid allSix Nothing Nothing (Just NotFollowing))
        `shouldSatisfy` TL.isInfixOf "/mosques/1/follow"

    it "offers to unfollow a followed mosque" $
      renderText (mosquePage jamaMasjid allSix Nothing Nothing (Just Following))
        `shouldSatisfy` TL.isInfixOf "/mosques/1/unfollow"

    it "sends signed-out visitors to sign in before following" $
      renderText (mosquePage jamaMasjid allSix Nothing Nothing (Just SignedOut))
        `shouldSatisfy` TL.isInfixOf "/sign-in?next=%2Fmosques%2F1"

    it "has no follow button for an unlisted mosque" $
      renderText (mosquePage jamaMasjid [] Nothing Nothing Nothing)
        `shouldSatisfy` (not . TL.isInfixOf "/follow")

    it "invites browsing when nothing is followed" $
      renderText (homePage [])
        `shouldSatisfy` TL.isInfixOf "Browse mosques"

    it "shows each followed mosque's next prayer" $
      renderText (homePage [(jamaMasjid, allSix, Just (at thursday 14 0))])
        `shouldSatisfy` TL.isInfixOf "Asr Jamaat"

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

  describe "createMosque" $
    it "adds a mosque without coordinates" $
      withTestDb $ \conn -> do
        mid <- createMosque conn "Noor Masjid" "Supela, Bhilai" "Asia/Kolkata"
        getMosque conn mid
          `shouldReturn` Just (Mosque mid "Noor Masjid" "Supela, Bhilai" Nothing Nothing "Asia/Kolkata")

  describe "updateMosque" $
    it "changes the details but keeps the coordinates" $
      withTestDb $ \conn -> do
        updateMosque conn (MosqueId 1) "Jama Masjid Bhilai" "Sector 6, Bhilai" "Asia/Kolkata"
        getMosque conn (MosqueId 1)
          `shouldReturn` Just jamaMasjid { mosqueName = "Jama Masjid Bhilai" }

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

  describe "sign-in codes" $ do
    it "can be saved and read back" $
      withTestDb $ \conn -> do
        saveSignInCode conn noon later "reader@example.com" "hash"
        getSignInCode conn "reader@example.com"
          `shouldReturn` Just (SignInCode "hash" 0 noon later)

    it "replace an earlier code and reset its attempts" $
      withTestDb $ \conn -> do
        saveSignInCode conn noon later "reader@example.com" "hash"
        incrementCodeAttempts conn "reader@example.com"
        saveSignInCode conn noon later "reader@example.com" "hash2"
        getSignInCode conn "reader@example.com"
          `shouldReturn` Just (SignInCode "hash2" 0 noon later)

    it "count wrong attempts" $
      withTestDb $ \conn -> do
        saveSignInCode conn noon later "reader@example.com" "hash"
        incrementCodeAttempts conn "reader@example.com"
        fmap codeAttempts <$> getSignInCode conn "reader@example.com"
          `shouldReturn` Just 1

    it "can be deleted" $
      withTestDb $ \conn -> do
        saveSignInCode conn noon later "reader@example.com" "hash"
        deleteSignInCode conn "reader@example.com"
        getSignInCode conn "reader@example.com" `shouldReturn` Nothing

  describe "users" $ do
    it "are created once per email" $
      withTestDb $ \conn -> do
        first  <- findOrCreateUser conn noon "reader@example.com"
        second <- findOrCreateUser conn later "reader@example.com"
        second `shouldBe` first

    it "are not blocked by default" $
      withTestDb $ \conn -> do
        _ <- findOrCreateUser conn noon "reader@example.com"
        isBlocked conn "reader@example.com" `shouldReturn` False

    it "can be blocked" $
      withTestDb $ \conn -> do
        _ <- findOrCreateUser conn noon "reader@example.com"
        execute_ conn "UPDATE users SET blocked = 1 WHERE email = 'reader@example.com'"
        isBlocked conn "reader@example.com" `shouldReturn` True

    it "who don't exist aren't blocked" $
      withTestDb $ \conn ->
        isBlocked conn "nobody@example.com" `shouldReturn` False

  describe "sessions" $ do
    it "identify their user" $
      withTestDb $ \conn -> do
        user <- findOrCreateUser conn noon "reader@example.com"
        makeSession conn noon later (userId user) "token-hash"
        getSessionUser conn noon "token-hash" `shouldReturn` Just user

    it "stop working once expired" $
      withTestDb $ \conn -> do
        user <- findOrCreateUser conn noon "reader@example.com"
        makeSession conn noon later (userId user) "token-hash"
        getSessionUser conn later "token-hash" `shouldReturn` Nothing

    it "stop working once deleted" $
      withTestDb $ \conn -> do
        user <- findOrCreateUser conn noon "reader@example.com"
        makeSession conn noon later (userId user) "token-hash"
        killSession conn "token-hash"
        getSessionUser conn noon "token-hash" `shouldReturn` Nothing

    it "stop working once the user is blocked" $
      withTestDb $ \conn -> do
        user <- findOrCreateUser conn noon "reader@example.com"
        makeSession conn noon later (userId user) "token-hash"
        execute_ conn "UPDATE users SET blocked = 1 WHERE email = 'reader@example.com'"
        getSessionUser conn noon "token-hash" `shouldReturn` Nothing

  describe "follows" $ do
    it "can be added and checked" $
      withTestDb $ \conn -> do
        user <- findOrCreateUser conn noon "reader@example.com"
        followMosque conn noon (userId user) (MosqueId 2)
        isFollowing conn (userId user) (MosqueId 2) `shouldReturn` True

    it "are harmless to repeat" $
      withTestDb $ \conn -> do
        user <- findOrCreateUser conn noon "reader@example.com"
        followMosque conn noon (userId user) (MosqueId 2)
        followMosque conn later (userId user) (MosqueId 2)
        map mosqueId <$> followedMosques conn (userId user) `shouldReturn` [MosqueId 2]

    it "can be removed" $
      withTestDb $ \conn -> do
        user <- findOrCreateUser conn noon "reader@example.com"
        followMosque conn noon (userId user) (MosqueId 2)
        unfollowMosque conn (userId user) (MosqueId 2)
        isFollowing conn (userId user) (MosqueId 2) `shouldReturn` False

    it "list followed mosques by name" $
      withTestDb $ \conn -> do
        user <- findOrCreateUser conn noon "reader@example.com"
        followMosque conn noon (userId user) (MosqueId 2)
        followMosque conn noon (userId user) (MosqueId 3)
        map mosqueName <$> followedMosques conn (userId user)
          `shouldReturn` ["Istiqlal Mosque", "Sultan Ahmed Mosque"]

    it "belong only to their own user" $
      withTestDb $ \conn -> do
        reader <- findOrCreateUser conn noon "reader@example.com"
        other  <- findOrCreateUser conn noon "other@example.com"
        followMosque conn noon (userId reader) (MosqueId 2)
        followedMosques conn (userId other) `shouldReturn` []

  with testApp $ do
    describe "GET /" $
      it "redirects to the mosque list when signed out" $
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

  withState authApp $ do
    describe "sign-in" $ do
      it "shows the email form" $
        get "/sign-in" `shouldRespondWith` 200

      it "sends a code to the normalised email" $ do
        postForm "/sign-in" [] "email=%20Reader%40Example.COM%20" `shouldRespondWith` 200
        codes <- readCodes
        liftIO (map fst codes `shouldBe` ["reader@example.com"])

      it "rejects an invalid email" $
        postForm "/sign-in" [] "email=not-an-email" `shouldRespondWith` 400

      it "doesn't send a second code within a minute" $ do
        postForm "/sign-in" [] "email=reader%40example.com" `shouldRespondWith` 200
        postForm "/sign-in" [] "email=reader%40example.com" `shouldRespondWith` 200
        codes <- readCodes
        liftIO (length codes `shouldBe` 1)

      it "doesn't sign in with a wrong code" $ do
        postForm "/sign-in" [] "email=reader%40example.com" `shouldRespondWith` 200
        postForm "/sign-in/code" [] "email=reader%40example.com&code=wrong"
          `shouldRespondWith` 200

      it "signs in with the right code" $ do
        cookie <- signIn
        liftIO (cookie `shouldSatisfy` BS.isPrefixOf "hilal_session=")

      it "returns to the requested page after signing in" $ do
        _ <- postForm "/sign-in" [] "email=reader%40example.com&next=%2Fmosques%2F2"
        codes <- readCodes
        case lookup "reader@example.com" codes of
          Nothing -> liftIO (expectationFailure "no code was sent")
          Just code ->
            postForm "/sign-in/code" []
              ("email=reader%40example.com&next=%2Fmosques%2F2&code=" <> BL.fromStrict (encodeUtf8 code))
              `shouldRespondWith` 302 { matchHeaders = ["Location" <:> "/mosques/2"] }

      it "rejects posts from another site" $
        postForm "/sign-in" [("Origin", "https://evil.example"), ("Host", "localhost")]
          "email=reader%40example.com"
          `shouldRespondWith` 403

      it "accepts posts from the same site" $
        postForm "/sign-in" [("Origin", "http://localhost"), ("Host", "localhost")]
          "email=reader%40example.com"
          `shouldRespondWith` 200

    describe "the account page" $ do
      it "asks you to sign in first, then returns" $
        get "/account" `shouldRespondWith` 302
          { matchHeaders = ["Location" <:> "/sign-in?next=%2Faccount"] }

      it "is shown when signed in" $ do
        cookie <- signIn
        request "GET" "/account" [("Cookie", cookie)] "" `shouldRespondWith` 200

    describe "sign-out" $
      it "ends the session" $ do
        cookie <- signIn
        postForm "/sign-out" [("Cookie", cookie)] "" `shouldRespondWith` 302
        request "GET" "/account" [("Cookie", cookie)] ""
          `shouldRespondWith` 302 { matchHeaders = ["Location" <:> "/sign-in?next=%2Faccount"] }

    describe "adding a mosque" $ do
      it "asks you to sign in first" $
        get "/mosques/new" `shouldRespondWith` 302
          { matchHeaders = ["Location" <:> "/sign-in?next=%2Fmosques%2Fnew"] }

      it "shows the form when signed in" $ do
        cookie <- signIn
        request "GET" "/mosques/new" [("Cookie", cookie)] "" `shouldRespondWith` 200

      it "creates the mosque and logs it" $ do
        cookie <- signIn
        postForm "/mosques/new" [("Cookie", cookie)] newMosqueBody
          `shouldRespondWith` 302 { matchHeaders = ["Location" <:> "/mosques/5"] }
        logLines <- readLog
        liftIO (logLines `shouldSatisfy` any (T.isInfixOf "created"))

      it "refuses a mosque without all six timings" $ do
        cookie <- signIn
        postForm "/mosques/new" [("Cookie", cookie)] "name=Noor+Masjid&address=Supela&timezone=Asia%2FKolkata"
          `shouldRespondWith` 400

    describe "editing a mosque" $ do
      it "shows the form when signed in" $ do
        cookie <- signIn
        request "GET" "/mosques/2/edit" [("Cookie", cookie)] "" `shouldRespondWith` 200

      it "is 404 for a missing mosque" $
        get "/mosques/99/edit" `shouldRespondWith` 404

      it "saves and logs only what changed" $ do
        cookie <- signIn
        postForm "/mosques/2/edit" [("Cookie", cookie)] editMosqueBody
          `shouldRespondWith` 302 { matchHeaders = ["Location" <:> "/mosques/2"] }
        logLines <- readLog
        liftIO (map (T.isInfixOf "asr: 16:00/16:15 -> 16:00/16:30") logLines `shouldBe` [True])

    describe "following" $ do
      it "asks you to sign in first, then returns to the mosque" $
        postForm "/mosques/2/follow" [] "" `shouldRespondWith` 302
          { matchHeaders = ["Location" <:> "/sign-in?next=%2Fmosques%2F2"] }

      it "shows an empty home page before following anything" $ do
        cookie <- signIn
        home <- homeBody cookie
        liftIO (home `shouldSatisfy` BS.isInfixOf "Browse mosques")

      it "adds the mosque to My mosques" $ do
        cookie <- signIn
        postForm "/mosques/2/follow" [("Cookie", cookie)] ""
          `shouldRespondWith` 302 { matchHeaders = ["Location" <:> "/mosques/2"] }
        home <- homeBody cookie
        liftIO (home `shouldSatisfy` BS.isInfixOf "Sultan Ahmed Mosque")

      it "removes it again when unfollowed" $ do
        cookie <- signIn
        postForm "/mosques/2/follow" [("Cookie", cookie)] "" `shouldRespondWith` 302
        postForm "/mosques/2/unfollow" [("Cookie", cookie)] "" `shouldRespondWith` 302
        home <- homeBody cookie
        liftIO (home `shouldSatisfy` (not . BS.isInfixOf "Sultan Ahmed Mosque"))

      it "ignores mosques without all six timings" $ do
        cookie <- signIn
        postForm "/mosques/4/follow" [("Cookie", cookie)] "" `shouldRespondWith` 302
        home <- homeBody cookie
        liftIO (home `shouldSatisfy` (not . BS.isInfixOf "Badshahi Mosque"))
