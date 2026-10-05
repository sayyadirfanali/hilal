module Hilal.Views
  ( FollowState (..)
  , homePage
  , mosquePage
  , mosquesPage
  , mosqueFormPage
  , mosqueUrl
  , signInUrl
  , notFoundPage
  , signInPage
  , codePage
  , accountPage
  , clockDigits
  , clockPeriod
  , stylesheet
  , stylesheetPath
  ) where

import Control.Monad (forM_, unless, when)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time (Day, LocalTime (..), TimeOfDay, defaultTimeLocale, formatTime)
import Lucid
import Lucid.Base (makeAttributes)
import Network.HTTP.Types.URI (urlEncode)

import Hilal.Assets (stylesheet, stylesheetPath)
import Hilal.Edit (MosqueForm (..))
import Hilal.Time (nextPrayer, zoneNames)
import Hilal.Types (Mosque (..), MosqueId (..), Prayer (..), PrayerTime (..), prayerLabel, prayerToText)

data FollowState = SignedOut | NotFollowing | Following
  deriving (Show, Eq)

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
      header_ [class_ "navbar sticky top-0 z-10 justify-between bg-base-100 shadow-sm"] $ do
        a_ [href_ "/", class_ "btn btn-ghost text-xl gap-2"] $ do
          crescent
          "Hilal"
        a_ [href_ "/account", class_ "btn btn-ghost btn-sm"] "Account"
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

notice :: Text -> Html ()
notice message =
  div_ [role_ "alert", class_ "alert alert-warning mb-4"] $
    span_ (toHtml message)

mosqueUrl :: MosqueId -> Text
mosqueUrl (MosqueId n) = "/mosques/" <> T.pack (show n)

signInUrl :: Text -> Text
signInUrl next = "/sign-in?next=" <> decodeUtf8 (urlEncode True (encodeUtf8 next))

nextJamaat :: [(Prayer, PrayerTime)] -> LocalTime -> Maybe (Prayer, TimeOfDay, Bool)
nextJamaat timings now = do
  (day, p) <- nextPrayer now timings
  t <- lookup p timings
  return (p, ptJamaat t, day /= localDay now)

nextLine :: (Prayer, TimeOfDay, Bool) -> Html ()
nextLine (p, jamaat, tomorrow) = do
  strong_ (toHtml (prayerLabel p <> " Jamaat"))
  when tomorrow " tomorrow"
  " at "
  clock jamaat

notFoundPage :: Html ()
notFoundPage =
  layout "Not found · Hilal" $ do
    h1_ [class_ "mb-2 text-2xl font-bold"] "Not found"
    p_ [class_ "mb-4 text-base-content/70"]
      "We couldn't find that page. The link may be wrong, or the mosque may have been removed."
    a_ [href_ "/mosques", class_ "btn btn-primary"] "Browse mosques"

homePage :: [(Mosque, [(Prayer, PrayerTime)], Maybe LocalTime)] -> Html ()
homePage entries =
  layout "My mosques · Hilal" $ do
    h1_ [class_ "mb-4 text-2xl font-bold"] "My mosques"
    case entries of
      [] -> do
        p_ [class_ "mb-4 text-base-content/70"]
          "You're not following any mosques yet. Follow a mosque to see its next prayer here."
        a_ [href_ "/mosques", class_ "btn btn-primary"] "Browse mosques"
      _ -> do
        ul_ [class_ "divide-y divide-base-300 overflow-hidden rounded-box bg-base-100 shadow-sm"] $
          mapM_ item entries
        p_ [class_ "mt-6 text-center text-sm"] $
          a_ [href_ "/mosques", class_ "link link-primary"] "Browse all mosques"
  where
    item (m, timings, now) =
      li_ $
        a_ [href_ (mosqueUrl (mosqueId m)), class_ "flex items-center gap-3 px-4 py-3 active:bg-base-200"] $ do
          div_ [class_ "min-w-0 flex-1"] $ do
            div_ [class_ "truncate font-semibold"] (toHtml (mosqueName m))
            case now >>= nextJamaat timings of
              Just next ->
                div_ [class_ "text-sm text-base-content/70"] (nextLine next)
              Nothing ->
                div_ [class_ "truncate text-sm text-base-content/70"] (toHtml (mosqueAddress m))
          chevron

signInPage :: Text -> Text -> Maybe Text -> Html ()
signInPage email next message =
  layout "Sign in · Hilal" $ do
    h1_ [class_ "mb-2 text-2xl font-bold"] "Sign in"
    p_ [class_ "mb-4 text-base-content/70"] "We'll email you a code. No password needed."
    forM_ message notice
    form_ [method_ "post", action_ "/sign-in", class_ "flex flex-col gap-3"] $ do
      input_ [type_ "hidden", name_ "next", value_ next]
      input_
        [ type_ "email"
        , name_ "email"
        , value_ email
        , required_ ""
        , autocomplete_ "email"
        , placeholder_ "you@example.com"
        , makeAttributes "aria-label" "Email address"
        , class_ "input w-full"
        ]
      button_ [type_ "submit", class_ "btn btn-primary"] "Send code"

codePage :: Text -> Text -> Maybe Text -> Html ()
codePage email next message =
  layout "Enter code · Hilal" $ do
    h1_ [class_ "mb-2 text-2xl font-bold"] "Check your email"
    p_ [class_ "mb-4 text-base-content/70"] $ do
      "We sent a 6-digit code to "
      strong_ (toHtml email)
      ". It expires in 10 minutes."
    forM_ message notice
    form_ [method_ "post", action_ "/sign-in/code", class_ "flex flex-col gap-3"] $ do
      input_ [type_ "hidden", name_ "email", value_ email]
      input_ [type_ "hidden", name_ "next", value_ next]
      input_
        [ type_ "text"
        , name_ "code"
        , required_ ""
        , autocomplete_ "one-time-code"
        , makeAttributes "inputmode" "numeric"
        , makeAttributes "pattern" "[0-9]{6}"
        , makeAttributes "maxlength" "6"
        , placeholder_ "123456"
        , makeAttributes "aria-label" "Sign-in code"
        , class_ "input w-full text-center text-2xl tracking-widest tabular-nums"
        ]
      button_ [type_ "submit", class_ "btn btn-primary"] "Sign in"
    a_ [href_ "/sign-in", class_ "link mt-4 inline-block text-sm"]
      "Use a different email or get a new code"

accountPage :: Text -> Bool -> Html ()
accountPage email superadmin =
  layout "Account · Hilal" $ do
    h1_ [class_ "mb-4 text-2xl font-bold"] "Account"
    div_ [class_ "mb-4 rounded-box bg-base-100 p-4 shadow-sm"] $ do
      p_ [class_ "text-sm text-base-content/70"] "Signed in as"
      p_ [class_ "break-all font-semibold"] (toHtml email)
      when superadmin $
        span_ [class_ "badge badge-primary badge-sm mt-2"] "Superadmin"
    form_ [method_ "post", action_ "/sign-out"] $
      button_ [type_ "submit", class_ "btn btn-outline w-full"] "Sign out"

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
             "No mosques match \""
             toHtml q
             "\"."
      _ ->
        ul_ [class_ "divide-y divide-base-300 overflow-hidden rounded-box bg-base-100 shadow-sm"] $
          mapM_ item mosques
    when more $
      p_ [class_ "mt-4 text-sm text-base-content/70"]
        "There are more mosques. Refine your search to see them."
    p_ [class_ "mt-6 text-center text-sm text-base-content/70"] $ do
      "Can't find your mosque? "
      a_ [href_ "/mosques/new", class_ "link link-primary"] "Add it"
  where
    item m =
      li_ $
        a_ [href_ (mosqueUrl (mosqueId m)), class_ "flex items-center gap-3 px-4 py-3 active:bg-base-200"] $ do
          div_ [class_ "min-w-0 flex-1"] $ do
            div_ [class_ "truncate font-semibold"] (toHtml (mosqueName m))
            div_ [class_ "truncate text-sm text-base-content/70"] (toHtml (mosqueAddress m))
          chevron

mosquePage :: Mosque -> [(Prayer, PrayerTime)] -> Maybe LocalTime -> Maybe Day -> Maybe FollowState -> Html ()
mosquePage mosque timings now updated followState =
  layout (mosqueName mosque <> " · Prayer times") $ do
    div_ [class_ "mb-4 flex items-start justify-between gap-2"] $ do
      div_ [class_ "min-w-0"] $ do
        h1_ [class_ "text-2xl font-bold"] (toHtml (mosqueName mosque))
        p_ [class_ "text-base-content/70"] (toHtml (mosqueAddress mosque))
        forM_ now $ \t ->
          p_ [class_ "text-sm text-base-content/70"] (toHtml (longDate (localDay t)))
      div_ [class_ "flex shrink-0 gap-2"] $ do
        forM_ followState (followButton (mosqueId mosque))
        a_ [href_ (mosqueUrl (mosqueId mosque) <> "/edit"), class_ "btn btn-ghost btn-sm"] "Edit"
    forM_ next $ \n ->
      div_ [class_ "mb-4 rounded-box bg-base-100 p-4 shadow-sm"] $ do
        span_ [class_ "text-base-content/70"] "Next: "
        nextLine n
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
    next = now >>= nextJamaat timings
    nextPrayerOnly = (\(p, _, _) -> p) <$> next
    row prayer =
      tr_ $ do
        th_ [scope_ "row", class_ "font-semibold"] $ do
          toHtml (prayerLabel prayer)
          when (nextPrayerOnly == Just prayer) $
            span_ [class_ "badge badge-primary badge-sm ml-2"] "Next"
        case lookup prayer timings of
          Just t -> do
            timeCell (ptAzan t)
            timeCell (ptJamaat t)
          Nothing ->
            td_ [colspan_ "2", class_ "text-base-content/60"] "Not set"
    timeCell t =
      td_ [class_ "whitespace-nowrap text-lg font-semibold tabular-nums"] (clock t)

followButton :: MosqueId -> FollowState -> Html ()
followButton mid state = case state of
  SignedOut ->
    a_ [href_ (signInUrl url), class_ "btn btn-primary btn-sm"] "Follow"
  NotFollowing ->
    form_ [method_ "post", action_ (url <> "/follow")] $
      button_ [type_ "submit", class_ "btn btn-primary btn-sm"] "Follow"
  Following ->
    form_ [method_ "post", action_ (url <> "/unfollow")] $
      button_
        [ type_ "submit"
        , class_ "btn btn-outline btn-sm"
        , makeAttributes "aria-label" "Unfollow"
        ]
        "Following"
  where
    url = mosqueUrl mid

mosqueFormPage :: Text -> Text -> [Text] -> MosqueForm -> [Prayer] -> Bool -> Html ()
mosqueFormPage title action errors form upcoming detectZone =
  layout (title <> " · Hilal") $ do
    h1_ [class_ "mb-4 text-2xl font-bold"] (toHtml title)
    unless (null errors) $
      div_ [role_ "alert", class_ "alert alert-error mb-4"] $
        ul_ [class_ "list-disc pl-4"] (mapM_ (li_ . toHtml) errors)
    form_ [method_ "post", action_ action, class_ "flex flex-col gap-4"] $ do
      div_ [class_ "rounded-box bg-base-100 p-4 shadow-sm"] $ do
        fieldset_ [class_ "fieldset"] $ do
          label_ [for_ "name", class_ "fieldset-legend"] "Name"
          input_
            [ type_ "text"
            , id_ "name"
            , name_ "name"
            , value_ (formName form)
            , required_ ""
            , placeholder_ "Jama Masjid"
            , class_ "input w-full"
            ]
        fieldset_ [class_ "fieldset"] $ do
          label_ [for_ "address", class_ "fieldset-legend"] "Address"
          input_
            [ type_ "text"
            , id_ "address"
            , name_ "address"
            , value_ (formAddress form)
            , required_ ""
            , placeholder_ "Sector 6, Bhilai"
            , class_ "input w-full"
            ]
        fieldset_ [class_ "fieldset"] $ do
          label_ [for_ "timezone", class_ "fieldset-legend"] "Time zone"
          select_ [id_ "timezone", name_ "timezone", class_ "select w-full"] $
            mapM_ zoneOption zones
      div_ [class_ "rounded-box bg-base-100 p-4 shadow-sm"] $ do
        div_ [class_ "mb-2 grid grid-cols-[5rem_1fr_1fr] gap-2 text-sm text-base-content/70"] $ do
          span_ "Prayer"
          span_ "Azan"
          span_ "Jamaat"
        mapM_ prayerRow (formTimes form)
      button_ [type_ "submit", class_ "btn btn-primary"] "Save"
    when detectZone $
      script_ [] (toHtmlRaw timezoneScript)
  where
    zones
      | formTimezone form `elem` zoneNames = zoneNames
      | otherwise                          = formTimezone form : zoneNames
    zoneOption z =
      option_ ([value_ z] <> (if z == formTimezone form then [selected_ ""] else [])) (toHtml z)
    prayerRow (p, (azan, jamaat)) = do
      div_ [class_ "grid grid-cols-[5rem_1fr_1fr] items-center gap-2 py-1"] $ do
        span_ [class_ "font-semibold"] (toHtml (prayerLabel p))
        timeInput p "azan" "Azan" azan
        timeInput p "jamaat" "Jamaat" jamaat
      when (p `elem` upcoming) $
        p_ [class_ "mb-1 text-xs text-warning"]
          "Hasn't happened yet today, so a change applies from today."
    timeInput p suffix label value =
      input_
        [ type_ "time"
        , name_ (prayerToText p <> "_" <> suffix)
        , value_ value
        , required_ ""
        , makeAttributes "aria-label" (prayerLabel p <> " " <> label)
        , class_ "input w-full"
        ]

timezoneScript :: Text
timezoneScript =
  "(function () {\
  \  var zone = Intl.DateTimeFormat().resolvedOptions().timeZone;\
  \  var select = document.getElementById('timezone');\
  \  if (!zone || !select) return;\
  \  for (var i = 0; i < select.options.length; i++) {\
  \    if (select.options[i].value === zone) { select.value = zone; return; }\
  \  }\
  \})();"

longDate :: Day -> Text
longDate = T.pack . formatTime defaultTimeLocale "%A, %-d %B"

shortDate :: Day -> Text
shortDate = T.pack . formatTime defaultTimeLocale "%-d %B %Y"

clock :: TimeOfDay -> Html ()
clock t = do
  toHtml (clockDigits t)
  " "
  span_ [class_ "text-xs font-normal text-base-content/60"] (toHtml (clockPeriod t))

clockDigits :: TimeOfDay -> Text
clockDigits = T.pack . formatTime defaultTimeLocale "%-I:%M"

clockPeriod :: TimeOfDay -> Text
clockPeriod = T.pack . formatTime defaultTimeLocale "%p"
