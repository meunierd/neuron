{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Neuron.CLI.App
  ( run,
  )
where

import Colog
import Control.Concurrent.Async (race_)
import qualified Data.Aeson.Text as Aeson
import Data.Some (withSome)
import Data.Tagged
import qualified Data.Text as T
import Data.Time
  ( getCurrentTime,
    getCurrentTimeZone,
    utcToLocalTime,
  )
import qualified Neuron.Backend as Backend
import Neuron.CLI.New (newZettelFile)
import Neuron.CLI.Open (openLocallyGeneratedFile)
import Neuron.CLI.Parser
import Neuron.CLI.Search (interactiveSearch)
import Neuron.CLI.Types
import qualified Neuron.Cache as Cache
import qualified Neuron.Cache.Type as Cache
import Neuron.Config (getConfig)
import qualified Neuron.Reactor as Reactor
import qualified Neuron.Version as Version
import qualified Neuron.Zettelkasten.Graph as G
import qualified Neuron.Zettelkasten.Query as Q
import Neuron.Zettelkasten.Zettel (sansLinkContext)
import Options.Applicative
import Relude
import System.Console.ANSI
  ( Color (..),
    ColorIntensity (Vivid),
    ConsoleLayer (Foreground),
    SGR (..),
    setSGRCode,
  )
import System.Directory (getCurrentDirectory)

run :: (Bool -> AppT ()) -> IO ()
run act = do
  defaultNotesDir <- getCurrentDirectory
  cliParser <- commandParser defaultNotesDir <$> now
  app <-
    execParser $
      info
        (versionOption <*> cliParser <**> helper)
        (fullDesc <> progDesc "Neuron, future-proof Zettelkasten app <https://neuron.zettel.page/>")
  let logAction = cmap fmtNeuronMsg logTextStdout
  runAppT (Env app logAction) $ runAppCommand act
  where
    versionOption =
      infoOption
        (toString $ untag Version.neuronVersion)
        (long "version" <> help "Show version")
    now = do
      tz <- getCurrentTimeZone
      utcToLocalTime tz <$> liftIO getCurrentTime
    fmtNeuronMsg :: Message -> Text
    fmtNeuronMsg Msg {..} =
      let sev = case msgSeverity of
            Debug -> color Green "[D] "
            Info -> color Blue "[I] "
            Warning -> color Yellow "[W] "
            Error -> color Red "[E] "
       in sev
            <> msgText
    color :: Color -> Text -> Text
    color c txt =
      T.pack (setSGRCode [SetColor Foreground Vivid c])
        <> txt
        <> T.pack (setSGRCode [Reset])

runAppCommand :: (Bool -> AppT ()) -> AppT ()
runAppCommand genAct = do
  c <- cmd <$> getApp
  case c of
    Gen GenCommand {..} -> do
      case serve of
        Just (host, port) -> do
          outDir <- getOutputDir
          appEnv <- getAppEnv
          liftIO $
            race_ (runAppT appEnv $ genAct watch) $ do
              runAppT appEnv $ Backend.serve host port outDir
        Nothing ->
          genAct watch
    New newCommand ->
      newZettelFile newCommand =<< getConfig
    Open openCommand ->
      openLocallyGeneratedFile openCommand
    Query QueryCommand {..} -> do
      Cache.NeuronCache {..} <-
        if cached
          then Cache.getCache
          else do
            (ch, _, _) <- Reactor.loadZettelkasten =<< getConfig
            pure ch
      case query of
        Left someQ ->
          withSome someQ $ \q -> do
            let zsSmall = sansLinkContext <$> G.getZettels _neuronCache_graph
                result = Q.runZettelQuery zsSmall q
            putLTextLn $ Aeson.encodeToLazyText $ Q.zettelQueryResultJson q result _neuronCache_errors
        Right someQ ->
          withSome someQ $ \q -> do
            let result = Q.runGraphQuery _neuronCache_graph q
            putLTextLn $ Aeson.encodeToLazyText $ Q.graphQueryResultJson q result _neuronCache_errors
    Search searchCmd -> do
      interactiveSearch searchCmd
