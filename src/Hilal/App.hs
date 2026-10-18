module Hilal.App (Config (..), app) where

import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
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
import Database.SQLite.Simple (Connection, withTransaction)
import Lucid (Html, renderText)
import Network.HTTP.Types.Status (status304, status400, status401, status403, status404, status429, status503)
import Network.HTTP.Types.URI (urlEncode)
import Network.Wai (Application)
import Numeric (showHex)
import System.IO (hPutStrLn, stderr)
import Web.Scotty hiding (next)

import Hilal.Assets (fnv1a, interFont, maplibreCss, maplibreJs, urduFont)
import Hilal.Azan (Recording (..), findRecording, mosqueRecordings)
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
  , blockLogLine
  , changedTimings
  , creationLog
  , editLog
  , emptyForm
  , formFromMosque
  , logLine
  , maintainerLog
  , validateForm
  )
import Hilal.JSON (followedJson, notFoundJson, notSignedInJson, timingsJson)
import Hilal.Location (Place (..), coordsFromParams, distanceMeters, isMosqueName, locatePlace, placeLink, placePin)
import Hilal.Query
  ( blockUser
  , clearWrongCodes
  , countSentCodes
  , countWrongCodes
  , createMosque
  , deleteExpired
  , deleteSignInCode
  , deleteUser
  , findOrCreateUser
  , followMosque
  , followedMosques
  , getLastUpdated
  , getMaintainer
  , getMosque
  , getSessionUser
  , getSignInCode
  , getTimings
  , incrementCodeAttempts
  , isBlocked
  , isFollowing
  , killSession
  , maintainedMosques
  , makeSession
  , mosqueByPlace
  , recordSentCode
  , recordWrongCode
  , saveSignInCode
  , saveTiming
  , searchMosques
  , setMaintainer
  , unblockUser
  , unfollowMosque
  , updateMosque
  , userByEmail
  , userById
  )
import Hilal.Time (lookupZone, nextJamaat, upcomingToday)
import Hilal.Types
  ( Coords (..)
  , Mosque (..)
  , MosqueId (..)
  , Prayer
  , PrayerTime
  , User (..)
  , UserId (..)
  , hasAllTimings
  , isDeleted
  , mosqueCoords
  , prayerToText
  )
import Hilal.Views
  ( Editing (..)
  , FollowState (..)
  , accountDeletedPage
  , accountPage
  , addLinkPage
  , codePage
  , deleteAccountPage
  , homePage
  , mosqueFormPage
  , mosquePage
  , mosqueUrl
  , mosquesPage
  , notAllowedPage
  , notFoundPage
  , privacyPage
  , signInPage
  , signInUrl
  , stylesheet
  , usersPage
  )

data Config = Config
  { configDb            :: FilePath
  , configSecureCookies :: Bool
  , configSuperadmin    :: Text
  , configSendCode      :: Text -> Text -> IO ()      -- throws when the code can't be sent
  , configLogEdit       :: Text -> IO ()
  , configDemoCode      :: Maybe Text                -- every sign-in code, for demos; never in production
  , configResolveLink   :: Text -> IO (Maybe Text)   -- where a Google Maps short link points
  , configFindTown      :: Text -> IO (Maybe Coords) -- roughly where a town is, to complete a Plus Code
  , configAzanDir       :: FilePath                  -- the superadmin's Azan recordings
  }

data SendOutcome = CodeSent | CodeTooSoon | TooManyCodes | TooManyWrongCodes | SendFailed | EmailBlocked

data FollowAction = Follow | Unfollow

type LoadedMosque = (Mosque, [(Prayer, PrayerTime)], Maybe UTCTime)

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

  -- Adding has two steps: the Google Maps link, then the rest of the form, with the name
  -- and address taken from the link, and a map to place the pin on.
  -- The link may come in the address, from "Share to Hilal" in the app.
  get "/mosques/new" $ do
    -- Shared text is the name and the link on separate lines; a form field would join them.
    shared <- maybe "" (T.unwords . T.words) <$> queryParamMaybe "location"
    requireUser dbPath (addUrl shared) $ \_ ->
      page (addLinkPage shared [] Nothing)

  post "/mosques/new/link" $ sameOriginOnly $
    requireUser dbPath "/mosques/new" $ \_ -> do
      pasted <- textParam "location"
      checked <- checkPlace dbPath (configResolveLink cfg) pasted
      case checked of
        Left refusal -> do
          status status400
          page refusal
        Right place -> do
          pin <- liftIO (placePin (configFindTown cfg) place)
          page (mosqueFormPage "Add a mosque" "/mosques/new" [] (placeForm place pin emptyForm) [] True)

  -- The link is read and checked again, so the name and location can't be swapped on the way.
  -- Whoever adds the mosque doesn't become its maintainer; the superadmin chooses one.
  post "/mosques/new" $ sameOriginOnly $
    requireUser dbPath "/mosques/new" $ \user -> do
      submitted <- readMosqueForm
      checked <- checkPlace dbPath (configResolveLink cfg) (formLocation submitted)
      case checked of
        Left refusal -> do
          status status400
          page refusal
        Right place -> do
          let form = submitted { formName = placeName place, formLocation = placeLink place }
              pin  = coordsFromParams (formLat form) (formLng form)
          case (validateForm form, pin) of
            (Right valid, Just coords) -> do
              now <- liftIO getCurrentTime
              mid <- liftIO $ withDb dbPath $ \conn -> withTransaction conn $ do
                newId <- createMosque conn (validName valid) (validAddress valid) (validTimezone valid) (placeId place) coords
                forM_ (validTimings valid) $ uncurry (saveTiming conn now newId)
                return newId
              liftIO $ mapM_ (configLogEdit cfg . logLine now (userId user) mid) (creationLog valid place coords)
              redirect (TL.fromStrict (mosqueUrl mid))
            (result, _) -> do
              let pinErrors = maybe ["Please tap the mosque on the map to place its pin."] (const []) pin
              status status400
              page (mosqueFormPage "Add a mosque" "/mosques/new" (either id (const []) result <> pinErrors) form [] True)

  get "/mosques/:id" $ do
    found <- loadMosque dbPath =<< pathParam "id"
    case found of
      Nothing -> notFoundResponse
      Just loaded -> do
        user <- currentUser dbPath
        showMosque cfg loaded user []

  post "/mosques/:id/follow" $ sameOriginOnly $
    changeFollow dbPath Follow =<< pathParam "id"

  post "/mosques/:id/unfollow" $ sameOriginOnly $
    changeFollow dbPath Unfollow =<< pathParam "id"

  get "/mosques/:id/edit" $ do
    found <- loadMosque dbPath =<< pathParam "id"
    case found of
      Nothing -> notFoundResponse
      Just (m, timings, _) ->
        requireEditor cfg m $ \_ -> do
          upcoming <- upcomingFor m timings
          page (mosqueFormPage (editTitle m) (editUrl m) [] (formFromMosque m timings) upcoming False)

  post "/mosques/:id/edit" $ sameOriginOnly $ do
    found <- loadMosque dbPath =<< pathParam "id"
    case found of
      Nothing -> notFoundResponse
      Just (m, oldTimings, _) ->
        requireEditor cfg m $ \user -> do
          -- The name stays as Google Maps had it when the mosque was added.
          form <- (\f -> f { formName = mosqueName m }) <$> readMosqueForm
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

  -- Only the superadmin chooses a mosque's maintainer, who must have signed in at least once.
  post "/mosques/:id/maintainer" $ sameOriginOnly $ do
    found <- loadMosque dbPath =<< pathParam "id"
    case found of
      Nothing -> notFoundResponse
      Just loaded@(m, _, _) ->
        requireSuperadmin cfg (mosqueUrl (mosqueId m)) $ \admin -> do
          input <- textParam "email"
          result <- liftIO $ withDb dbPath $ \conn ->
            case normaliseEmail input of
              Nothing -> return (Left "Please enter a valid email address.")
              Just email -> do
                account <- userByEmail conn email
                case account of
                  Nothing ->
                    return (Left "No one has signed in to Hilal with that email yet. Ask them to sign in once, then try again.")
                  Just (u, blocked)
                    | blocked                         -> return (Left "That account is blocked.")
                    | email == configSuperadmin cfg -> return (Left "You can already edit every mosque.")
                    | otherwise -> do
                        old <- getMaintainer conn (mosqueId m)
                        setMaintainer conn (mosqueId m) (Just (userId u))
                        return (Right (userId <$> old, userId u))
          case result of
            Left problem ->
              showMosque cfg loaded (Just admin) [problem]
            Right (old, new) -> do
              now <- liftIO getCurrentTime
              liftIO $ configLogEdit cfg (logLine now (userId admin) (mosqueId m) (maintainerLog old (Just new)))
              redirect (TL.fromStrict (mosqueUrl (mosqueId m)))

  post "/mosques/:id/maintainer/remove" $ sameOriginOnly $ do
    found <- loadMosque dbPath =<< pathParam "id"
    case found of
      Nothing -> notFoundResponse
      Just (m, _, _) -> do
        let mid = mosqueId m
        requireSuperadmin cfg (mosqueUrl mid) $ \admin -> do
          old <- liftIO $ withDb dbPath $ \conn -> do
            old <- getMaintainer conn mid
            setMaintainer conn mid Nothing
            return old
          forM_ old $ \u -> do
            now <- liftIO getCurrentTime
            liftIO $ configLogEdit cfg (logLine now (userId admin) mid (maintainerLog (Just (userId u)) Nothing))
          redirect (TL.fromStrict (mosqueUrl mid))

  get "/api/v1/mosques/:id/timings" $ do
    found <- loadMosque dbPath =<< pathParam "id"
    case found of
      Just (m, timings, _) | hasAllTimings timings -> do
        recordings <- liftIO (mosqueRecordings (configAzanDir cfg) (mosqueId m))
        etagResponse "application/json; charset=utf-8" (timingsJson m recordings timings)
      _ -> apiNotFound

  -- A mosque's own Azan recordings, which the app downloads when it syncs and plays offline.
  get "/mosques/:id/azan" $
    recordingResponse (configAzanDir cfg) Azan =<< pathParam "id"

  get "/mosques/:id/azan-fajr" $
    recordingResponse (configAzanDir cfg) FajrAzan =<< pathParam "id"

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
    requireUser dbPath "/account" $ \u -> do
      maintained <- liftIO $ withDb dbPath $ \conn -> maintainedMosques conn (userId u)
      page (accountPage (userEmail u) (isSuperadmin cfg u) maintained)

  get "/account/delete" $
    requireUser dbPath "/account/delete" $ \u ->
      page (deleteAccountPage (userEmail u))

  -- The phone notices at its next sync, which then finds itself signed out and clears its alarms.
  post "/account/delete" $ sameOriginOnly $
    requireUser dbPath "/account/delete" $ \u -> do
      liftIO $ withDb dbPath $ \conn -> deleteUser conn (userId u) (userEmail u)
      setCookieHeader (clearSessionCookie (configSecureCookies cfg))
      page accountDeletedPage

  -- The superadmin finds an account by email, or by the number edits.log gives it.
  get "/admin/users" $
    requireSuperadmin cfg "/admin/users" $ \_ -> do
      q <- maybe "" T.strip <$> queryParamMaybe "q"
      found <- liftIO $ withDb dbPath $ \conn -> findAccount conn q
      page (usersPage (configSuperadmin cfg) q found)

  post "/admin/users/:id/block" $ sameOriginOnly $
    changeBlock cfg True =<< pathParam "id"

  post "/admin/users/:id/unblock" $ sameOriginOnly $
    changeBlock cfg False =<< pathParam "id"

  get "/privacy" $
    page privacyPage

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

-- A link to a place Google Maps names as a mosque, which isn't on Hilal yet;
-- otherwise the first step's page, saying why not.
checkPlace :: FilePath -> (Text -> IO (Maybe Text)) -> Text -> ActionM (Either (Html ()) Place)
checkPlace dbPath resolve pasted = do
  found <- liftIO (locatePlace resolve pasted)
  case found of
    Nothing ->
      return (Left (addLinkPage pasted [noPlace] Nothing))
    Just place
      | not (isMosqueName (placeName place)) ->
          return (Left (addLinkPage pasted [notMosque] Nothing))
      | otherwise -> do
          existing <- liftIO $ withDb dbPath $ \conn -> mosqueByPlace conn (placeId place)
          return $ case existing of
            Just mid -> Left (addLinkPage pasted [] (Just mid))
            Nothing  -> Right place
  where
    noPlace =
      "We couldn't find a place in that link. In Google Maps, open the mosque itself, tap Share, and paste that link."
    notMosque =
      "Hilal only adds places that Google Maps names as a mosque. If this is a mosque, suggest an edit to its name on Google Maps so it includes \"Masjid\", then add it again."

-- The second step's form, filled in from the link: the name, the address,
-- and the place's location when Hilal could work it out; otherwise it is placed on a map.
placeForm :: Place -> Maybe Coords -> MosqueForm -> MosqueForm
placeForm place pin f =
  f { formName     = placeName place
    , formAddress  = placeAddress place
    , formLocation = placeLink place
    , formLat      = maybe "" (\(Coords lat _) -> T.pack (show lat)) pin
    , formLng      = maybe "" (\(Coords _ lng) -> T.pack (show lng)) pin
    }

-- The first step's address, carrying a shared link through signing in.
addUrl :: Text -> Text
addUrl shared
  | T.null shared = "/mosques/new"
  | otherwise     = "/mosques/new?location=" <> TE.decodeUtf8 (urlEncode True (TE.encodeUtf8 shared))

-- The mosque's page, for whoever is looking; problems are from the superadmin choosing a maintainer.
showMosque :: Config -> LoadedMosque -> Maybe User -> [Text] -> ActionM ()
showMosque cfg (m, timings, updated) user problems = do
  now <- liftIO getCurrentTime
  (following, maintainer) <- liftIO $ withDb (configDb cfg) $ \conn -> do
    maintainer <- getMaintainer conn (mosqueId m)
    following <- case user of
      Nothing -> return SignedOut
      Just u -> do
        yes <- isFollowing conn (userId u) (mosqueId m)
        return (if yes then Following else NotFollowing)
    return (following, maintainer)
  let zone        = lookupZone (mosqueTimezone m)
      localNow    = (`utcToLocalTimeTZ` now) <$> zone
      coming      = zone >>= \z -> nextJamaat z now timings
      updatedDay  = localDay <$> (utcToLocalTimeTZ <$> zone <*> updated)
      followState = if hasAllTimings timings then Just following else Nothing
  unless (null problems) $
    status status400
  page (mosquePage m timings localNow coming updatedDay followState (editingFor cfg user maintainer problems))

editingFor :: Config -> Maybe User -> Maybe User -> [Text] -> Editing
editingFor cfg viewer maintainer problems = case viewer of
  Just v
    | isSuperadmin cfg v                         -> Superadmin (userEmail <$> maintainer) problems
    | (userId <$> maintainer) == Just (userId v) -> Maintainer
  _ -> Reporter (configSuperadmin cfg)

isSuperadmin :: Config -> User -> Bool
isSuperadmin cfg u = userEmail u == configSuperadmin cfg

-- Only the superadmin and the mosque's maintainer may edit it.
mayEdit :: Config -> User -> MosqueId -> IO Bool
mayEdit cfg u mid
  | isSuperadmin cfg u = return True
  | otherwise = do
      maintainer <- withDb (configDb cfg) $ \conn -> getMaintainer conn mid
      return ((userId <$> maintainer) == Just (userId u))

requireEditor :: Config -> Mosque -> (User -> ActionM ()) -> ActionM ()
requireEditor cfg m action =
  requireUser (configDb cfg) (editUrl m) $ \u -> do
    allowed <- liftIO (mayEdit cfg u (mosqueId m))
    if allowed
      then action u
      else do
        status status403
        page (notAllowedPage m)

-- Everyone else is told there's nothing here, as for any unknown address.
requireSuperadmin :: Config -> Text -> (User -> ActionM ()) -> ActionM ()
requireSuperadmin cfg here action =
  requireUser (configDb cfg) here $ \u ->
    if isSuperadmin cfg u then action u else notFoundResponse

-- An account by its number, or else by its email, with whether it's blocked and the mosques it maintains.
findAccount :: Connection -> Text -> IO (Maybe (User, Bool, [Mosque]))
findAccount conn q = do
  account <- case decimal q of
    Right (n, rest) | T.null rest -> userById conn (UserId n)
    _                             -> maybe (return Nothing) (userByEmail conn) (normaliseEmail q)
  case account of
    Nothing -> return Nothing
    Just (u, blocked) -> do
      maintained <- maintainedMosques conn (userId u)
      return (Just (u, blocked, maintained))

-- Blocking or unblocking, then back to the account; the superadmin's own account
-- and deleted ones are left as they are, and nothing is logged for them.
changeBlock :: Config -> Bool -> Text -> ActionM ()
changeBlock cfg block idText =
  requireSuperadmin cfg "/admin/users" $ \admin ->
    case decimal idText of
      Right (n, rest) | T.null rest -> do
        let uid = UserId n
        account <- liftIO $ withDb (configDb cfg) $ \conn -> userById conn uid
        case account of
          Just (u, blocked)
            | not (isSuperadmin cfg u), not (isDeleted u), blocked /= block -> do
                now <- liftIO getCurrentTime
                liftIO $ withDb (configDb cfg) $ \conn ->
                  if block then blockUser conn uid else unblockUser conn uid
                liftIO $ configLogEdit cfg (blockLogLine now (userId admin) uid block)
          _ -> return ()
        redirect (TL.fromStrict ("/admin/users?q=" <> T.pack (show n)))
      _ -> notFoundResponse

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

loadMosque :: FilePath -> Text -> ActionM (Maybe LoadedMosque)
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
  lat      <- textParam "lat"
  lng      <- textParam "lng"
  times <- forM [minBound .. maxBound] $ \p -> do
    azan   <- textParam (prayerToText p <> "_azan")
    jamaat <- textParam (prayerToText p <> "_jamaat")
    return (p, (azan, jamaat))
  return (MosqueForm name address timezone location lat lng times)

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

-- Sent with an ETag, so the app always revalidates and an unchanged response costs a tiny 304.
etagResponse :: TL.Text -> BL.ByteString -> ActionM ()
etagResponse contentType resp = do
  let etag = etagOf resp
  setHeader "ETag" etag
  setHeader "Cache-Control" "no-cache"
  ifNoneMatch <- header "If-None-Match"
  if maybe False (matchesETag etag) ifNoneMatch
    then status status304
    else do
      setHeader "Content-Type" contentType
      raw resp

recordingResponse :: FilePath -> Recording -> Text -> ActionM ()
recordingResponse dir recording idText = do
  found <- case parseMosqueId idText of
    Nothing  -> return Nothing
    Just mid -> liftIO (findRecording dir mid recording)
  case found of
    Nothing -> do
      status status404
      text "No recording"
    Just (path, contentType) -> do
      contents <- liftIO (BS.readFile path)
      etagResponse (TL.fromStrict contentType) (BL.fromStrict contents)

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
