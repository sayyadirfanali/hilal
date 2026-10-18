module Hilal.Views
  ( FollowState (..)
  , Editing (..)
  , homePage
  , mosquePage
  , mosquesPage
  , mosqueFormPage
  , addLinkPage
  , notAllowedPage
  , usersPage
  , mosqueUrl
  , signInUrl
  , notFoundPage
  , signInPage
  , codePage
  , accountPage
  , deleteAccountPage
  , accountDeletedPage
  , privacyPage
  , clockDigits
  , clockPeriod
  , countdown
  , formatDistance
  , stylesheet
  , stylesheetPath
  ) where

import Control.Monad (forM_, unless, when)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time (Day, LocalTime (..), TimeOfDay, defaultTimeLocale, formatTime)
import Lucid
import Lucid.Base (makeAttributes)
import Network.HTTP.Types.URI (urlEncode)

import Hilal.Assets (interFontPath, maplibreCssPath, maplibreJsPath, stylesheet, stylesheetPath, urduFontPath)
import Hilal.Edit (MosqueForm (..))
import Hilal.Hijri (HijriPart (..), hijriParts, monthEnglish, monthUrdu)
import Hilal.Time (NextJamaat (..), zoneNames)
import Hilal.Types
  ( Coords (..)
  , Mosque (..)
  , MosqueId (..)
  , Prayer (..)
  , PrayerTime (..)
  , User (..)
  , UserId (..)
  , formatTimestamp
  , isDeleted
  , prayerLabel
  , prayerToText
  , prayerUrdu
  )

data FollowState = SignedOut | NotFollowing | Following
  deriving (Show, Eq)

-- What the viewer of a mosque's page may do about its timings.
data Editing
  = Reporter Text                -- report them, by email to this address: the superadmin's
  | Maintainer                   -- edit them, as the mosque's maintainer
  | Superadmin (Maybe Text) [Text] -- edit them, and choose the maintainer: theirs, and what went wrong choosing
  deriving (Show, Eq)

-- Which tab of the bottom bar is highlighted.
data Tab = MineTab | NearbyTab | AccountTab | NoTab
  deriving (Eq)

-- Every page has the green band at the top, with the page's own heading in it,
-- and the bottom bar of tabs.
layout :: Text -> Tab -> Html () -> Html () -> Html ()
layout title tab band content = do
  doctype_
  html_ [lang_ "en"] $ do
    head_ $ do
      meta_ [charset_ "utf-8"]
      meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1, viewport-fit=cover"]
      meta_ [name_ "color-scheme", content_ "light dark"]
      meta_ [name_ "theme-color", content_ "#1F4D3A"]
      title_ (toHtml title)
      link_
        [ rel_ "preload"
        , href_ interFontPath
        , makeAttributes "as" "font"
        , type_ "font/woff2"
        , makeAttributes "crossorigin" ""
        ]
      style_ [] fontFaces
      link_ [rel_ "stylesheet", href_ stylesheetPath]
    body_ [class_ "min-h-screen bg-base-200 text-base-content antialiased"] $ do
      header_ [class_ "hilal-band"] $
        div_ [class_ "mx-auto max-w-xl px-4 pt-3 pb-5"] $ do
          a_ [href_ "/", class_ "mb-3 inline-flex items-center gap-2 text-lg font-semibold text-secondary"] $ do
            crescent
            "Hilal"
          band
      main_ [class_ "mx-auto max-w-xl px-4 pt-4 pb-28"] content
      nav_ [class_ "dock hilal-dock", makeAttributes "aria-label" "Main"] $ do
        tabLink MineTab "/" homeIcon "My mosques"
        tabLink NearbyTab "/mosques" pinIcon "Nearby"
        tabLink AccountTab "/account" userIcon "Account"
  where
    tabLink t href icon label
      | t == tab =
          a_ [href_ href, class_ "dock-active text-secondary", makeAttributes "aria-current" "page"] $ do
            icon
            span_ [class_ "dock-label"] label
      | otherwise =
          a_ [href_ href, class_ "opacity-80"] $ do
            icon
            span_ [class_ "dock-label"] label

-- The fonts' URLs carry fingerprints, so their rules live here, not in app.css.
fontFaces :: Text
fontFaces =
  "@font-face{font-family:\"Inter\";src:url(" <> interFontPath <> ") format(\"woff2\");\
  \font-weight:100 900;font-style:normal;font-display:swap}\
  \@font-face{font-family:\"Hilal Urdu\";src:url(" <> urduFontPath <> ") format(\"woff2\");\
  \font-weight:100 900;font-display:swap;unicode-range:U+0600-06FF,U+0750-077F,U+FB50-FDFF,U+FE70-FEFF}"

bandTitle :: Text -> Html ()
bandTitle t = h1_ [class_ "text-2xl font-semibold leading-tight"] (toHtml t)

-- Urdu text, set right to left inside the English line around it.
urdu :: Text -> Text -> Html ()
urdu classes t = span_ [lang_ "ur", makeAttributes "dir" "rtl", class_ classes] (toHtml t)

hijriHtml :: [HijriPart] -> Html ()
hijriHtml = mapM_ part
  where
    part (HijriText t)  = toHtml t
    part (HijriMonth m) =
      span_ [lang_ "ur", makeAttributes "dir" "rtl", title_ (monthEnglish m)] (toHtml (monthUrdu m))

listClasses :: Text
listClasses = "divide-y divide-base-300 overflow-hidden rounded-box border border-base-300 bg-base-100"

svgIcon :: Text -> Html ()
svgIcon paths =
  toHtmlRaw
    ( "<svg viewBox=\"0 0 24 24\" width=\"22\" height=\"22\" aria-hidden=\"true\" fill=\"none\" \
      \stroke=\"currentColor\" stroke-width=\"1.75\" stroke-linecap=\"round\" stroke-linejoin=\"round\">"
        <> paths
        <> "</svg>"
    )

homeIcon :: Html ()
homeIcon = svgIcon "<path d=\"M5 12H3l9-9 9 9h-2\"/><path d=\"M5 12v7a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-7\"/>"

pinIcon :: Html ()
pinIcon = svgIcon "<path d=\"M9 11a3 3 0 1 0 6 0a3 3 0 0 0-6 0\"/><path d=\"M17.66 16.66l-4.25 4.24a2 2 0 0 1-2.82 0l-4.25-4.24a8 8 0 1 1 11.32 0z\"/>"

userIcon :: Html ()
userIcon = svgIcon "<path d=\"M8 7a4 4 0 1 0 8 0a4 4 0 0 0-8 0\"/><path d=\"M6 21v-2a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v2\"/>"

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

-- An email to the superadmin, from the person's own email app, naming the mosque.
-- Nothing passes through Hilal, so nothing about the person is kept.
reportLink :: Text -> Mosque -> Text
reportLink address m =
  "mailto:" <> address <> "?subject=" <> encode subject <> "&body=" <> encode body
  where
    MosqueId n = mosqueId m
    subject = "Hilal: mosque " <> T.pack (show n) <> ", " <> mosqueName m
    body = "Which timings are wrong, and what are they now?\n\n"
    encode = decodeUtf8 . urlEncode True . encodeUtf8

-- One line for lists: "Asr Jamaat عصر at 4:15 PM · in 2 h 15 min".
nextLine :: NextJamaat -> Html ()
nextLine n = do
  strong_ [class_ "font-semibold text-base-content"] (toHtml (prayerLabel (njPrayer n) <> " Jamaat"))
  " "
  urdu "text-accent" (prayerUrdu (njPrayer n))
  when (njTomorrow n) " tomorrow"
  " at "
  clock (njTime n)
  " · "
  countdownSpan n

countdownSpan :: NextJamaat -> Html ()
countdownSpan n =
  span_ [makeAttributes "data-countdown" (formatTimestamp (njAt n))] (toHtml (countdown (njSeconds n)))

-- Rounds up, so "in 1 min" lasts until the Jamaat minute begins.
countdown :: Int -> Text
countdown seconds
  | minutes <= 0 = "now"
  | minutes < 60 = "in " <> showT minutes <> " min"
  | rest == 0    = "in " <> showT hours <> " h"
  | otherwise    = "in " <> showT hours <> " h " <> showT rest <> " min"
  where
    minutes = (seconds + 59) `div` 60
    (hours, rest) = minutes `divMod` 60
    showT = T.pack . show

-- Keeps every countdown current, and reloads once, a minute after the
-- earliest Jamaat, when the server will have moved on to the next prayer.
-- Must format exactly like `countdown`.
countdownScript :: Html ()
countdownScript =
  script_ [] (toHtmlRaw script)
  where
    script :: Text
    script =
      "(function () {\
      \  var els = document.querySelectorAll('[data-countdown]');\
      \  if (!els.length) return;\
      \  function at(el) { return Date.parse(el.getAttribute('data-countdown')); }\
      \  function label(ms) {\
      \    var m = Math.ceil(ms / 60000);\
      \    if (m <= 0) return 'now';\
      \    if (m < 60) return 'in ' + m + ' min';\
      \    var h = Math.floor(m / 60), r = m % 60;\
      \    return 'in ' + h + ' h' + (r ? ' ' + r + ' min' : '');\
      \  }\
      \  function tick() {\
      \    var now = Date.now();\
      \    for (var i = 0; i < els.length; i++) els[i].textContent = label(at(els[i]) - now);\
      \  }\
      \  var first = Infinity;\
      \  for (var i = 0; i < els.length; i++) first = Math.min(first, at(els[i]));\
      \  var wait = first + 61000 - Date.now();\
      \  if (wait > 0) setTimeout(function () { location.reload(); }, wait);\
      \  tick();\
      \  setInterval(tick, 15000);\
      \})();"

notFoundPage :: Html ()
notFoundPage =
  layout "Not found · Hilal" NoTab (bandTitle "Not found") $ do
    p_ [class_ "mb-4 text-base-content/70"]
      "We couldn't find that page. The link may be wrong, or the mosque may have been removed."
    a_ [href_ "/mosques", class_ "btn btn-primary"] "Browse mosques"

homePage :: [(Mosque, Maybe NextJamaat)] -> Html ()
homePage entries =
  layout "My mosques · Hilal" MineTab (bandTitle "My mosques") $ do
    case entries of
      [] ->
        div_ [class_ "rounded-box border border-base-300 bg-base-100 p-4"] $ do
          p_ [class_ "mb-4 text-base-content/70"]
            "You're not following any mosques yet. Follow a mosque to see its next prayer here."
          a_ [href_ "/mosques", class_ "btn btn-primary w-full"] "Browse mosques"
      _ -> do
        ul_ [class_ listClasses] $
          mapM_ item entries
        p_ [class_ "mt-6 text-center text-sm"] $
          a_ [href_ "/mosques", class_ "link link-accent"] "Browse all mosques"
        when (any (isJust . snd) entries) countdownScript
  where
    item (m, next) =
      li_ $
        a_ [href_ (mosqueUrl (mosqueId m)), class_ "flex items-center gap-3 px-4 py-3 active:bg-base-200"] $ do
          div_ [class_ "min-w-0 flex-1"] $ do
            div_ [class_ "truncate font-semibold"] (toHtml (mosqueName m))
            case next of
              Just n ->
                div_ [class_ "text-sm text-base-content/70"] (nextLine n)
              Nothing ->
                div_ [class_ "truncate text-sm text-base-content/70"] (toHtml (mosqueAddress m))
          chevron

signInPage :: Text -> Text -> Maybe Text -> Html ()
signInPage email next message =
  layout "Sign in · Hilal" AccountTab (bandTitle "Sign in") $ do
    p_ [class_ "mb-4 text-base-content/70"] "We'll email you a code. No password needed."
    forM_ message notice
    form_ [method_ "post", action_ "/sign-in", class_ "flex flex-col gap-3 rounded-box border border-base-300 bg-base-100 p-4"] $ do
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
    privacyLink

codePage :: Text -> Text -> Maybe Text -> Html ()
codePage email next message =
  layout "Enter code · Hilal" AccountTab (bandTitle "Check your email") $ do
    p_ [class_ "mb-4 text-base-content/70"] $ do
      "We sent a 6-digit code to "
      strong_ (toHtml email)
      ". It expires in 10 minutes."
    forM_ message notice
    form_ [method_ "post", action_ "/sign-in/code", class_ "flex flex-col gap-3 rounded-box border border-base-300 bg-base-100 p-4"] $ do
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
    a_ [href_ "/sign-in", class_ "link link-accent mt-4 inline-block text-sm"]
      "Use a different email or get a new code"

-- The mosques listed are those the person maintains, which only they and the superadmin see.
accountPage :: Text -> Bool -> [Mosque] -> Html ()
accountPage email superadmin maintained =
  layout "Account · Hilal" AccountTab (bandTitle "Account") $ do
    div_ [class_ "mb-4 rounded-box border border-base-300 bg-base-100 p-4"] $ do
      p_ [class_ "text-sm text-base-content/70"] "Signed in as"
      p_ [class_ "break-all font-semibold"] (toHtml email)
      when superadmin $ do
        span_ [class_ "badge badge-secondary badge-sm mt-2"] "Superadmin"
        p_ [class_ "mt-3 text-sm"] $
          a_ [href_ "/admin/users", class_ "link link-accent"] "Manage users"
    unless (null maintained) $ do
      p_ [class_ "mb-2 text-sm text-base-content/70"] "You maintain"
      ul_ [class_ (listClasses <> " mb-4")] $
        forM_ maintained $ \m ->
          li_ $
            a_ [href_ (mosqueUrl (mosqueId m)), class_ "flex items-center gap-3 px-4 py-3 active:bg-base-200"] $ do
              div_ [class_ "min-w-0 flex-1"] $ do
                div_ [class_ "truncate font-semibold"] (toHtml (mosqueName m))
                div_ [class_ "truncate text-sm text-base-content/70"] (toHtml (mosqueAddress m))
              chevron
    form_ [method_ "post", action_ "/sign-out"] $
      button_ [type_ "submit", class_ "btn btn-outline w-full"] "Sign out"
    div_ [class_ "mt-6 flex justify-between text-sm"] $ do
      a_ [href_ "/privacy", class_ "link link-accent"] "Privacy"
      a_ [href_ "/account/delete", class_ "link text-error"] "Delete account"

privacyLink :: Html ()
privacyLink =
  p_ [class_ "mt-4 text-sm"] $
    a_ [href_ "/privacy", class_ "link link-accent"] "How Hilal uses your data"

-- Asked once more, since nothing can be undone.
deleteAccountPage :: Text -> Html ()
deleteAccountPage email =
  layout "Delete account · Hilal" AccountTab (bandTitle "Delete account") $ do
    div_ [class_ "mb-4 rounded-box border border-base-300 bg-base-100 p-4"] $ do
      p_ [class_ "mb-2"] $ do
        "This deletes the account for "
        strong_ [class_ "break-all"] (toHtml email)
        ", the mosques it follows, and its sign-in on every device."
      p_ [class_ "mb-2"] "The app on your phone stops sounding the Azan once it next connects."
      p_ [class_ "text-base-content/70"] $ do
        "Mosques and timings you added or edited stay, for everyone who follows them. "
        "You can sign up again with the same email, as a new account."
    form_ [method_ "post", action_ "/account/delete"] $
      button_ [type_ "submit", class_ "btn btn-error w-full"] "Delete my account"
    a_ [href_ "/account", class_ "link link-accent mt-4 inline-block text-sm"] "Keep my account"

accountDeletedPage :: Html ()
accountDeletedPage =
  layout "Account deleted · Hilal" AccountTab (bandTitle "Account deleted") $ do
    p_ [class_ "mb-4"] "Your account is deleted. Thank you for using Hilal."
    a_ [href_ "/mosques", class_ "link link-accent"] "Browse mosques"

-- The superadmin's page for finding an account, by email or by the number in edits.log,
-- and blocking or unblocking it.
usersPage :: Text -> Text -> Maybe (User, Bool, [Mosque]) -> Html ()
usersPage superadmin q found =
  layout "Users · Hilal" AccountTab (bandTitle "Users") $ do
    form_ [method_ "get", action_ "/admin/users", role_ "search", class_ "join mb-4 w-full"] $ do
      input_
        [ type_ "search"
        , name_ "q"
        , value_ q
        , required_ ""
        , placeholder_ "Email or account number"
        , makeAttributes "aria-label" "Email or account number"
        , class_ "input join-item w-full"
        ]
      button_ [type_ "submit", class_ "btn btn-primary join-item"] "Find"
    case found of
      Nothing
        | T.null q  -> p_ [class_ "text-base-content/70"] "Find an account by its email, or by its number in edits.log."
        | otherwise -> p_ [class_ "text-base-content/70"] $ do
            "No account matches \""
            toHtml q
            "\"."
      Just (u, blocked, maintained) -> account u blocked maintained
    a_ [href_ "/account", class_ "link link-accent mt-6 inline-block text-sm"] "Back to Account"
  where
    account u blocked maintained = do
      let UserId n = userId u
          url = "/admin/users/" <> T.pack (show n)
      div_ [class_ "flex flex-col gap-2 rounded-box border border-base-300 bg-base-100 p-4"] $ do
        p_ [class_ "break-all font-semibold"] $
          if isDeleted u then "Deleted account" else toHtml (userEmail u)
        p_ [class_ "text-sm text-base-content/70"] $ do
          toHtml ("Account " <> T.pack (show n) <> " · ")
          if blocked then "Blocked" else "Active"
        unless (null maintained) $ do
          p_ [class_ "text-sm text-base-content/70"] "Maintains"
          ul_ [class_ "list-disc pl-5"] $
            forM_ maintained $ \m ->
              li_ $ a_ [href_ (mosqueUrl (mosqueId m)), class_ "link link-accent"] (toHtml (mosqueName m))
        blockButton u blocked url
    -- Never for the superadmin, nor to unblock a deleted account, whose email is gone.
    blockButton u blocked url
      | userEmail u == superadmin =
          p_ [class_ "text-sm text-base-content/70"] "This is you."
      | isDeleted u =
          return ()
      | blocked =
          form_ [method_ "post", action_ (url <> "/unblock")] $
            button_ [type_ "submit", class_ "btn btn-outline w-full"] "Unblock"
      | otherwise =
          form_ [method_ "post", action_ (url <> "/block")] $ do
            p_ [class_ "mb-2 text-sm text-base-content/70"]
              "Blocking signs them out everywhere and removes them as maintainer; their email can't sign in again."
            button_ [type_ "submit", class_ "btn btn-error w-full"] "Block"

privacyPage :: Html ()
privacyPage =
  layout "Privacy · Hilal" NoTab (bandTitle "Privacy") $
    div_ [class_ "flex flex-col gap-4 rounded-box border border-base-300 bg-base-100 p-4 leading-relaxed"] $ do
      p_ [class_ "text-sm text-base-content/70"] "Last updated 18 October 2026"
      p_ $ do
        "Hilal tells you the Azan and Jamaat times of the mosques you follow. "
        "It is run by Irfan Ali, who you can write to at "
        a_ [href_ "mailto:irfan@irfanali.org", class_ "link link-accent"] "irfan@irfanali.org"
        ". Hilal keeps as little about you as it can, shows no ads, and sells or shares nothing."

      section "What Hilal keeps" $ bullets $ do
        bullet "Your email address, so you can sign in."
        bullet "The mosques you follow, so Hilal can show their times and the app can sound their Azan. No one else can see them."
        bullet "If you look after a mosque's timings for Hilal, which mosque. Only you and Hilal's superadmin can see it."
        bullet $ do
          "A record of each mosque you add and each change you make, so mistakes and vandalism can be found and undone. "
          "It names your account by number, not by email, and never shows anyone who made a change."
        bullet $ do
          "While you sign in: the code we email you, stored scrambled, for 10 minutes; "
          "and the codes sent and wrong codes tried, for a day, to stop abuse."
        bullet "A cookie that keeps you signed in, for up to a year. Hilal sets no other cookies."
        bullet $ do
          "Nothing when you report wrong timings: Report opens your own email app, "
          "and your email reaches Hilal's superadmin from your address, like any other."

      section "Your location" $ bullets $ do
        bullet $ do
          "Only when you ask for mosques near you. "
          "Your phone rounds it to about 100 metres before sending it; it is used to sort the list, and never stored or logged."
        bullet "The map beside that list is drawn from OpenFreeMap, which sees your internet address and the area shown, as any website you load does."

      section "The app on your phone" $ bullets $ do
        bullet "It keeps the timings and Azan recordings of the mosques you follow on the phone, so the Azan sounds without internet."
        bullet "It sends nothing beyond what the website does. It has no analytics, no ads, and no trackers, and uses no Google services."
        bullet "Uninstalling it removes everything it kept."

      section "Who else handles your data" $ bullets $ do
        bullet "Brevo sends the sign-in emails, so it receives your email address."
        bullet "Hostinger runs the server Hilal lives on."
        bullet "OpenStreetMap's Nominatim receives a mosque's public address when it is added, to find where it is; nothing about you."
        bullet "Links to Google Maps open Google Maps, under Google's own privacy policy."

      section "How long" $ bullets $ do
        bullet "Your account, until you delete it."
        bullet "Copies of Hilal's data are made whenever Hilal is updated, in case the server fails. A deleted account remains in those copies until they are replaced by newer ones."

      section "Deleting your account" $
        p_ $ do
          "Go to Account, then "
          a_ [href_ "/account/delete", class_ "link link-accent"] "Delete account"
          ". Your email, your follows, your sign-ins, and any mosque you look after are removed at once. "
          "Records of your edits stay, without anything that leads back to you. "
          "If you can't sign in, write to the address above."
  where
    section :: Text -> Html () -> Html ()
    section title body = div_ $ do
      h2_ [class_ "mb-1 font-semibold"] (toHtml title)
      body
    bullets :: Html () -> Html ()
    bullets = ul_ [class_ "list-disc space-y-1 pl-5"]
    bullet :: Html () -> Html ()
    bullet = li_

-- Without a location or a search, the page asks for one instead of listing every mosque.
mosquesPage :: Text -> Maybe Coords -> [(Mosque, Maybe Double)] -> Bool -> Html ()
mosquesPage q origin results more =
  layout "Mosques · Hilal" NearbyTab (bandTitle (if isJust origin then "Mosques near you" else "Mosques")) $ do
    when blank $
      div_ [class_ "mb-4 rounded-box border border-base-300 bg-base-100 p-4"] $ do
        p_ [class_ "mb-3"] "See the mosques closest to you, or search by name or area."
        button_
          [ type_ "button"
          , id_ "locate"
          , makeAttributes "hidden" ""
          , class_ "btn btn-primary w-full"
          ]
          "Show mosques near me"
        p_ [id_ "locate-status", role_ "status", class_ "mt-2 text-sm text-base-content/70"] ""
    forM_ origin $ \_ ->
      p_ [class_ "mb-4 text-sm text-base-content/70"] $ do
        "Showing the nearest mosques. "
        a_ [href_ "/mosques", class_ "link link-accent"] "Clear"
    form_ [method_ "get", action_ "/mosques", role_ "search", class_ "join mb-4 w-full"] $ do
      forM_ origin $ \here -> do
        input_ [type_ "hidden", name_ "lat", value_ (showDouble (coordsLat here))]
        input_ [type_ "hidden", name_ "lng", value_ (showDouble (coordsLng here))]
      input_
        [ type_ "search"
        , name_ "q"
        , value_ q
        , placeholder_ "Search by name or area"
        , makeAttributes "aria-label" "Search mosques"
        , class_ "input join-item w-full"
        ]
      button_ [type_ "submit", class_ "btn btn-primary join-item"] "Search"
    forM_ mapOrigin $ \here -> do
      link_ [rel_ "stylesheet", href_ maplibreCssPath]
      div_
        [ id_ "map"
        , makeAttributes "data-lat" (showDouble (coordsLat here))
        , makeAttributes "data-lng" (showDouble (coordsLng here))
        , class_ "mb-4 h-72 w-full overflow-hidden rounded-box border border-base-300 bg-base-100"
        ]
        ""
    case results of
      [] | blank         -> return ()
         | isJust origin -> p_ [class_ "text-base-content/70"] "No mosques found near you."
         | otherwise     -> p_ [class_ "text-base-content/70"] $ do
             "No mosques match \""
             toHtml q
             "\"."
      _ ->
        ul_ [class_ listClasses] $
          mapM_ item results
    when more $
      p_ [class_ "mt-4 text-sm text-base-content/70"]
        "There are more mosques. Refine your search to see them."
    p_ [class_ "mt-6 text-center text-sm text-base-content/70"] $ do
      "Can't find your mosque? "
      a_ [href_ "/mosques/new", class_ "link link-accent"] "Add it"
    when blank $
      script_ [] (toHtmlRaw locateScript)
    forM_ mapOrigin $ \_ -> do
      script_ [src_ maplibreJsPath] ("" :: Text)
      script_ [] (toHtmlRaw mapScript)
  where
    blank = T.null q && isNothing origin
    mapOrigin = if null results then Nothing else origin
    item (m, distance) =
      li_
        [ makeAttributes "data-mosque-lat" (showDouble (mosqueLat m))
        , makeAttributes "data-mosque-lng" (showDouble (mosqueLng m))
        , makeAttributes "data-mosque-name" (mosqueName m)
        , makeAttributes "data-mosque-url" (mosqueUrl (mosqueId m))
        ] $
        a_ [href_ (mosqueUrl (mosqueId m)), class_ "flex items-center gap-3 px-4 py-3 active:bg-base-200"] $ do
          div_ [class_ "min-w-0 flex-1"] $ do
            div_ [class_ "truncate font-semibold"] (toHtml (mosqueName m))
            div_ [class_ "truncate text-sm text-base-content/70"] $ do
              toHtml (mosqueAddress m)
              forM_ distance $ \d -> toHtml (" · " <> formatDistance d)
          chevron

-- Rounded to about 100 m before it leaves the phone; the server never stores it.
locateScript :: Text
locateScript =
  "(function () {\
  \  var button = document.getElementById('locate');\
  \  var status = document.getElementById('locate-status');\
  \  if (!button || !navigator.geolocation) return;\
  \  button.hidden = false;\
  \  button.addEventListener('click', function () {\
  \    button.disabled = true;\
  \    status.textContent = 'Finding your location...';\
  \    navigator.geolocation.getCurrentPosition(function (p) {\
  \      location.href = '/mosques?lat=' + p.coords.latitude.toFixed(3) + '&lng=' + p.coords.longitude.toFixed(3);\
  \    }, function () {\
  \      button.disabled = false;\
  \      status.textContent = 'Could not get your location. You can search by name or area instead.';\
  \    }, { timeout: 15000, maximumAge: 600000 });\
  \  });\
  \})();"

-- Pins come from the list's data attributes, so the map shows exactly what the list shows.
mapScript :: Text
mapScript =
  "(function () {\
  \  var el = document.getElementById('map');\
  \  if (!el || !window.maplibregl) return;\
  \  var here = [parseFloat(el.dataset.lng), parseFloat(el.dataset.lat)];\
  \  var map = new maplibregl.Map({ container: el, style: 'https://tiles.openfreemap.org/styles/liberty', center: here, zoom: 13 });\
  \  map.addControl(new maplibregl.NavigationControl({ showCompass: false }));\
  \  var bounds = new maplibregl.LngLatBounds(here, here);\
  \  new maplibregl.Marker({ color: '#2563eb' }).setLngLat(here).addTo(map);\
  \  var rows = document.querySelectorAll('[data-mosque-lat]');\
  \  for (var i = 0; i < rows.length; i++) {\
  \    var row = rows[i];\
  \    var at = [parseFloat(row.dataset.mosqueLng), parseFloat(row.dataset.mosqueLat)];\
  \    var link = document.createElement('a');\
  \    link.href = row.dataset.mosqueUrl;\
  \    link.textContent = row.dataset.mosqueName;\
  \    new maplibregl.Marker({ color: '#16a34a' }).setLngLat(at)\
  \      .setPopup(new maplibregl.Popup({ offset: 25 }).setDOMContent(link)).addTo(map);\
  \    bounds.extend(at);\
  \  }\
  \  map.fitBounds(bounds, { padding: 40, maxZoom: 15, duration: 0 });\
  \})();"

formatDistance :: Double -> Text
formatDistance meters
  | meters < 950  = showT (max 10 (10 * round (meters / 10))) <> " m"
  | meters < 9950 = showT (tenths `div` 10) <> "." <> showT (tenths `mod` 10) <> " km"
  | otherwise     = showT (round (meters / 1000)) <> " km"
  where
    tenths = round (meters / 100)
    showT :: Int -> Text
    showT = T.pack . show

showDouble :: Double -> Text
showDouble = T.pack . show

-- The timings table fits a 320 px screen: Urdu goes under the English, cells are
-- narrower on phones, and the box scrolls rather than cutting a column off.
-- The next prayer's row is highlighted and framed in gold, like the gold card above.
-- Edit appears only for those who may edit; everyone else is offered Report instead.
mosquePage
  :: Mosque
  -> [(Prayer, PrayerTime)]
  -> Maybe LocalTime
  -> Maybe NextJamaat
  -> Maybe Day
  -> Maybe FollowState
  -> Editing
  -> Html ()
mosquePage mosque timings now next updated followState editing =
  layout (mosqueName mosque <> " · Prayer times") NoTab band $ do
    forM_ next nextCard
    div_ [class_ "overflow-x-auto rounded-box border border-base-300 bg-base-100"] $
      table_ [class_ "table"] $ do
        thead_ $
          tr_ [class_ "text-base-content/70"] $ do
            th_ [class_ "px-2 sm:px-4"] (heading "Prayer" "نماز")
            th_ [class_ "px-2 sm:px-4"] (heading "Azan" "اذان")
            th_ [class_ "px-2 sm:px-4"] (heading "Jamaat" "جماعت")
        tbody_ $
          mapM_ row [minBound .. maxBound :: Prayer]
    forM_ updated $ \d ->
      p_ [class_ "mt-4 text-sm text-base-content/60"] (toHtml ("Updated " <> shortDate d))
    case editing of
      Reporter address ->
        p_ [class_ "mt-2 text-sm text-base-content/70"] $ do
          "Timings wrong or out of date? "
          a_ [href_ (reportLink address mosque), class_ "link link-accent"] "Report them"
      Maintainer ->
        p_ [class_ "mt-2 text-sm text-base-content/70"] "You maintain this mosque, so you can edit its timings."
      Superadmin maintainer problems ->
        maintainerPanel (mosqueId mosque) maintainer problems
    when (isJust next) countdownScript
  where
    band =
      div_ [class_ "flex items-start justify-between gap-3"] $ do
        div_ [class_ "min-w-0"] $ do
          h1_ [class_ "text-2xl font-semibold leading-tight"] (toHtml (mosqueName mosque))
          p_ [class_ "text-sm text-primary-content/75"] (toHtml (mosqueAddress mosque))
          forM_ now $ \t ->
            p_ [class_ "mt-2 text-sm text-secondary"] $ do
              toHtml (longDate (localDay t))
              forM_ (hijriParts (localDay t)) $ \parts -> do
                " · "
                hijriHtml parts
        div_ [class_ "flex shrink-0 flex-col items-end gap-2"] $ do
          forM_ followState (followButton (mosqueId mosque))
          case editing of
            Reporter _ -> return ()
            _ -> a_ [href_ (mosqueUrl (mosqueId mosque) <> "/edit"), class_ "btn btn-ghost btn-sm text-primary-content"] "Edit"
    nextPrayerOnly = njPrayer <$> next
    nextCard n =
      div_ [class_ "mb-4 rounded-box border-2 border-secondary bg-base-100 p-4 text-center"] $ do
        p_ [class_ "text-sm text-base-content/70"] $ do
          "Next: "
          strong_ [class_ "font-semibold text-base-content"] (toHtml (prayerLabel (njPrayer n) <> " Jamaat"))
          when (njTomorrow n) " tomorrow"
        p_ [class_ "text-xl"] (urdu "text-accent" (prayerUrdu (njPrayer n)))
        p_ [class_ "mt-1 text-5xl font-semibold tracking-tight tabular-nums text-primary dark:text-secondary"] $ do
          toHtml (clockDigits (njTime n))
          " "
          span_ [class_ "text-lg font-medium"] (toHtml (clockPeriod (njTime n)))
        p_ [class_ "mt-1 text-sm text-base-content/70"] (countdownSpan n)
    heading :: Text -> Text -> Html ()
    heading english urduText = do
      div_ (toHtml english)
      div_ (urdu "text-accent" urduText)
    row prayer =
      tr_ (if nextPrayerOnly == Just prayer then [class_ "bg-secondary/15 outline-2 -outline-offset-2 outline-secondary"] else []) $ do
        th_ [scope_ "row", class_ "px-2 font-semibold sm:px-4"] $ do
          div_ (toHtml (prayerLabel prayer))
          div_ (urdu "font-normal text-accent" (prayerUrdu prayer))
        case lookup prayer timings of
          Just t -> do
            td_ [class_ "whitespace-nowrap px-2 tabular-nums text-base-content/70 sm:px-4"] (clock (ptAzan t))
            td_ [class_ "whitespace-nowrap px-2 text-lg font-semibold tabular-nums sm:px-4"] (clock (ptJamaat t))
          Nothing ->
            td_ [colspan_ "2", class_ "px-2 text-base-content/60 sm:px-4"] "Not set"

-- Only the superadmin sees this: who maintains the mosque, to remove them, or a field to choose someone.
maintainerPanel :: MosqueId -> Maybe Text -> [Text] -> Html ()
maintainerPanel mid maintainer problems =
  div_ [class_ "mt-6 rounded-box border border-base-300 bg-base-100 p-4"] $ do
    h2_ [class_ "mb-2 font-semibold"] "Maintainer"
    errorList problems
    case maintainer of
      Just email ->
        div_ [class_ "flex items-center justify-between gap-3"] $ do
          span_ [class_ "min-w-0 break-all"] (toHtml email)
          form_ [method_ "post", action_ (url <> "/maintainer/remove")] $
            button_ [type_ "submit", class_ "btn btn-outline btn-sm"] "Remove"
      Nothing -> do
        p_ [class_ "mb-2 text-sm text-base-content/70"] "None, so only you can edit this mosque."
        form_ [method_ "post", action_ (url <> "/maintainer"), class_ "join w-full"] $ do
          input_
            [ type_ "email"
            , name_ "email"
            , required_ ""
            , placeholder_ "Their email, as they sign in"
            , makeAttributes "aria-label" "Maintainer's email"
            , class_ "input join-item w-full"
            ]
          button_ [type_ "submit", class_ "btn btn-primary join-item"] "Assign"
    p_ [class_ "mt-2 text-xs text-base-content/60"] "Only you see this."
  where
    url = mosqueUrl mid

followButton :: MosqueId -> FollowState -> Html ()
followButton mid state = case state of
  SignedOut ->
    a_ [href_ (signInUrl url), class_ "btn btn-secondary btn-sm"] "Follow"
  NotFollowing ->
    form_ [method_ "post", action_ (url <> "/follow")] $
      button_ [type_ "submit", class_ "btn btn-secondary btn-sm"] "Follow"
  Following ->
    form_ [method_ "post", action_ (url <> "/unfollow")] $
      button_
        [ type_ "submit"
        , class_ "btn btn-outline btn-secondary btn-sm"
        , makeAttributes "aria-label" "Unfollow"
        ]
        "Following"
  where
    url = mosqueUrl mid

errorList :: [Text] -> Html ()
errorList errors =
  unless (null errors) $
    div_ [role_ "alert", class_ "alert alert-error mb-4"] $
      ul_ [class_ "list-disc pl-4"] (mapM_ (li_ . toHtml) errors)

-- For someone signed in who may not edit the mosque.
notAllowedPage :: Mosque -> Html ()
notAllowedPage m =
  layout ("Edit " <> mosqueName m <> " · Hilal") NoTab (bandTitle ("Edit " <> mosqueName m)) $ do
    p_ [class_ "mb-4 text-base-content/70"] $ do
      "Only Hilal's superadmin and this mosque's maintainer can change its timings. "
      "If they're wrong or out of date, please report them from the mosque's page."
    a_ [href_ (mosqueUrl (mosqueId m)), class_ "btn btn-primary"] "Back to the mosque"

-- Adding starts with the mosque's Google Maps link, which gives its name and location.
addLinkPage :: Text -> [Text] -> Maybe MosqueId -> Html ()
addLinkPage pasted errors existing =
  layout "Add a mosque · Hilal" NoTab (bandTitle "Add a mosque") $ do
    errorList errors
    forM_ existing $ \mid ->
      div_ [role_ "alert", class_ "alert alert-warning mb-4"] $
        span_ $ do
          "This mosque is already on Hilal. "
          a_ [href_ (mosqueUrl mid), class_ "link font-semibold"] "See it"
    form_ [method_ "post", action_ "/mosques/new/link", class_ "flex flex-col gap-4 rounded-box border border-base-300 bg-base-100 p-4"] $ do
      fieldset_ [class_ "fieldset"] $ do
        label_ [for_ "location", class_ "fieldset-legend"] "Google Maps link"
        input_
          [ type_ "text"
          , id_ "location"
          , name_ "location"
          , value_ pasted
          , required_ ""
          , autocomplete_ "off"
          , placeholder_ "https://maps.app.goo.gl/..."
          , class_ "input w-full"
          ]
        p_ [class_ "label whitespace-normal"]
          "In Google Maps, open the mosque, tap Share, and paste the link here. Its name and location come from Google Maps."
      button_ [type_ "submit", class_ "btn btn-primary"] "Continue"

-- The name is shown, not typed: it always comes from Google Maps.
-- Adding carries the place's link along, and guesses the time zone on first showing;
-- editing does neither, because a mosque's location doesn't change.
mosqueFormPage :: Text -> Text -> [Text] -> MosqueForm -> [Prayer] -> Bool -> Html ()
mosqueFormPage title action errors form upcoming adding =
  layout (title <> " · Hilal") NoTab (bandTitle title) $ do
    errorList errors
    form_ [method_ "post", action_ action, class_ "flex flex-col gap-4"] $ do
      when adding $ do
        input_ [type_ "hidden", name_ "location", value_ (formLocation form)]
        input_ [type_ "hidden", id_ "lat", name_ "lat", value_ (formLat form)]
        input_ [type_ "hidden", id_ "lng", name_ "lng", value_ (formLng form)]
      div_ [class_ "rounded-box border border-base-300 bg-base-100 p-4"] $ do
        fieldset_ [class_ "fieldset"] $ do
          span_ [class_ "fieldset-legend"] "Name"
          p_ [class_ "text-base font-semibold"] (toHtml (formName form))
          p_ [class_ "label whitespace-normal"] "As named on Google Maps."
        when (adding && not needsPin) $
          fieldset_ [class_ "fieldset"] $ do
            span_ [class_ "fieldset-legend"] "Location"
            p_ [class_ "text-base"] "Found."
        when needsPin $
          fieldset_ [class_ "fieldset"] $ do
            span_ [class_ "fieldset-legend"] "Location"
            p_ [class_ "label whitespace-normal"]
              "Hilal couldn't work out where this mosque is. Zoom in and tap it on the map; you can drag the pin to adjust it."
            link_ [rel_ "stylesheet", href_ maplibreCssPath]
            div_ [id_ "pin-map", class_ "h-72 w-full overflow-hidden rounded-box border border-base-300"] ""
            p_ [id_ "pin-status", role_ "status", class_ "label whitespace-normal"] ""
            noscript_ $
              p_ [class_ "text-sm text-warning"] "Placing the pin needs JavaScript, which is turned off."
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
      div_ [class_ "rounded-box border border-base-300 bg-base-100 p-4"] $ do
        div_ [class_ "mb-2 grid grid-cols-[5.5rem_1fr_1fr] gap-2 text-sm text-base-content/70"] $ do
          span_ "Prayer"
          span_ $ do
            "Azan "
            urdu "text-accent" "اذان"
          span_ $ do
            "Jamaat "
            urdu "text-accent" "جماعت"
        mapM_ prayerRow (formTimes form)
      when adding $
        p_ [class_ "text-sm text-base-content/70"]
          "Once it's added, only Hilal's superadmin, or a maintainer they choose, can change this mosque, so please check the timings before saving."
      button_ [type_ "submit", class_ "btn btn-primary"] "Save"
    when (adding && null errors) $
      script_ [] (toHtmlRaw timezoneScript)
    when needsPin $ do
      script_ [src_ maplibreJsPath] ("" :: Text)
      script_ [] (toHtmlRaw pinScript)
  where
    -- Only when the link didn't give the location does the person place it on a map.
    needsPin = adding && (T.null (formLat form) || T.null (formLng form))
    zones
      | formTimezone form `elem` zoneNames = zoneNames
      | otherwise                          = formTimezone form : zoneNames
    zoneOption z =
      option_ ([value_ z] <> (if z == formTimezone form then [selected_ ""] else [])) (toHtml z)
    prayerRow (p, (azan, jamaat)) = do
      div_ [class_ "grid grid-cols-[5.5rem_1fr_1fr] items-center gap-2 py-1"] $ do
        div_ $ do
          div_ [class_ "font-semibold"] (toHtml (prayerLabel p))
          div_ [class_ "text-sm"] (urdu "text-accent" (prayerUrdu p))
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

-- The pin goes where the mosque is tapped, and can be dragged; its coordinates fill the hidden fields.
-- The map starts at a pin already placed, or else at the phone's location, which stays on the phone;
-- failing both, it shows all of India.
pinScript :: Text
pinScript =
  "(function () {\
  \  var el = document.getElementById('pin-map');\
  \  var lat = document.getElementById('lat'), lng = document.getElementById('lng');\
  \  var status = document.getElementById('pin-status');\
  \  if (!el || !lat || !lng || !window.maplibregl) return;\
  \  var map = new maplibregl.Map({ container: el, style: 'https://tiles.openfreemap.org/styles/liberty', center: [78.96, 22.59], zoom: 4 });\
  \  map.addControl(new maplibregl.NavigationControl({ showCompass: false }));\
  \  var marker = null;\
  \  function record(ll) {\
  \    lat.value = ll.lat.toFixed(6);\
  \    lng.value = ll.lng.toFixed(6);\
  \    status.textContent = 'Pin placed. Drag it, or tap elsewhere, to move it.';\
  \  }\
  \  function place(ll) {\
  \    if (!marker) {\
  \      marker = new maplibregl.Marker({ color: '#16a34a', draggable: true }).setLngLat(ll).addTo(map);\
  \      marker.on('dragend', function () { record(marker.getLngLat()); });\
  \    } else {\
  \      marker.setLngLat(ll);\
  \    }\
  \    record(marker.getLngLat());\
  \  }\
  \  map.on('click', function (e) { place(e.lngLat); });\
  \  if (lat.value && lng.value) {\
  \    var start = [parseFloat(lng.value), parseFloat(lat.value)];\
  \    map.jumpTo({ center: start, zoom: 17 });\
  \    place(start);\
  \  } else if (navigator.geolocation) {\
  \    navigator.geolocation.getCurrentPosition(function (p) {\
  \      if (!marker) map.jumpTo({ center: [p.coords.longitude, p.coords.latitude], zoom: 16 });\
  \    }, function () {}, { timeout: 15000, maximumAge: 600000 });\
  \  }\
  \})();"

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

-- AM/PM is set small, so the digits carry the time and narrow columns stay narrow.
clock :: TimeOfDay -> Html ()
clock t = do
  toHtml (clockDigits t)
  " "
  span_ [class_ "text-[0.625rem] font-normal text-base-content/60"] (toHtml (clockPeriod t))

clockDigits :: TimeOfDay -> Text
clockDigits = T.pack . formatTime defaultTimeLocale "%-I:%M"

clockPeriod :: TimeOfDay -> Text
clockPeriod = T.pack . formatTime defaultTimeLocale "%p"
