module Main (main) where

import Network.Wai.Handler.Warp
import Hilal.App
import Hilal.DB
import Hilal.Migrate

main :: IO ()
main = do
  withDb "hilal.db" migrate
  application <- app "./hilal.db"
  putStrLn "hilal listening on http://localhost:8080"
  run 8080 application