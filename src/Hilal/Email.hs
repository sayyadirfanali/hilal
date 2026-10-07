module Hilal.Email (newMailer) where

import Control.Monad (unless)
import Data.Aeson (Value, encode, object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Client
  ( Manager
  , RequestBody (RequestBodyLBS)
  , httpNoBody
  , parseRequest
  , requestBody
  , requestHeaders
  , responseStatus
  , responseTimeout
  , responseTimeoutMicro
  )
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)

-- Sends sign-in codes through Brevo's HTTPS API, with the given API key and sender address.
-- Throws when Brevo doesn't accept the email; callers must not log the exception,
-- because a network error carries the request, and so the key and the address.
newMailer :: Text -> Text -> IO (Text -> Text -> IO ())
newMailer apiKey from = sendWith apiKey from <$> newTlsManager

sendWith :: Text -> Text -> Manager -> Text -> Text -> IO ()
sendWith apiKey from manager to code = do
  request <- parseRequest "POST https://api.brevo.com/v3/smtp/email"
  response <- httpNoBody
    request
      { requestHeaders =
          [ ("api-key", encodeUtf8 apiKey)
          , ("content-type", "application/json")
          , ("accept", "application/json")
          ]
      , requestBody = RequestBodyLBS (encode (codeEmail from to code))
      , responseTimeout = responseTimeoutMicro 10000000
      }
    manager
  let status = statusCode (responseStatus response)
  unless (status >= 200 && status < 300) $
    ioError (userError ("Brevo refused the email with status " <> show status))

-- The code is in the subject too, so it can be read from the phone's notification.
codeEmail :: Text -> Text -> Text -> Value
codeEmail from to code =
  object
    [ "sender" .= object ["name" .= ("Hilal" :: Text), "email" .= from]
    , "to" .= [object ["email" .= to]]
    , "subject" .= ("Your Hilal sign-in code: " <> code)
    , "textContent" .= T.unlines
        [ "Your Hilal sign-in code is " <> code <> "."
        , ""
        , "It expires in 10 minutes and works once."
        , ""
        , "If you didn't ask for it, you can ignore this email: nobody can sign in without the code."
        ]
    ]
