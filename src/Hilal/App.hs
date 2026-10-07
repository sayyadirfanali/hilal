module Hilal.App (Config (..), app) where

import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, when)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Lazy qualified as TL
import Data.Text.Read (decimal)
import Data.Time (LocalTime, UTCTime, addUTCTime, getCurrentTime, localDay)
import Data.Time.Zones (utcToLocalTimeTZ)
import Database.SQLite.Simple (withTransaction)
import Lucid (Html, renderText)
import Network.HTTP.Types.Status (status304, status400, status401, status403, status404, status429, status503)
import Network.Wai (Application)
import Numeric (showHex)
import System.IO (hPutStrLn, stderr)
import Web.Scotty hiding (next)

import Hilal.Assets (fnv1a, interFont, maplibreCss, maplibreJs, urduFont)
import Hilal.Auth
  ( CodeCheck (..)
  , canResend
  , checkCode
  , clearSessionCookie
  , codeLifetime
  , maxCodesPerDay
  , maxWrongCodesPerDay
  , newCode
  , newToken
  , normaliseEmail
  , safeNext
  , sameOrigin
  , sessionCookie
  , sessionLifetime
  , sessionToken
  , sha256
  , windowStart
  )
import Hilal.DB (withDb)
import Hilal.Edit
  ( MosqueForm (..)
  , ValidMosque (..)
  , changedTimings
  , creationLog
  , editLog
  , emptyForm
  , formFromMosque
  , logLine
  , validateForm
  , validateNew
  )
import Hilal.JSON (followedJson, notFoundJson, notSignedInJson, timingsJson)
import Hilal.Location (coordsFromParams, distanceMeters, locate)
import Hilal.Query
  ( clearWrongCodes
  , countSentCodes
  , countWrongCodes
  , createMosque
  , deleteExpired
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
  , recordSentCode
  , recordWrongCode
  , saveSignInCode
  , saveTiming
  , searchMosques
  , unfollowMosque
  , updateMosque
  )
import Hilal.Time (lookupZone, nextJamaat, upcomingToday)
import Hilal.Types (Mosque (..), MosqueId (..), Prayer, PrayerTime, User (..), hasAllTimings, mosqueCoords, prayerToText)
import Hilal.Views
  ( FollowState (..)
  , accountPage
  , codePage
  , homePage
  , mosqueFormPage
  , mosquePage
  , mosqueUrl
  , mosquesPage
  , notFoundPage
  , signInPage
  , signInUrl
  , stylesheet
  )

data Config = Config
  { configDb            :: FilePath
  , configSecureCookies :: Bool
  , configSuperadmin    :: Text
  , configSendCode      :: Text -> Text -> IO ()      -- throws when the code can't be sent
  , configLogEdit       :: Text -> IO ()
  , configDemoCode      :: Maybe Text                -- every sign-in code, for demos; never in production
  , configResolveLink   :: Text -> IO (Maybe Text)   -- where a Google Maps short link points
  }

data SendOutcome = CodeSent | CodeTooSoon | TooManyCodes | TooManyWrongCodes | SendFailed | EmailBlocked

data FollowAction = Follow | Unfollow

app :: Config -> IO Application
app cfg = scottyApp $ do
  get "/health" $
    text "ok"

  get "/static/:hash/app.css" $
    asset "text/css; charset=utf-8" stylesheet

  get "/static/:hash/maplibre-gl.js" $
    asset "text/javascript; charset=utf-8" maplibreJs

  get "/static/:hash/maplibre-gl.css" $
    asset "text/css; charset=utf-8" maplibreCss

  get "/static/:hash/inter.woff2" $
    asset "font/woff2" interFont

  get "/static/:hash/urdu.woff2" $
    asset "font/woff2" urduFont

  get "/" $ do
    user <- currentUser dbPath
    case user of
      Nothing -> redirect "/mosques"
      Just u -> do
        now <- liftIO getCurrentTime
        entries <- liftIO $ withDb dbPath $ \conn -> do
          mosques <- followedMosques conn (userId u)
          forM mosques $ \m -> do
            timings <- getTimings conn (mosqueId m)
            let coming = lookupZone (mosqueTimezone m) >>= \zone -> nextJamaat zone now timings
            return (m, coming)
        page (homePage entries)

  get "/mosques" $ do
    q <- maybe "" T.strip <$> queryParamMaybe "q"
    lat <- queryParamMaybe "lat"
    lng <- queryParamMaybe "lng"
    case coordsFromParams <$> lat <*> lng of
      Just (Just here) -> do
        found <- liftIO $ withDb dbPath $ \conn ->
          searchMosques conn Nothing q
        let nearest = take nearCount (sortOn snd (map (\m -> (m, distanceMeters here (mosqueCoords m))) found))
        page (mosquesPage q (Just here) (map (fmap Just) nearest) False)
      _ | T.null q ->
            page (mosquesPage q Nothing [] False)
        | otherwise -> do
            found <- liftIO $ withDb dbPath $ \conn ->
              searchMosques conn (Just (pageSize + 1)) q
            page (mosquesPage q Nothing (map (\m -> (m, Nothing)) (take pageSize found)) (length found > pageSize))

  get "/mosques/new" $
    requireUser dbPath "/mosques/new" $ \_ ->
      page (mosqueFormPage "Add a mosque" "/mosques/new" [] emptyForm [] True)

  post "/mosques/new" $ sameOriginOnly $
    requireUser dbPath "/mosques/new" $ \user -> do
      form <- readMosqueForm
      location <- liftIO (locate (configResolveLink cfg) (formLocation form))
      case validateNew form location of
        Left errors -> do
          status status400
          page (mosqueFormPage "Add a mosque" "/mosques/new" errors form [] True)
        Right (valid, coords) -> do
          now <- liftIO getCurrentTime
          mid <- liftIO $ withDb dbPath $ \conn -> withTransaction conn $ do
            newId <- createMosque conn (validName valid) (validAddress valid) (validTimezone valid) coords
            forM_ (validTimings valid) $ uncurry (saveTiming conn now newId)
            return newId
          liftIO $ mapM_ (configLogEdit cfg . logLine now (userId user) mid) (creationLog valid coords)
          redirect (TL.fromStrict (mosqueUrl mid))

  get "/mosques/:id" $ do
    found <- loadMosque dbPath =<< pathParam "id"
    case found of
      Nothing -> notFoundResponse
      Just (m, timings, updated) -> do
        now <- liftIO getCurrentTime
        user <- currentUser dbPath
        following <- case user of
          Nothing -> return SignedOut
          Just u -> do
            yes <- liftIO $ withDb dbPath $ \conn -> isFollowing conn (userId u) (mosqueId m)
            return (if yes then Following else NotFollowing)
        let zone        = lookupZone (mosqueTimezone m)
            localNow    = (`utcToLocalTimeTZ` now) <$> zone
            coming      = zone >>= \z -> nextJamaat z now timings
            updatedDay  = localDay <$> (utcToLocalTimeTZ <$> zone <*> updated)
            followState = if hasAllTimings timings then Just following else Nothing
        page (mosquePage m timings localNow coming updatedDay followState)

  post "/mosques/:id/follow" $ sameOriginOnly $
    changeFollow dbPath Follow =<< pathParam "id"

  post "/mosques/:id/unfollow" $ sameOriginOnly $
    changeFollow dbPath Unfollow =<< pathParam "id"

  get "/mosques/:id/edit" $ do
    found <- loadMosque dbPath =<< pathParam "id"
    case found of
      Nothing -> notFoundResponse
      Just (m, timings, _) ->
        requireUser dbPath (editUrl m) $ \_ -> do
          upcoming <- upcomingFor m timings
          page (mosqueFormPage (editTitle m) (editUrl m) [] (formFromMosque m timings) upcoming False)

  post "/mosques/:id/edit" $ sameOriginOnly $ do
    found <- loadMosque dbPath =<< pathParam "id"
    case found of
      Nothing -> notFoundResponse
      Just (m, oldTimings, _) ->
        requireUser dbPath (editUrl m) $ \user -> do
          form <- readMosqueForm
          case validateForm form of
            Left errors -> do
              upcoming <- upcomingFor m oldTimings
              status status400
              page (mosqueFormPage (editTitle m) (editUrl m) errors form upcoming False)
            Right valid -> do
              now <- liftIO getCurrentTime
              let mid = mosqueId m
              liftIO $ withDb dbPath $ \conn -> withTransaction conn $ do
                updateMosque conn mid (validName valid) (validAddress valid) (validTimezone valid)
                forM_ (changedTimings oldTimings (validTimings valid)) $ uncurry (saveTiming conn now mid)
              liftIO $ mapM_ (configLogEdit cfg . logLine now (userId user) mid) (editLog m oldTimings valid)
              redirect (TL.fromStrict (mosqueUrl mid))

  get "/api/v1/mosques/:id/timings" $ do
    found <- loadMosque dbPath =<< pathParam "id"
    case found of
      Just (m, timings, _) | hasAllTimings timings ->
        timingsResponse (timingsJson m timings)
      _ -> apiNotFound

  get "/api/v1/me/mosques" $ do
    user <- currentUser dbPath
    case user of
      Nothing -> do
        status status401
        json notSignedInJson
      Just u -> do
        mosques <- liftIO $ withDb dbPath $ \conn -> followedMosques conn (userId u)
        setHeader "Cache-Control" "private, no-cache"
        json (followedJson mosques)

  get "/sign-in" $ do
    next <- safeNext . fromMaybe "" <$> queryParamMaybe "next"
    page (signInPage "" next Nothing)

  post "/sign-in" $ sameOriginOnly $ do
    input <- textParam "email"
    next  <- safeNext <$> textParam "next"
    case normaliseEmail input of
      Nothing -> do
        status status400
        page (signInPage input next (Just "Please enter a valid email address."))
      Just email -> do
        now <- liftIO getCurrentTime
        outcome <- liftIO $ withDb dbPath $ \conn -> do
          let since = windowStart now
          deleteExpired conn now since
          blocked  <- isBlocked conn email
          wrong    <- countWrongCodes conn since email
          sent     <- countSentCodes conn since email
          existing <- getSignInCode conn email
          let decision
                | blocked                                   = EmailBlocked
                | wrong >= maxWrongCodesPerDay              = TooManyWrongCodes
                | sent >= maxCodesPerDay                    = TooManyCodes
                | not (maybe True (canResend now) existing) = CodeTooSoon
                | otherwise                                 = CodeSent
          case decision of
            CodeSent -> sendNewCode conn now email
            _        -> return decision
        case outcome of
          CodeSent ->
            page (codePage email next Nothing)
          CodeTooSoon ->
            page (codePage email next (Just "We sent you a code less than a minute ago. Check your email, or try again shortly."))
          TooManyCodes -> do
            status status429
            page (codePage email next (Just "We've sent this email too many codes today, so we can't send another until tomorrow. If you have a recent code, enter it here."))
          TooManyWrongCodes -> do
            status status429
            page (signInPage input next (Just tooManyWrongCodes))
          SendFailed -> do
            status status503
            page (signInPage input next (Just "We couldn't send the email. Please try again in a minute."))
          EmailBlocked -> do
            status status403
            page (signInPage input next (Just "This email address can't be used to sign in."))

  post "/sign-in/code" $ sameOriginOnly $ do
    email <- fromMaybe "" . normaliseEmail <$> textParam "email"
    next  <- safeNext <$> textParam "next"
    code  <- T.strip <$> textParam "code"
    now <- liftIO getCurrentTime
    result <- liftIO $ withDb dbPath $ \conn -> do
      wrong  <- countWrongCodes conn (windowStart now) email
      stored <- getSignInCode conn email
      if wrong >= maxWrongCodesPerDay
        then return (Left tooManyWrongCodes)
        else case checkCode now code <$> stored of
          Nothing ->
            return (Left "That code has expired. Please request a new one.")
          Just CodeOk -> do
            deleteSignInCode conn email
            blocked <- isBlocked conn email
            if blocked
              then return (Left "This email address can't be used to sign in.")
              else do
                user <- findOrCreateUser conn now email
                clearWrongCodes conn email
                token <- newToken
                makeSession conn now (addUTCTime sessionLifetime now) (userId user) (sha256 token)
                return (Right token)
          Just CodeWrong -> do
            incrementCodeAttempts conn email
            recordWrongCode conn now email
            return (Left "That code isn't right. Please check it and try again.")
          Just CodeExpired -> do
            deleteSignInCode conn email
            return (Left "That code has expired. Please request a new one.")
          Just CodeLocked -> do
            deleteSignInCode conn email
            return (Left "Too many wrong attempts. Please request a new code.")
    case result of
      Right token -> do
        setCookieHeader (sessionCookie (configSecureCookies cfg) token)
        redirect (TL.fromStrict next)
      Left message ->
        page (codePage email next (Just message))

  post "/sign-out" $ sameOriginOnly $ do
    token <- requestToken
    forM_ token $ \t ->
      liftIO $ withDb dbPath $ \conn -> killSession conn (sha256 t)
    setCookieHeader (clearSessionCookie (configSecureCookies cfg))
    redirect "/mosques"

  get "/account" $
    requireUser dbPath "/account" $ \u ->
      page (accountPage (userEmail u) (userEmail u == configSuperadmin cfg))

  notFound notFoundResponse
  where
    dbPath = configDb cfg

    -- A code that couldn't be sent is forgotten, so asking again needn't wait a minute.
    -- Only the failure is logged: the exception may carry the address and the API key.
    sendNewCode conn now email = do
      code <- maybe newCode return (configDemoCode cfg)
      saveSignInCode conn now (addUTCTime codeLifetime now) email (sha256 code)
      result <- try @SomeException (configSendCode cfg email code)
      case result of
        Right () -> do
          recordSentCode conn now email
          return CodeSent
        Left _ -> do
          deleteSignInCode conn email
          hPutStrLn stderr "A sign-in email could not be sent."
          return SendFailed

tooManyWrongCodes :: Text
tooManyWrongCodes = "Too many wrong codes for this email today. Please try again tomorrow."

changeFollow :: FilePath -> FollowAction -> Text -> ActionM ()
changeFollow dbPath action idText = do
  found <- loadMosque dbPath idText
  case found of
    Nothing -> notFoundResponse
    Just (m, timings, _) -> do
      let url = mosqueUrl (mosqueId m)
      requireUser dbPath url $ \user -> do
        now <- liftIO getCurrentTime
        liftIO $ withDb dbPath $ \conn ->
          case action of
            Follow ->
              when (hasAllTimings timings) $
                followMosque conn now (userId user) (mosqueId m)
            Unfollow ->
              unfollowMosque conn (userId user) (mosqueId m)
        redirect (TL.fromStrict url)

loadMosque :: FilePath -> Text -> ActionM (Maybe (Mosque, [(Prayer, PrayerTime)], Maybe UTCTime))
loadMosque dbPath idText = case parseMosqueId idText of
  Nothing -> return Nothing
  Just mid -> liftIO $ withDb dbPath $ \conn -> do
    mosque <- getMosque conn mid
    case mosque of
      Nothing -> return Nothing
      Just m -> do
        timings <- getTimings conn mid
        updated <- getLastUpdated conn mid
        return (Just (m, timings, updated))

parseMosqueId :: Text -> Maybe MosqueId
parseMosqueId t = case decimal t of
  Right (n, rest) | T.null rest -> Just (MosqueId n)
  _                             -> Nothing

editUrl :: Mosque -> Text
editUrl m = mosqueUrl (mosqueId m) <> "/edit"

editTitle :: Mosque -> Text
editTitle m = "Edit " <> mosqueName m

mosqueLocalNow :: Mosque -> ActionM (Maybe LocalTime)
mosqueLocalNow m = do
  now <- liftIO getCurrentTime
  return ((`utcToLocalTimeTZ` now) <$> lookupZone (mosqueTimezone m))

upcomingFor :: Mosque -> [(Prayer, PrayerTime)] -> ActionM [Prayer]
upcomingFor m timings = maybe [] (`upcomingToday` timings) <$> mosqueLocalNow m

readMosqueForm :: ActionM MosqueForm
readMosqueForm = do
  name     <- textParam "name"
  address  <- textParam "address"
  timezone <- textParam "timezone"
  location <- textParam "location"
  times <- forM [minBound .. maxBound] $ \p -> do
    azan   <- textParam (prayerToText p <> "_azan")
    jamaat <- textParam (prayerToText p <> "_jamaat")
    return (p, (azan, jamaat))
  return (MosqueForm name address timezone location times)

textParam :: Text -> ActionM Text
textParam key = fromMaybe "" <$> formParamMaybe (TL.fromStrict key)

currentUser :: FilePath -> ActionM (Maybe User)
currentUser dbPath = do
  token <- requestToken
  case token of
    Nothing -> return Nothing
    Just t -> liftIO $ do
      now <- getCurrentTime
      withDb dbPath $ \conn -> getSessionUser conn now (sha256 t)

requireUser :: FilePath -> Text -> (User -> ActionM ()) -> ActionM ()
requireUser dbPath here action = do
  user <- currentUser dbPath
  case user of
    Just u  -> action u
    Nothing -> redirect (TL.fromStrict (signInUrl here))

requestToken :: ActionM (Maybe Text)
requestToken = do
  cookies <- header "Cookie"
  return (cookies >>= sessionToken . TE.encodeUtf8 . TL.toStrict)

setCookieHeader :: ByteString -> ActionM ()
setCookieHeader = addHeader "Set-Cookie" . TL.fromStrict . TE.decodeUtf8

sameOriginOnly :: ActionM () -> ActionM ()
sameOriginOnly action = do
  origin <- header "Origin"
  host   <- header "Host"
  if sameOrigin (TL.toStrict <$> origin) (TL.toStrict <$> host)
    then action
    else do
      status status403
      text "Cross-site request rejected"

page :: Html () -> ActionM ()
page h = do
  setHeader "Cache-Control" "no-cache"
  html (renderText h)

notFoundResponse :: ActionM ()
notFoundResponse = do
  status status404
  page notFoundPage

timingsResponse :: BL.ByteString -> ActionM ()
timingsResponse resp = do
  let etag = etagOf resp
  setHeader "ETag" etag
  setHeader "Cache-Control" "no-cache"
  ifNoneMatch <- header "If-None-Match"
  if maybe False (matchesETag etag) ifNoneMatch
    then status status304
    else do
      setHeader "Content-Type" "application/json; charset=utf-8"
      raw resp

etagOf :: BL.ByteString -> TL.Text
etagOf b = "\"" <> TL.pack (showHex (fnv1a (BL.toStrict b)) "") <> "\""

matchesETag :: TL.Text -> TL.Text -> Bool
matchesETag etag ifNoneMatch =
  any (isMatch . TL.strip) (TL.splitOn "," ifNoneMatch)
  where
    isMatch t = t == "*" || t == etag

apiNotFound :: ActionM ()
apiNotFound = do
  status status404
  json notFoundJson

asset :: TL.Text -> ByteString -> ActionM ()
asset contentType contents = do
  setHeader "Content-Type" contentType
  setHeader "Cache-Control" "public, max-age=31536000, immutable"
  raw (BL.fromStrict contents)

pageSize :: Int
pageSize = 50

nearCount :: Int
nearCount = 20
