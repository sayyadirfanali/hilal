module Hilal.Hijri
  ( HijriDate (..)
  , HijriPart (..)
  , hijriFromDay
  , hijriParts
  , monthEnglish
  , monthUrdu
  ) where

import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (Day, addDays, diffDays)

import Hilal.HijriTable (monthStarts)

data HijriDate = HijriDate
  { hijriYear  :: Int
  , hijriMonth :: Int -- 1 is Muharram
  , hijriDay   :: Int
  }
  deriving (Show, Eq)

-- A Hijri date to display: numbers as text, months by number, so that a page
-- can write month names in Urdu, right to left, between left-to-right numbers.
data HijriPart = HijriText Text | HijriMonth Int
  deriving (Show, Eq)

-- The Umm al-Qura date for a Gregorian day, if the table covers it.
hijriFromDay :: Day -> Maybe HijriDate
hijriFromDay day = do
  ((year, month, start), _) <- find contains (zip monthStarts (drop 1 monthStarts))
  return (HijriDate year month (fromInteger (diffDays day start) + 1))
  where
    contains ((_, _, start), (_, _, next)) = start <= day && day < next

-- Local moon sighting in India usually runs a day behind Umm al-Qura,
-- so the date shows the day before and the Umm al-Qura day: "19/20 Rabi' al-Thani 1448".
hijriParts :: Day -> Maybe [HijriPart]
hijriParts day = do
  local <- hijriFromDay (addDays (-1) day)
  saudi <- hijriFromDay day
  return (parts local saudi)
  where
    parts a b
      | hijriYear a == hijriYear b && hijriMonth a == hijriMonth b =
          [ HijriText (showT (hijriDay a) <> "/" <> showT (hijriDay b) <> " ")
          , HijriMonth (hijriMonth b)
          , HijriText (" " <> showT (hijriYear b))
          ]
      | hijriYear a == hijriYear b =
          [ HijriText (showT (hijriDay a) <> " ")
          , HijriMonth (hijriMonth a)
          , HijriText (" / " <> showT (hijriDay b) <> " ")
          , HijriMonth (hijriMonth b)
          , HijriText (" " <> showT (hijriYear b))
          ]
      | otherwise =
          [ HijriText (showT (hijriDay a) <> " ")
          , HijriMonth (hijriMonth a)
          , HijriText (" " <> showT (hijriYear a) <> " / " <> showT (hijriDay b) <> " ")
          , HijriMonth (hijriMonth b)
          , HijriText (" " <> showT (hijriYear b))
          ]
    showT :: Int -> Text
    showT = T.pack . show

monthEnglish :: Int -> Text
monthEnglish m = case m of
  1  -> "Muharram"
  2  -> "Safar"
  3  -> "Rabi' al-Awwal"
  4  -> "Rabi' al-Thani"
  5  -> "Jumada al-Ula"
  6  -> "Jumada al-Thani"
  7  -> "Rajab"
  8  -> "Sha'ban"
  9  -> "Ramadan"
  10 -> "Shawwal"
  11 -> "Dhu al-Qa'dah"
  _  -> "Dhu al-Hijjah"

-- As written in India. Any new Urdu text must also be added to install_vendor.sh.
monthUrdu :: Int -> Text
monthUrdu m = case m of
  1  -> "محرم"
  2  -> "صفر"
  3  -> "ربیع الاول"
  4  -> "ربیع الثانی"
  5  -> "جمادی الاول"
  6  -> "جمادی الثانی"
  7  -> "رجب"
  8  -> "شعبان"
  9  -> "رمضان"
  10 -> "شوال"
  11 -> "ذوالقعدہ"
  _  -> "ذوالحجہ"
