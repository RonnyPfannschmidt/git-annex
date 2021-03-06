{- git-annex command
 -
 - Copyright 2010 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.Version where

import Command
import Annex.Version
import BuildInfo
import BuildFlags
import Types.Key
import qualified Types.Backend as B
import qualified Types.Remote as R
import qualified Remote
import qualified Backend

import System.Info

cmd :: Command
cmd = dontCheck repoExists $ noCommit $ 
	noRepo (seekNoRepo <$$> optParser) $ 
		command "version" SectionQuery "show version info"
			paramNothing (seek <$$> optParser)

data VersionOptions = VersionOptions
	{ rawOption :: Bool
	}

optParser :: CmdParamsDesc -> Parser VersionOptions
optParser _ = VersionOptions
	<$> switch
		( long "raw"
		<> help "output only program version"
		)

seek :: VersionOptions -> CommandSeek
seek o
	| rawOption o = liftIO showRawVersion
	| otherwise = showVersion

seekNoRepo :: VersionOptions -> IO ()
seekNoRepo o
	| rawOption o = showRawVersion
	| otherwise = showPackageVersion

showVersion :: Annex ()
showVersion = do
	liftIO showPackageVersion
	maybe noop (liftIO . vinfo "local repository version")
		=<< getVersion

showPackageVersion :: IO ()
showPackageVersion = do
	vinfo "git-annex version" BuildInfo.packageversion
	vinfo "build flags" $ unwords buildFlags
	vinfo "dependency versions" $ unwords dependencyVersions
	vinfo "key/value backends" $ unwords $
		map (formatKeyVariety . B.backendVariety) Backend.list
	vinfo "remote types" $ unwords $ map R.typename Remote.remoteTypes
	vinfo "operating system" $ unwords [os, arch]
	vinfo "supported repository versions" $
		unwords supportedVersions
	vinfo "upgrade supported from repository versions" $
		unwords upgradableVersions

showRawVersion :: IO ()
showRawVersion = do
	putStr BuildInfo.packageversion
	hFlush stdout -- no newline, so flush

vinfo :: String -> String -> IO ()
vinfo k v = putStrLn $ k ++ ": " ++ v
