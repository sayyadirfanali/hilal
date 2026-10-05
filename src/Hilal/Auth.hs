module Hilal.Auth
  ( CodeCheck (..)
  , checkCode
  , canResend
  , codeLifetime
  , sessionLifetime
  , newCode
  , newToken
  , sha256
  , normaliseEmail
  , sessionCookie
  , clearSessionCookie
  , sessionToken
  , sameOrigin
  , safeNext
  ) where

import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Char (isSpace)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import Numeric (showHex)
import Web.Cookie (SetCookie (..), defaultSetCookie, parseCookiesText, renderSetCookie, sameSiteLax)

import Hilal.Types (SignInCode (..))

data CodeCheck = CodeOk | CodeWrong | CodeExpired | CodeLocked
  deriving (Show, Eq)

codeLifetime :: NominalDiffTime
codeLifetime = 10 * 60

resendDelay :: NominalDiffTime
resendDelay = 60

sessionLifetime :: NominalDiffTime
sessionLifetime = 365 * 24 * 60 * 60

maxAttempts :: Int
maxAttempts = 5

checkCode :: UTCTime -> Text -> SignInCode -> CodeCheck
checkCode now code stored
  | now >= codeExpiresAt stored          = CodeExpired
  | codeAttempts stored >= maxAttempts   = CodeLocked
  | sha256 code == codeHash stored       = CodeOk
  | otherwise                            = CodeWrong

canResend :: UTCTime -> SignInCode -> Bool
canResend now stored = diffUTCTime now (codeCreatedAt stored) >= resendDelay

newCode :: IO Text
newCode = do
  bytes <- getRandomBytes 4 :: IO ByteString
  let n = BS.foldl' (\acc w -> acc * 256 + fromIntegral w) (0 :: Int) bytes `mod` 1000000
  return (T.justifyRight 6 '0' (T.pack (show n)))

newToken :: IO Text
newToken = do
  bytes <- getRandomBytes 32 :: IO ByteString
  return (toHex bytes)

sha256 :: Text -> Text
sha256 t = T.pack (show (hash (encodeUtf8 t) :: Digest SHA256))

toHex :: ByteString -> Text
toHex = T.pack . concatMap byte . BS.unpack
  where
    byte w = case showHex w "" of
      [d] -> ['0', d]
      ds  -> ds

normaliseEmail :: Text -> Maybe Text
normaliseEmail input
  | T.length email >= 3
  , T.length email <= 254
  , "@" `T.isInfixOf` email
  , not (T.any isSpace email)
  = Just email
  | otherwise = Nothing
  where
    email = T.toLower (T.strip input)

cookieName :: ByteString
cookieName = "hilal_session"

sessionCookie :: Bool -> Text -> ByteString
sessionCookie secure token =
  renderCookie defaultSetCookie
    { setCookieName     = cookieName
    , setCookieValue    = encodeUtf8 token
    , setCookiePath     = Just "/"
    , setCookieMaxAge   = Just (realToFrac sessionLifetime)
    , setCookieHttpOnly = True
    , setCookieSecure   = secure
    , setCookieSameSite = Just sameSiteLax
    }

clearSessionCookie :: Bool -> ByteString
clearSessionCookie secure =
  renderCookie defaultSetCookie
    { setCookieName     = cookieName
    , setCookieValue    = ""
    , setCookiePath     = Just "/"
    , setCookieMaxAge   = Just 0
    , setCookieHttpOnly = True
    , setCookieSecure   = secure
    , setCookieSameSite = Just sameSiteLax
    }

renderCookie :: SetCookie -> ByteString
renderCookie = BL.toStrict . toLazyByteString . renderSetCookie

sessionToken :: ByteString -> Maybe Text
sessionToken = lookup "hilal_session" . parseCookiesText

sameOrigin :: Maybe Text -> Maybe Text -> Bool
sameOrigin Nothing _ = True
sameOrigin (Just origin) host = Just (snd (T.breakOnEnd "://" origin)) == host

safeNext :: Text -> Text
safeNext next
  | "/" `T.isPrefixOf` next
  , not ("//" `T.isPrefixOf` next)
  , not ("/\\" `T.isPrefixOf` next)
  , T.all (\c -> c > ' ' && c /= '\DEL') next
  = next
  | otherwise = "/mosques"
