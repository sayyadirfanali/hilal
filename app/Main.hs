module Main (main) where

import Control.Monad (when)
import Data.Char (isDigit)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Network.Wai.Handler.Warp (run)
import System.Environment (lookupEnv)
import System.Exit (die)

import Hilal.App (Config (..), app)
import Hilal.DB (withDb)
import Hilal.Email (newMailer)
import Hilal.Location (newLinkResolver)
import Hilal.Migrate (migrate)

main :: IO ()
main = do
  env <- lookupEnv "HILAL_ENV"
  demoCode <- lookupEnv "HILAL_DEMO_CODE"
  let production = env == Just "production"
  when (production && isJust demoCode) $
    die "HILAL_DEMO_CODE must not be set when HILAL_ENV=production."
  case demoCode of
    Just code
      | length code /= 6 || not (all isDigit code) ->
          die "HILAL_DEMO_CODE must be six digits."
      | otherwise ->
          putStrLn ("demo mode: every sign-in code is " <> code)
    Nothing -> return ()
  sendCode <- codeSender production
  resolveLink <- newLinkResolver
  withDb dbPath migrate
  application <- app Config
    { configDb            = dbPath
    , configSecureCookies = production
    , configSuperadmin    = "irfan@irfanali.org"
    , configSendCode      = sendCode
    , configLogEdit       = \line ->
        TIO.appendFile "edits.log" (line <> "\n")
    , configDemoCode      = T.pack <$> demoCode
    , configResolveLink   = resolveLink
    }
  putStrLn "hilal listening on http://localhost:8080"
  run 8080 application
  where
    dbPath = "hilal.db"

-- Codes are emailed when Brevo is configured, which production requires;
-- otherwise, in development, they are printed to the terminal.
codeSender :: Bool -> IO (Text -> Text -> IO ())
codeSender production = do
  apiKey <- lookupEnv "BREVO_API_KEY"
  from   <- lookupEnv "HILAL_MAIL_FROM"
  case (apiKey, from) of
    (Just key, Just address) -> do
      putStrLn ("sign-in codes are emailed from " <> address)
      newMailer (T.pack key) (T.pack address)
    _ | production ->
          die "BREVO_API_KEY and HILAL_MAIL_FROM must be set when HILAL_ENV=production."
      | otherwise ->
          return (\email code -> TIO.putStrLn ("sign-in code for " <> email <> ": " <> code))
