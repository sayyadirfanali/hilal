module Main (main) where

import Network.Wai.Handler.Warp (run)
import Hilal.App (app)
import Hilal.DB (withDb)
import Hilal.Migrate (migrate)

main :: IO ()
main = do
  withDb "hilal.db" migrate
  application <- app
  putStrLn "hilal listening on http://localhost:8080"
  run 8080 application