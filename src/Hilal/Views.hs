module Hilal.Views
  ( mosquePage
  , notFoundPage
  , clockDigits
  , clockPeriod
  , stylesheet
  , stylesheetPath
  ) where

import Data.Bits (xor)
import Data.ByteString qualified as BS
import Data.FileEmbed (embedFile)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeOfDay, defaultTimeLocale, formatTime)
import Data.Word (Word64)
import Numeric (showHex)

import Lucid
import Hilal.Types

-- | read both @pico.min.css@ and @hilal.css@ at compile time
stylesheet :: BS.ByteString
stylesheet =
  $(embedFile "static/pico.min.css") <> "\n" <> $(embedFile "static/hilal.css")

-- | create new based on @fnv1a(pico.min.css + hilal.css)@ to renew cached files
stylesheetPath :: Text
stylesheetPath = "/static/" <> T.pack (showHex (fnv1a stylesheet) "") <> "/app.css"

fnv1a :: BS.ByteString -> Word64
fnv1a = BS.foldl' step 0xcbf29ce484222325
  where
    step h byte = (h `xor` fromIntegral byte) * 0x100000001b3

notFoundPage :: Html ()
notFoundPage =
  layout "Not found" $ do
    h1_ "Not found"
    p_ "We couldn't find that page. The link may be wrong, or the mosque may have been removed."

prayerLabel :: Prayer -> Text
prayerLabel prayer = case prayer of
  Fajr    -> "Fajr"
  Zuhr    -> "Zuhr"
  Asr     -> "Asr"
  Maghrib -> "Maghrib"
  Isha    -> "Isha"
  Jumuah  -> "Jumu'ah"

clock :: TimeOfDay -> Html ()
clock t = do
  toHtml (clockDigits t)
  " "
  span_ [class_ "ampm"] (toHtml (clockPeriod t))

clockDigits :: TimeOfDay -> Text
clockDigits = T.pack . formatTime defaultTimeLocale "%-I:%M"

clockPeriod :: TimeOfDay -> Text
clockPeriod = T.pack . formatTime defaultTimeLocale "%p"

-- | app shell
layout :: Text -> Html () -> Html ()
layout title content = do
  doctype_
  html_ [lang_ "en"] $ do
    head_ $ do
      meta_ [charset_ "utf-8"]
      meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
      meta_ [name_ "color-scheme", content_ "light dark"]
      title_ (toHtml title)
      link_ [rel_ "stylesheet", href_ stylesheetPath]
    body_ $
      main_ [class_ "container"] content

-- | mosque name and timings
mosquePage :: Mosque -> [(Prayer, PrayerTime)] -> Html ()
mosquePage mosque timings =
  layout (mosqueName mosque <> " · Prayer times") $ do
    hgroup_ $ do
      h1_ (toHtml (mosqueName mosque))
      p_ (toHtml (mosqueAddress mosque))
    table_ [class_ "timings"] $ do
      thead_ $
        tr_ $ do
          th_ "Prayer"
          th_ "Azan"
          th_ "Jamaat"
      tbody_ $
        mapM_ row [minBound .. maxBound :: Prayer]
  where
    row prayer =
      tr_ $ do
        th_ [scope_ "row"] (toHtml (prayerLabel prayer))
        case lookup prayer timings of
          Just t -> do
            td_ (clock (ptAzan t))
            td_ (clock (ptJamaat t))
          Nothing ->
            td_ [colspan_ "2", class_ "unset"] "Not set"