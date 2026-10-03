module Hilal.Assets
  ( stylesheet
  , stylesheetPath
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
stylesheetPath = "/static/" <> T.pack (showHex (fnv1a stylesheet) "") <> "/app.css"

fnv1a :: ByteString -> Word64
fnv1a = BS.foldl' step 0xcbf29ce484222325
  where
    step h byte = (h `xor` fromIntegral byte) * 0x100000001b3