module Hilal.Location
  ( Place (..)
  , parsePlace
  , placeLink
  , shortLink
  , locatePlace
  , isMosqueName
  , newLinkResolver
  , coordsFromParams
  , distanceMeters
  ) where

import Control.Exception (try)
import Data.Char (isAlphaNum, isHexDigit)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, decodeUtf8With, encodeUtf8)
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
import Network.HTTP.Types.URI (urlDecode, urlEncode)

import Hilal.Types (Coords (..))

-- A place on Google Maps, as its link describes it.
data Place = Place
  { placeId     :: Text   -- Google's id for the place, such as "0x3a28dd…:0x5d2f…"
  , placeName   :: Text   -- as Google Maps names it
  , placeCoords :: Coords -- the place's own pin
  }
  deriving (Show, Eq)

-- The place in what someone pasted: the text Google Maps shares, or a full Google Maps link.
-- A link to a map view or plain coordinates has no place, so it gives nothing.
-- Short links (maps.app.goo.gl) have to be followed first; see `locatePlace`.
parsePlace :: Text -> Maybe Place
parsePlace input = do
  url <- decodeUrl <$> findUrl input
  name <- nameIn url
  pid <- featureId url
  c <- listToMaybe (mapMaybe ($ url) [pinned, viewport])
  return (Place pid name c)

-- A full link to the place, which `parsePlace` reads back without asking Google.
-- The form carries it between its two steps.
placeLink :: Place -> Text
placeLink (Place pid name (Coords lat lng)) =
  "https://www.google.com/maps/place/" <> encode name <> "/data=!1s" <> pid
    <> "!3d" <> T.pack (show lat) <> "!4d" <> T.pack (show lng)
  where
    encode = decodeUtf8 . urlEncode True . encodeUtf8

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

-- Like `parsePlace`, but also follows a short link with the given resolver,
-- which returns where the short link points.
locatePlace :: (Text -> IO (Maybe Text)) -> Text -> IO (Maybe Place)
locatePlace resolve input = case parsePlace input of
  Just p -> return (Just p)
  Nothing -> case shortLink input of
    Just url -> (>>= parsePlace) <$> resolve url
    Nothing  -> return Nothing

-- Whether Google Maps names the place as a mosque, in English or an Indian script.
-- Idgahs, dargahs, madrasas and "palli", which Kerala also uses for churches, are left out on purpose.
isMosqueName :: Text -> Bool
isMosqueName name = any (`T.isInfixOf` T.toLower name) mosqueWords

mosqueWords :: [Text]
mosqueWords =
  [ "masjid", "masjeed", "masjed", "musjid", "mosque"
  , "मस्जिद"        -- Hindi
  , "مسجد"          -- Urdu
  , "মসজিদ"         -- Bengali
  , "మసీదు"          -- Telugu
  , "பள்ளிவாசல்"     -- Tamil
  , "മസ്ജിദ്"        -- Malayalam
  , "ಮಸೀದಿ"          -- Kannada
  , "મસ્જિદ"         -- Gujarati
  ]

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

-- The name in ".../maps/place/Jama Masjid/...".
nameIn :: Text -> Maybe Text
nameIn url = do
  rest <- after "/maps/place/" url
  let name = T.strip (T.takeWhile (/= '/') rest)
  if T.null name then Nothing else Just name

-- Google's id for the place: two hexadecimal numbers, "0x…:0x…".
featureId :: Text -> Maybe Text
featureId url = listToMaybe (mapMaybe (fromMatch . snd) (T.breakOnAll "0x" url))
  where
    fromMatch t = do
      (a, r) <- hex =<< T.stripPrefix "0x" t
      (b, _) <- hex =<< T.stripPrefix ":0x" r
      return (T.toLower ("0x" <> a <> ":0x" <> b))
    hex t = case T.span isHexDigit t of
      (h, r) | not (T.null h) -> Just (h, r)
      _                       -> Nothing

-- The place's own pin, preferred to the map's centre.
pinned :: Text -> Maybe Coords
pinned t = do
  rest <- after "!3d" t
  (la, r) <- number rest
  r' <- T.stripPrefix "!4d" r
  (lo, _) <- number r'
  coords la lo

viewport :: Text -> Maybe Coords
viewport t = fst <$> (pair =<< after "/@" t)

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
