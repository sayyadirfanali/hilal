module Hilal.App (app) where

import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read (decimal)
import Lucid (Html, renderText)
import Network.HTTP.Types.Status (status404)
import Network.Wai (Application)
import Web.Scotty

import Hilal.DB (withDb)
import Hilal.Query (getMosque, getTimings)
import Hilal.Types (MosqueId (..))
import Hilal.Views (mosquePage, notFoundPage, stylesheet)

app :: FilePath -> IO Application
app dbPath = scottyApp $ do
  get "/health" $
    text "ok"

  get "/static/:hash/app.css" $ do
    setHeader "Content-Type" "text/css; charset=utf-8"
    setHeader "Cache-Control" "public, max-age=31536000, immutable"
    raw (BL.fromStrict stylesheet)

  get "/mosques/:id" $ do
    idText <- pathParam "id"
    case parseMosqueId idText of
      Nothing -> notFoundResponse
      Just mid -> do
        found <- liftIO $ withDb dbPath $ \conn -> do
          mosque <- getMosque conn mid
          case mosque of
            Nothing -> pure Nothing
            Just m -> do
              timings <- getTimings conn mid
              pure (Just (m, timings))
        case found of
          Nothing -> notFoundResponse
          Just (m, timings) -> page (mosquePage m timings)

  notFound notFoundResponse

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