module Hilal.Location
  ( parseLocation
  , shortLink
  , locate
  , newLinkResolver
  , coordsFromParams
  , distanceMeters
  ) where

import Control.Exception (try)
import Data.Char (isAlphaNum)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Text.Read (rational)
import Network.HTTP.Client
  ( HttpException
  , Manager
  , httpNoBody
  , parseRequest
  , redirectCount
  , responseHeaders
  , responseTimeout
  , responseTimeoutMicro
  )
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.URI (urlDecode)

import Hilal.Types (Coords (..))

-- Coordinates from what someone pasted: the text Google Maps shares,
-- a full Google Maps link, or plain "21.2036, 81.3700".
-- Short links (maps.app.goo.gl) carry no coordinates; see `locate`.
parseLocation :: Text -> Maybe Coords
parseLocation input = case findUrl input of
  Just url -> fromUrl (decodeUrl url)
  Nothing -> case pair (T.strip input) of
    Just (c, rest) | T.null (T.strip rest) -> Just c
    _                                      -> Nothing

-- The https form of a Google Maps short link in the pasted text, if there is one.
shortLink :: Text -> Maybe Text
shortLink input = do
  url <- findUrl input
  rest <- listToMaybe (mapMaybe (`T.stripPrefix` url) ["https://maps.app.goo.gl/", "http://maps.app.goo.gl/"])
  if T.null rest || not (T.all safe rest)
    then Nothing
    else Just ("https://maps.app.goo.gl/" <> rest)
  where
    safe c = isAlphaNum c || c `elem` ("-_/?=&." :: String)

-- Like `parseLocation`, but also follows a short link with the given resolver,
-- which returns where the short link points.
locate :: (Text -> IO (Maybe Text)) -> Text -> IO (Maybe Coords)
locate resolve input = case parseLocation input of
  Just c -> return (Just c)
  Nothing -> case shortLink input of
    Just url -> (>>= parseLocation) <$> resolve url
    Nothing  -> return Nothing

-- A resolver that asks Google where a short link points, without following it further.
-- Only called with links that `shortLink` produced, so it only ever contacts maps.app.goo.gl.
newLinkResolver :: IO (Text -> IO (Maybe Text))
newLinkResolver = resolveWith <$> newTlsManager

resolveWith :: Manager -> Text -> IO (Maybe Text)
resolveWith manager url = do
  result <- try @HttpException $ do
    request <- parseRequest (T.unpack url)
    response <- httpNoBody
      request { redirectCount = 0, responseTimeout = responseTimeoutMicro 5000000 }
      manager
    return (lookup "Location" (responseHeaders response))
  return $ case result of
    Right (Just location) -> Just (decodeUtf8With lenientDecode location)
    _                     -> Nothing

-- The "lat" and "lng" query parameters of the mosque list.
coordsFromParams :: Text -> Text -> Maybe Coords
coordsFromParams latText lngText =
  case (rational (T.strip latText), rational (T.strip lngText)) of
    (Right (la, ""), Right (lo, "")) -> coords la lo
    _                                -> Nothing

-- Great-circle distance, accurate to well under 1% at these scales.
distanceMeters :: Coords -> Coords -> Double
distanceMeters (Coords lat1 lng1) (Coords lat2 lng2) =
  2 * earthRadius * asin (sqrt a)
  where
    earthRadius = 6371000
    rad d = d * pi / 180
    dLat = rad (lat2 - lat1)
    dLng = rad (lng2 - lng1)
    a = sin (dLat / 2) ^ (2 :: Int)
      + cos (rad lat1) * cos (rad lat2) * sin (dLng / 2) ^ (2 :: Int)

findUrl :: Text -> Maybe Text
findUrl = listToMaybe . filter isUrl . T.words
  where
    isUrl w = "https://" `T.isPrefixOf` w || "http://" `T.isPrefixOf` w

-- Decoding the whole link also unwraps links nested inside others, such as Google's consent page.
decodeUrl :: Text -> Text
decodeUrl = decodeUtf8With lenientDecode . urlDecode True . encodeUtf8

-- In order of preference: the place's own pin, the map's centre, a query.
fromUrl :: Text -> Maybe Coords
fromUrl url = listToMaybe (mapMaybe ($ url) [pinned, viewport, queried])
  where
    pinned t = do
      rest <- after "!3d" t
      (la, r) <- number rest
      r' <- T.stripPrefix "!4d" r
      (lo, _) <- number r'
      coords la lo
    viewport t = fst <$> (pair =<< after "/@" t)
    queried t =
      listToMaybe (mapMaybe (\key -> fst <$> (pair =<< after key t)) ["q=", "query=", "ll=", "center=", "destination="])

after :: Text -> Text -> Maybe Text
after key t = case T.breakOn key t of
  (_, rest) | not (T.null rest) -> Just (T.drop (T.length key) rest)
  _                             -> Nothing

pair :: Text -> Maybe (Coords, Text)
pair t = do
  (la, r) <- number t
  r' <- T.stripPrefix "," (T.stripStart r)
  (lo, rest) <- number r'
  c <- coords la lo
  return (c, rest)

number :: Text -> Maybe (Double, Text)
number t = either (const Nothing) Just (rational (T.stripStart t))

coords :: Double -> Double -> Maybe Coords
coords la lo
  | abs la <= 90 && abs lo <= 180 = Just (Coords la lo)
  | otherwise                     = Nothing
