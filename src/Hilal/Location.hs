module Hilal.Location
  ( Place (..)
  , parsePlace
  , placeLink
  , shortLink
  , locatePlace
  , isMosqueName
  , placePin
  , townQueries
  , recoverPlusCode
  , newLinkResolver
  , newTownFinder
  , coordsFromParams
  , distanceMeters
  ) where

import Control.Exception (try)
import Control.Monad (guard)
import Data.Aeson (Object, decode, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.Char (isAlphaNum, isHexDigit)
import Data.List (elemIndex, tails)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Text.Read (rational)
import Network.HTTP.Client
  ( HttpException
  , Manager
  , httpLbs
  , httpNoBody
  , parseRequest
  , redirectCount
  , requestHeaders
  , responseBody
  , responseHeaders
  , responseTimeout
  , responseTimeoutMicro
  , setQueryString
  )
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.URI (urlDecode, urlEncode)

import Hilal.Types (Coords (..))

-- A place on Google Maps, as its link describes it.
-- Links shared from the Google Maps app carry no coordinates, but a shortened Plus Code,
-- which gives them once completed with any point within about 50 km; see `placePin`.
data Place = Place
  { placeId       :: Text         -- Google's id for the place, such as "0x3a28dd…:0x5d2f…"
  , placeName     :: Text         -- as Google Maps names it
  , placeAddress  :: Text         -- what follows the name in the link, if anything
  , placePlusCode :: Maybe Text   -- the Plus Code before the name, such as "6922+H4H"
  , placeCoords   :: Maybe Coords -- the place's own pin in the link, if it has one
  }
  deriving (Show, Eq)

-- The place in what someone pasted: the text Google Maps shares, or a full Google Maps link.
-- A link to a map view or plain coordinates has no place, so it gives nothing.
-- Short links (maps.app.goo.gl) have to be followed first; see `locatePlace`.
parsePlace :: Text -> Maybe Place
parsePlace input = do
  url <- decodeUrl <$> findUrl input
  (code, name, address) <- labelIn url
  pid <- featureId url
  return (Place pid name address code (pinned url))

-- A link to the place, with just its name and Google's id, which `parsePlace` reads back
-- without asking Google. The form carries it between its two steps.
placeLink :: Place -> Text
placeLink p =
  "https://www.google.com/maps/place/" <> encode (placeName p) <> "/data=!1s" <> placeId p
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

-- The Plus Code, name and address in ".../maps/place/6922+H4H Jama Masjid, Sector 6, Bhilai/...":
-- an optional Plus Code, the name, then the address after the first comma.
labelIn :: Text -> Maybe (Maybe Text, Text, Text)
labelIn url = do
  rest <- after "/maps/place/" url
  let label = T.takeWhile (/= '/') rest
      (front, back) = T.breakOn "," label
      (code, nameWords) = case T.words front of
        w : ws | isPlusCode w -> (Just w, ws)
        ws                    -> (Nothing, ws)
      name = T.strip (T.unwords nameWords)
  if T.null name then Nothing else Just (code, name, T.strip (T.drop 1 back))

-- A Plus Code such as "6922+H4H", which Google puts before the name of places shared from its app.
isPlusCode :: Text -> Bool
isPlusCode w = T.length w >= 6 && "+" `T.isInfixOf` w && T.all (`elem` ('+' : plusCodeDigits)) w

plusCodeDigits :: String
plusCodeDigits = "23456789CFGHJMPQRVWX"

-- Where the place is: its own pin in the link, or else its Plus Code completed with its town,
-- found with the given lookup from the address in the link. Nothing if neither works.
placePin :: (Text -> IO (Maybe Coords)) -> Place -> IO (Maybe Coords)
placePin findTown p = case (placeCoords p, placePlusCode p) of
  (Just c, _)          -> return (Just c)
  (Nothing, Just code) -> tryTowns code (townQueries (placeAddress p))
  _                    -> return Nothing
  where
    tryTowns _ [] = return Nothing
    tryTowns code (q : qs) = do
      town <- findTown q
      case town >>= (`recoverPlusCode` code) of
        Just c  -> return (Just c)
        Nothing -> tryTowns code qs

-- The address to look up, from most to least precise, but always with at least the town and state:
-- "Sector 6, Bhilai, Chhattisgarh 490006", then "Bhilai, Chhattisgarh 490006".
-- A state alone could be too far away to complete a Plus Code correctly.
townQueries :: Text -> [Text]
townQueries address =
  map (T.intercalate ", ") (filter ((>= 2) . length) (take 3 (tails parts)))
  where
    parts = filter (not . T.null) (map T.strip (T.splitOn "," address))

-- The centre of a Plus Code, completing a shortened one, such as "6922+H4H",
-- with any point within about 50 km, as the Open Location Code standard does.
recoverPlusCode :: Coords -> Text -> Maybe Coords
recoverPlusCode (Coords refLat refLng) input = do
  let code = T.toUpper (T.strip input)
      (front, back) = T.breakOn "+" code
      padding = 8 - T.length front
  guard (not (T.null back) && even padding && padding >= 0 && padding <= 6)
  (lat, lng) <- decodePlusCode (prefix padding <> T.filter (/= '+') code)
  let size = 20 ** (2 - fromIntegral (padding `div` 2)) :: Double
      nearer ref c
        | ref + size / 2 < c = c - size
        | ref - size / 2 > c = c + size
        | otherwise          = c
  coords (nearer refLat lat) (nearer refLng lng)
  where
    -- The leading digits of the reference point's own code, which a shortened code leaves out.
    prefix n = T.pack (take n (concatMap pairAt [0, 1, 2]))
    pairAt :: Int -> String
    pairAt i =
      let size = 20 ** (1 - fromIntegral i) :: Double
      in [digit ((refLat + 90) / size), digit ((refLng + 180) / size)]
    digit x = plusCodeDigits !! (floor x `mod` 20)

-- The centre of a full Plus Code, without its "+": pairs of digits, then perhaps a grid digit.
decodePlusCode :: Text -> Maybe (Double, Double)
decodePlusCode code = do
  digits <- mapM (`elemIndex` plusCodeDigits) (T.unpack code)
  let (pairs, grid) = splitAt 10 digits
  guard (length pairs >= 8 && even (length pairs))
  let (lat, lng, size) = walk (-90) (-180) 400 pairs
  return $ case grid of
    g : _ ->
      let h = size / 5
          w = size / 4
      in (lat + fromIntegral (g `div` 4) * h + h / 2, lng + fromIntegral (g `mod` 4) * w + w / 2)
    [] -> (lat + size / 2, lng + size / 2)
  where
    walk la lo size (a : b : rest) =
      let s = size / 20
      in walk (la + fromIntegral a * s) (lo + fromIntegral b * s) s rest
    walk la lo size _ = (la, lo, size)

-- Where a town is, from OpenStreetMap's free address search, Nominatim, which needs no key.
-- Only the town from a Google Maps link is ever looked up, never anything about a person.
newTownFinder :: IO (Text -> IO (Maybe Coords))
newTownFinder = findTownWith <$> newTlsManager

findTownWith :: Manager -> Text -> IO (Maybe Coords)
findTownWith manager place = do
  result <- try @HttpException $ do
    request <- parseRequest "https://nominatim.openstreetmap.org/search"
    response <- httpLbs
      (setQueryString [("q", Just (encodeUtf8 place)), ("format", Just "jsonv2"), ("limit", Just "1")] request)
        { requestHeaders = [("User-Agent", "Hilal (https://hilal.irfanali.org)")]
        , responseTimeout = responseTimeoutMicro 5000000
        }
      manager
    return (responseBody response)
  return $ case result of
    Right body -> firstPlace =<< decode body
    Left _     -> Nothing
  where
    firstPlace :: [Object] -> Maybe Coords
    firstPlace (o : _) = do
      la <- decimalText =<< parseMaybe (.: "lat") o
      lo <- decimalText =<< parseMaybe (.: "lon") o
      coords la lo
    firstPlace [] = Nothing
    decimalText t = case rational t of
      Right (x, "") -> Just x
      _             -> Nothing

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

-- The place's own pin; the map's centre, also in some links, may be anywhere nearby.
pinned :: Text -> Maybe Coords
pinned t = do
  rest <- after "!3d" t
  (la, r) <- number rest
  r' <- T.stripPrefix "!4d" r
  (lo, _) <- number r'
  coords la lo

after :: Text -> Text -> Maybe Text
after key t = case T.breakOn key t of
  (_, rest) | not (T.null rest) -> Just (T.drop (T.length key) rest)
  _                             -> Nothing

number :: Text -> Maybe (Double, Text)
number t = either (const Nothing) Just (rational (T.stripStart t))

coords :: Double -> Double -> Maybe Coords
coords la lo
  | abs la <= 90 && abs lo <= 180 = Just (Coords la lo)
  | otherwise                     = Nothing
