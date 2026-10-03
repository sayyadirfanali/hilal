module Hilal.App (app) where

import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Text.Read (decimal)
import Lucid (Html, renderText)
import Network.HTTP.Types.Status (status304, status404)
import Network.Wai (Application)
import Numeric (showHex)
import Web.Scotty
import Data.Time (UTCTime, getCurrentTime, localDay)
import Data.Time.Zones (utcToLocalTimeTZ)

import Hilal.Assets (fnv1a)
import Hilal.DB (withDb)
import Hilal.JSON (notFoundJson, timingsJson)
import Hilal.Query (getLastUpdated, getMosque, getTimings, searchMosques)
import Hilal.Time (lookupZone)
import Hilal.Types (Mosque (..), MosqueId (..), Prayer, PrayerTime, hasAllTimings)
import Hilal.Views (mosquePage, mosquesPage, notFoundPage, stylesheet)

app :: FilePath -> IO Application
app dbPath = scottyApp $ do
  get "/health" $
    text "ok"

  get "/static/:hash/app.css" $ do
    setHeader "Content-Type" "text/css; charset=utf-8"
    setHeader "Cache-Control" "public, max-age=31536000, immutable"
    raw (BL.fromStrict stylesheet)

  get "/api/mosques/:id/timings" $ do
    found <- loadMosque dbPath =<< pathParam "id"
    case found of
      Just (m, timings, _) | hasAllTimings timings ->
        timingsResponse (timingsJson m timings)
      _ -> apiNotFound

  get "/" $
    redirect "/mosques"

  get "/mosques" $ do
    q <- maybe "" T.strip <$> queryParamMaybe "q"
    found <- liftIO $ withDb dbPath $ \conn ->
      searchMosques conn (pageSize + 1) q
    page (mosquesPage q (take pageSize found) (length found > pageSize))

  get "/mosques/:id" $ do
    found <- loadMosque dbPath =<< pathParam "id"
    case found of
      Nothing -> notFoundResponse
      Just (m, timings, updated) -> do
        now <- liftIO getCurrentTime
        let zone       = lookupZone (mosqueTimezone m)
            localNow   = (`utcToLocalTimeTZ` now) <$> zone
            updatedDay = localDay <$> (utcToLocalTimeTZ <$> zone <*> updated)
        page (mosquePage m timings localNow updatedDay)

  get "/api/mosques/:id/timings" $ do
    found <- loadMosque dbPath =<< pathParam "id"
    case found of
      Just (m, timings, _) | hasAllTimings timings ->
        timingsResponse (timingsJson m timings)
      _ -> apiNotFound

  notFound notFoundResponse

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

pageSize :: Int
pageSize = 50