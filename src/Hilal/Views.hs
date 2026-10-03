module Hilal.Views
  ( mosquePage
  , mosquesPage
  , notFoundPage
  , clockDigits
  , clockPeriod
  , stylesheet
  , stylesheetPath
  ) where

import Control.Monad (forM_, when)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (Day, LocalTime (..), TimeOfDay, defaultTimeLocale, formatTime)
import Lucid
import Lucid.Base (makeAttributes)

import Hilal.Time (nextPrayer)
import Hilal.Assets (stylesheet, stylesheetPath)
import Hilal.Types (Mosque (..), MosqueId (..), Prayer (..), PrayerTime (..))

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
    body_ [class_ "min-h-screen bg-base-200 text-base-content"] $ do
      header_ [class_ "navbar sticky top-0 z-10 bg-base-100 shadow-sm"] $
        a_ [href_ "/mosques", class_ "btn btn-ghost text-xl gap-2"] $ do
          crescent
          "Hilal"
      main_ [class_ "mx-auto max-w-xl p-4"] content

crescent :: Html ()
crescent =
  toHtmlRaw
    ("<svg viewBox=\"0 0 24 24\" width=\"24\" height=\"24\" aria-hidden=\"true\">\
     \<path fill=\"currentColor\" d=\"M20 14.5A8.5 8.5 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z\"/>\
     \</svg>" :: Text)

chevron :: Html ()
chevron =
  toHtmlRaw
    ("<svg viewBox=\"0 0 24 24\" width=\"20\" height=\"20\" aria-hidden=\"true\" class=\"shrink-0 opacity-40\">\
     \<path d=\"M9 6l6 6-6 6\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" \
     \stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\
     \</svg>" :: Text)

notFoundPage :: Html ()
notFoundPage =
  layout "Not found · Hilal" $ do
    h1_ [class_ "mb-2 text-2xl font-bold"] "Not found"
    p_ [class_ "mb-4 text-base-content/70"]
      "We couldn't find that page. The link may be wrong, or the mosque may have been removed."
    a_ [href_ "/mosques", class_ "btn btn-primary"] "Browse mosques"

mosquesPage :: Text -> [Mosque] -> Bool -> Html ()
mosquesPage q mosques more =
  layout "Mosques · Hilal" $ do
    h1_ [class_ "mb-4 text-2xl font-bold"] "Mosques"
    form_ [method_ "get", action_ "/mosques", role_ "search", class_ "join mb-4 w-full"] $ do
      input_
        [ type_ "search"
        , name_ "q"
        , value_ q
        , placeholder_ "Search by name or area"
        , makeAttributes "aria-label" "Search mosques"
        , class_ "input join-item w-full"
        ]
      button_ [type_ "submit", class_ "btn btn-primary join-item"] "Search"
    case mosques of
      [] | T.null q  -> p_ [class_ "text-base-content/70"] "No mosques are listed yet."
         | otherwise -> p_ [class_ "text-base-content/70"] $ do
             "No mosques match “"
             toHtml q
             "”."
      _ ->
        ul_ [class_ "divide-y divide-base-300 overflow-hidden rounded-box bg-base-100 shadow-sm"] $
          mapM_ item mosques
    when more $
      p_ [class_ "mt-4 text-sm text-base-content/70"]
        "There are more mosques. Refine your search to see them."
  where
    item m =
      li_ $
        a_ [href_ (mosqueUrl m), class_ "flex items-center gap-3 px-4 py-3 active:bg-base-200"] $ do
          div_ [class_ "min-w-0 flex-1"] $ do
            div_ [class_ "truncate font-semibold"] (toHtml (mosqueName m))
            div_ [class_ "truncate text-sm text-base-content/70"] (toHtml (mosqueAddress m))
          chevron

mosqueUrl :: Mosque -> Text
mosqueUrl m =
  let MosqueId n = mosqueId m
   in "/mosques/" <> T.pack (show n)

mosquePage :: Mosque -> [(Prayer, PrayerTime)] -> Maybe LocalTime -> Maybe Day -> Html ()
mosquePage mosque timings now updated =
  layout (mosqueName mosque <> " · Prayer times") $ do
    div_ [class_ "mb-4"] $ do
      h1_ [class_ "text-2xl font-bold"] (toHtml (mosqueName mosque))
      p_ [class_ "text-base-content/70"] (toHtml (mosqueAddress mosque))
      forM_ now $ \t ->
        p_ [class_ "text-sm text-base-content/70"] (toHtml (longDate (localDay t)))
    forM_ next $ \(day, p) ->
      forM_ (lookup p timings) $ \t ->
        div_ [class_ "mb-4 rounded-box bg-base-100 p-4 shadow-sm"] $ do
          span_ [class_ "text-base-content/70"] "Next: "
          strong_ (toHtml (prayerLabel p <> " Jamaat"))
          when (Just day /= fmap localDay now) " tomorrow"
          " at "
          clock (ptJamaat t)
    div_ [class_ "overflow-x-auto rounded-box bg-base-100 shadow-sm"] $
      table_ [class_ "table"] $ do
        thead_ $
          tr_ $ do
            th_ "Prayer"
            th_ "Azan"
            th_ "Jamaat"
        tbody_ $
          mapM_ row [minBound .. maxBound :: Prayer]
    forM_ updated $ \d ->
      p_ [class_ "mt-4 text-sm text-base-content/60"] (toHtml ("Updated " <> shortDate d))
  where
    next = now >>= \t -> nextPrayer t timings
    row prayer =
      tr_ $ do
        th_ [scope_ "row", class_ "font-semibold"] $ do
          toHtml (prayerLabel prayer)
          when (fmap snd next == Just prayer) $
            span_ [class_ "badge badge-primary badge-sm ml-2"] "Next"
        case lookup prayer timings of
          Just t -> do
            timeCell (ptAzan t)
            timeCell (ptJamaat t)
          Nothing ->
            td_ [colspan_ "2", class_ "text-base-content/60"] "Not set"
    timeCell t =
      td_ [class_ "whitespace-nowrap text-lg font-semibold tabular-nums"] (clock t)

longDate :: Day -> Text
longDate = T.pack . formatTime defaultTimeLocale "%A, %-d %B"

shortDate :: Day -> Text
shortDate = T.pack . formatTime defaultTimeLocale "%-d %B %Y"

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
  span_ [class_ "text-xs font-normal text-base-content/60"] (toHtml (clockPeriod t))

clockDigits :: TimeOfDay -> Text
clockDigits = T.pack . formatTime defaultTimeLocale "%-I:%M"

clockPeriod :: TimeOfDay -> Text
clockPeriod = T.pack . formatTime defaultTimeLocale "%p"