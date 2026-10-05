module Main (main) where

import Data.Text.IO qualified as TIO
import Network.Wai.Handler.Warp (run)
import System.Environment (lookupEnv)

import Hilal.App (Config (..), app)
import Hilal.DB (withDb)
import Hilal.Migrate (migrate)

main :: IO ()
main = do
  env <- lookupEnv "HILAL_ENV"
  withDb dbPath migrate
  application <- app Config
    { configDb            = dbPath
    , configSecureCookies = env == Just "production"
    , configSuperadmin    = "you@example.com"
    , configSendCode      = \email code ->
        TIO.putStrLn ("sign-in code for " <> email <> ": " <> code)
    , configLogEdit       = \line ->
        TIO.appendFile "edits.log" (line <> "\n")
    }
  putStrLn "hilal listening on http://localhost:8080"
  run 8080 application
  where
    dbPath = "hilal.db"
