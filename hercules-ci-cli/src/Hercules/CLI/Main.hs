{-# LANGUAGE BlockArguments #-}

module Hercules.CLI.Main
  ( main,
  )
where

import Hercules.CLI.Client (prettyPrintHttpErrors)
import qualified Hercules.CLI.Effect as Effect
import qualified Hercules.CLI.Exception as Exception
import qualified Hercules.CLI.Lock as Lock
import qualified Hercules.CLI.Login as Login
import Hercules.CLI.Options (execParser, helper, mkCommand, subparser)
import qualified Hercules.CLI.Secret as Secret
import qualified Hercules.CLI.State as State
import qualified Hercules.CNix.Exception
import Hercules.CNix.Verbosity (setShowTrace)
import qualified Options.Applicative as Optparse
import Protolude

main :: IO ()
main =
  prettyPrintErrors $
    Exception.handleUserException $
      prettyPrintHttpErrors $ do
        join $ execParser opts

prettyPrintErrors :: IO a -> IO a
prettyPrintErrors = handleHaskell . Hercules.CNix.Exception.handleExceptions
  where
    handleHaskell = handle \e ->
      case fromException e :: Maybe ExitCode of
        Just _ -> throwIO e
        Nothing -> do
          putErrLn $ "hci: " <> displayException e
          exitFailure

opts :: Optparse.ParserInfo (IO ())
opts =
  Optparse.info
    (commands <**> helper)
    (Optparse.fullDesc <> Optparse.header "Command line interface to Hercules CI")

setCommonOpts :: Optparse.Parser (IO ())
setCommonOpts =
  Optparse.flag pass (setShowTrace True) (Optparse.long "show-trace")

commands :: Optparse.Parser (IO ())
commands =
  (*>)
    <$> setCommonOpts
    <*> subparser
      ( mkCommand
          "login"
          (Optparse.progDesc "Configure token for authentication to hercules-ci.com")
          Login.commandParser
          <> mkCommand
            "state"
            (Optparse.progDesc "Perform operations on state files")
            State.commandParser
          <> mkCommand
            "effect"
            (Optparse.progDesc "Run effects locally")
            Effect.commandParser
          <> mkCommand
            "secret"
            (Optparse.progDesc "Manipulate locally stored secrets")
            Secret.commandParser
          <> mkCommand
            "lock"
            (Optparse.progDesc "Opt-in locking for use with state")
            Lock.commandParser
      )
