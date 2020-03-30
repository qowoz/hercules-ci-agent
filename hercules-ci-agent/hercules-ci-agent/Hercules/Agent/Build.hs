module Hercules.Agent.Build where

import Data.Char (isSpace)
import qualified Data.Conduit.Combinators as Conduit
import Data.Conduit.Process (sourceProcessWithStreams)
import Data.IORef.Lifted
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Hercules.API.Agent.Build as API.Build
import qualified Hercules.API.Agent.Build.BuildEvent as BuildEvent
import qualified Hercules.API.Agent.Build.BuildEvent.OutputInfo as OutputInfo
import Hercules.API.Agent.Build.BuildEvent.OutputInfo
  ( OutputInfo,
  )
import qualified Hercules.API.Agent.Build.BuildEvent.Pushed as Pushed
import qualified Hercules.API.Agent.Build.BuildTask as BuildTask
import Hercules.API.Agent.Build.BuildTask
  ( BuildTask,
  )
import qualified Hercules.API.Agent.Evaluate.EvaluateEvent.DerivationInfo as DerivationInfo
import qualified Hercules.API.Logs as API.Logs
import Hercules.API.Servant (noContent)
import Hercules.API.TaskStatus (TaskStatus)
import qualified Hercules.API.TaskStatus as TaskStatus
import qualified Hercules.Agent.Cachix as Agent.Cachix
import qualified Hercules.Agent.Client
import qualified Hercules.Agent.Config as Config
import Hercules.Agent.Env
import qualified Hercules.Agent.Env as Env
import Hercules.Agent.Log
import qualified Hercules.Agent.Nix as Nix
import Hercules.Agent.Nix.RetrieveDerivationInfo
  ( retrieveDerivationInfo,
  )
import Hercules.Agent.WorkerProcess
import qualified Hercules.Agent.WorkerProtocol.Command as Command
import qualified Hercules.Agent.WorkerProtocol.Command.Build as Command.Build
import qualified Hercules.Agent.WorkerProtocol.Event as Event
import qualified Hercules.Agent.WorkerProtocol.LogSettings as LogSettings
import Hercules.Error (defaultRetry)
import Protolude
import Servant.Auth.Client
import System.Process

performBuild :: BuildTask.BuildTask -> App TaskStatus
performBuild buildTask = do
  workerExe <- getWorkerExe
  commandChan <- liftIO newChan
  statusRef <- newIORef Nothing
  let opts = [show $ extraNixOptions]
      extraNixOptions :: [(Text, Text)]
      extraNixOptions = []
      procSpec =
        (System.Process.proc workerExe opts)
          { env = Just [("NIX_PATH", "")],
            close_fds = True,
            cwd = Just "/"
          }
      writeEvent :: Event.Event -> App ()
      writeEvent event = case event of
        Event.BuildResult r -> writeIORef statusRef $ Just r
        Event.Exception e -> do
          logLocM DebugS $ show e
          panic e
        _ -> pass
  bulkSocketHost <- asks (Config.bulkSocketBase . Env.config)
  liftIO $ writeChan commandChan $ Just $ Command.Build $ Command.Build.Build
    { drvPath = BuildTask.derivationPath buildTask,
      inputDerivationOutputPaths = toS <$> BuildTask.inputDerivationOutputPaths buildTask,
      logSettings = LogSettings.LogSettings
        { token = LogSettings.Sensitive $ BuildTask.logToken buildTask,
          path = "/api/v1/logs/build/socket",
          host = bulkSocketHost
        }
    }
  exitCode <- runWorker procSpec stderrLineHandler commandChan writeEvent
  logLocM DebugS $ "Worker exit: " <> show exitCode
  case exitCode of
    ExitSuccess -> pass
    _ -> panic $ "Worker failed: " <> show exitCode
  status <- readIORef statusRef
  let result = case status of
        Just True -> TaskStatus.Successful ()
        Just False -> TaskStatus.Terminated ()
        Nothing -> TaskStatus.Exceptional "Build did not complete"
  case result of
    s@TaskStatus.Successful {} -> s <$ do
      outs <- getOutputPathInfos buildTask
      reportOutputInfos buildTask outs
      push buildTask outs
      reportSuccess buildTask
    x -> pure x

stderrLineHandler :: Int -> ByteString -> App ()
stderrLineHandler pid ln =
  withNamedContext "worker" (pid :: Int)
    $ logLocM InfoS
    $ "Builder: "
      <> logStr (toSL ln :: Text)

realise :: BuildTask.BuildTask -> App TaskStatus
realise buildTask = do
  let stdinc = pass
      stdoutc = pass -- FIXME: use
      stderrc = Conduit.fold
  nixStoreProc <-
    Nix.nixProc
      "nix-store"
      [ "--realise",
        "--timeout",
        "36000", -- 10h TODO: make configurable via meta.timeout and decrease default to 3600s or so
        "--max-silent-time",
        "1800" -- 0.5h TODO: make configurable via (?) and decrease default to 600s
      ]
      [ BuildTask.derivationPath buildTask
      ]
  let procSpec =
        nixStoreProc
          { close_fds = True, -- Disable on Windows?
            cwd = Just "/"
          }
  logLocM DebugS $ "Building: " <> show (System.Process.cmdspec procSpec)
  (status, _out, errBytes) <-
    liftIO $
      sourceProcessWithStreams procSpec stdinc stdoutc stderrc
  noContent $ defaultRetry $ runHerculesClient' $
    API.Logs.writeLog
      Hercules.Agent.Client.logsClient
      (Token $ toSL $ BuildTask.logToken buildTask)
      errBytes
  case status of
    ExitFailure e -> do
      withNamedContext "exitStatus" e $ logLocM ErrorS "Building failed"
      emitEvents buildTask [BuildEvent.Done False]
      pure $ TaskStatus.Terminated ()
    ExitSuccess -> TaskStatus.Successful () <$ logLocM DebugS "Building succeeded"

getOutputPathInfos :: BuildTask -> App (Map Text OutputInfo)
getOutputPathInfos buildTask = do
  let drvPath = BuildTask.derivationPath buildTask
  drvInfo <- retrieveDerivationInfo drvPath
  flip M.traverseWithKey (DerivationInfo.outputs drvInfo) $ \outputName o -> do
    let outputPath = DerivationInfo.path o
    sizeStr <- Nix.readNixProcess "nix-store" ["--query", "--size"] [toS outputPath] ""
    size <-
      case reads (toS $ T.dropAround isSpace $ toS sizeStr) of
        [(x, "")] -> pure x
        _ ->
          throwIO
            $ FatalError
            $ "nix-store returned invalid size "
              <> show sizeStr
    hashStr <- Nix.readNixProcess "nix-store" ["--query", "--hash"] [toS outputPath] ""
    let h = T.dropAround isSpace (toS hashStr)
    pure OutputInfo.OutputInfo
      { OutputInfo.deriver = drvPath,
        name = outputName,
        path = outputPath,
        size = size,
        hash = h
      }

push :: BuildTask -> Map Text OutputInfo -> App ()
push buildTask outs = do
  let paths = OutputInfo.path <$> toList outs
  caches <- Agent.Cachix.activePushCaches
  forM_ caches $ \cache -> do
    Agent.Cachix.push cache paths 4
    emitEvents buildTask [BuildEvent.Pushed $ Pushed.Pushed {cache = cache}]

reportSuccess :: BuildTask -> App ()
reportSuccess buildTask = emitEvents buildTask [BuildEvent.Done True]

reportOutputInfos :: BuildTask -> Map Text OutputInfo -> App ()
reportOutputInfos buildTask outs =
  emitEvents buildTask $ map BuildEvent.OutputInfo (toList outs)

emitEvents :: BuildTask -> [BuildEvent.BuildEvent] -> App ()
emitEvents buildTask =
  noContent . defaultRetry . runHerculesClient
    . API.Build.updateBuild
      Hercules.Agent.Client.buildClient
      (BuildTask.id buildTask)
