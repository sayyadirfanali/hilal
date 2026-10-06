module Hilal.Assets
  ( stylesheet
  , stylesheetPath
  , maplibreJs
  , maplibreJsPath
  , maplibreCss
  , maplibreCssPath
  , interFont
  , interFontPath
  , urduFont
  , urduFontPath
  , fnv1a
  ) where

import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.FileEmbed (embedFile)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import Numeric (showHex)

stylesheet :: ByteString
stylesheet = $(embedFile "static/app.gen.css")

stylesheetPath :: Text
stylesheetPath = fingerprinted stylesheet "app.css"

-- MapLibre is served from Hilal itself, not a CDN, so viewers' addresses
-- aren't sent to a third party just to load the map's code.
maplibreJs :: ByteString
maplibreJs = $(embedFile "vendor/maplibre-gl.js")

maplibreJsPath :: Text
maplibreJsPath = fingerprinted maplibreJs "maplibre-gl.js"

maplibreCss :: ByteString
maplibreCss = $(embedFile "vendor/maplibre-gl.css")

maplibreCssPath :: Text
maplibreCssPath = fingerprinted maplibreCss "maplibre-gl.css"

-- Fonts are served from Hilal itself too, never from Google Fonts.
interFont :: ByteString
interFont = $(embedFile "vendor/inter.woff2")

interFontPath :: Text
interFontPath = fingerprinted interFont "inter.woff2"

-- Noto Sans Arabic, cut down to the Urdu letters Hilal uses.
urduFont :: ByteString
urduFont = $(embedFile "vendor/urdu.woff2")

urduFontPath :: Text
urduFontPath = fingerprinted urduFont "urdu.woff2"

fingerprinted :: ByteString -> Text -> Text
fingerprinted contents name = "/static/" <> T.pack (showHex (fnv1a contents) "") <> "/" <> name

fnv1a :: ByteString -> Word64
fnv1a = BS.foldl' step 0xcbf29ce484222325
  where
    step h byte = (h `xor` fromIntegral byte) * 0x100000001b3
