{- git-annex remotes types
 -
 - Most things should not need this, using Types instead
 -
 - Copyright 2011-2018 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE RankNTypes #-}

module Types.Remote
	( RemoteConfigKey
	, RemoteConfig
	, RemoteTypeA(..)
	, RemoteA(..)
	, SetupStage(..)
	, Availability(..)
	, Verification(..)
	, unVerified
	, RetrievalSecurityPolicy(..)
	, isExportSupported
	, ExportActions(..)
	)
	where

import qualified Data.Map as M
import Data.Ord

import qualified Git
import Types.Key
import Types.UUID
import Types.GitConfig
import Types.Availability
import Types.Creds
import Types.UrlContents
import Types.NumCopies
import Types.Export
import Config.Cost
import Utility.Metered
import Git.Types (RemoteName)
import Utility.SafeCommand
import Utility.Url

type RemoteConfigKey = String

type RemoteConfig = M.Map RemoteConfigKey String

data SetupStage = Init | Enable RemoteConfig

{- There are different types of remotes. -}
data RemoteTypeA a = RemoteType
	-- human visible type name
	{ typename :: String
	-- enumerates remotes of this type
	-- The Bool is True if automatic initialization of remotes is desired
	, enumerate :: Bool -> a [Git.Repo]
	-- generates a remote of this type from the current git config
	, generate :: Git.Repo -> UUID -> RemoteConfig -> RemoteGitConfig -> a (Maybe (RemoteA a))
	-- initializes or enables a remote
	, setup :: SetupStage -> Maybe UUID -> Maybe CredPair -> RemoteConfig -> RemoteGitConfig -> a (RemoteConfig, UUID)
	-- check if a remote of this type is able to support export
	, exportSupported :: RemoteConfig -> RemoteGitConfig -> a Bool
	}

instance Eq (RemoteTypeA a) where
	x == y = typename x == typename y

{- An individual remote. -}
data RemoteA a = Remote
	-- each Remote has a unique uuid
	{ uuid :: UUID
	-- each Remote has a human visible name
	, name :: RemoteName
	-- Remotes have a use cost; higher is more expensive
	, cost :: Cost

	-- Transfers a key's contents from disk to the remote.
	-- The key should not appear to be present on the remote until
	-- all of its contents have been transferred.
	, storeKey :: Key -> AssociatedFile -> MeterUpdate -> a Bool
	-- Retrieves a key's contents to a file.
	-- (The MeterUpdate does not need to be used if it writes
	-- sequentially to the file.)
	, retrieveKeyFile :: Key -> AssociatedFile -> FilePath -> MeterUpdate -> a (Bool, Verification)
	-- Retrieves a key's contents to a tmp file, if it can be done cheaply.
	-- It's ok to create a symlink or hardlink.
	, retrieveKeyFileCheap :: Key -> AssociatedFile -> FilePath -> a Bool
	-- Security policy for reteiving keys from this remote.
	, retrievalSecurityPolicy :: RetrievalSecurityPolicy
	-- Removes a key's contents (succeeds if the contents are not present)
	, removeKey :: Key -> a Bool
	-- Uses locking to prevent removal of a key's contents,
	-- thus producing a VerifiedCopy, which is passed to the callback.
	-- If unable to lock, does not run the callback, and throws an
	-- error.
	-- This is optional; remotes do not have to support locking.
	, lockContent :: forall r. Maybe (Key -> (VerifiedCopy -> a r) -> a r)
	-- Checks if a key is present in the remote.
	-- Throws an exception if the remote cannot be accessed.
	, checkPresent :: Key -> a Bool
	-- Some remotes can checkPresent without an expensive network
	-- operation.
	, checkPresentCheap :: Bool
	-- Some remotes support exports of trees.
	, exportActions :: a (ExportActions a)
	-- Some remotes can provide additional details for whereis.
	, whereisKey :: Maybe (Key -> a [String])
	-- Some remotes can run a fsck operation on the remote,
	-- without transferring all the data to the local repo
	-- The parameters are passed to the fsck command on the remote.
	, remoteFsck :: Maybe ([CommandParam] -> a (IO Bool))
	-- Runs an action to repair the remote's git repository.
	, repairRepo :: Maybe (a Bool -> a (IO Bool))
	-- a Remote has a persistent configuration store
	, config :: RemoteConfig
	-- Get the git repo for the Remote.
	, getRepo :: a Git.Repo
	-- a Remote's configuration from git
	, gitconfig :: RemoteGitConfig
	-- a Remote can be assocated with a specific local filesystem path
	, localpath :: Maybe FilePath
	-- a Remote can be known to be readonly
	, readonly :: Bool
	-- a Remote can be globally available. (Ie, "in the cloud".)
	, availability :: Availability
	-- the type of the remote
	, remotetype :: RemoteTypeA a
	-- For testing, makes a version of this remote that is not
	-- available for use. All its actions should fail.
	, mkUnavailable :: a (Maybe (RemoteA a))
	-- Information about the remote, for git annex info to display.
	, getInfo :: a [(String, String)]
	-- Some remotes can download from an url (or uri).
	, claimUrl :: Maybe (URLString -> a Bool)
	-- Checks that the url is accessible, and gets information about
	-- its contents, without downloading the full content.
	-- Throws an exception if the url is inaccessible.
	, checkUrl :: Maybe (URLString -> a UrlContents)
	}

instance Show (RemoteA a) where
	show remote = "Remote { name =\"" ++ name remote ++ "\" }"

-- two remotes are the same if they have the same uuid
instance Eq (RemoteA a) where
	x == y = uuid x == uuid y

-- Order by cost since that is the important order of remotes
-- when deciding which to use. But since remotes often have the same cost
-- and Ord must be total, do a secondary ordering by uuid.
instance Ord (RemoteA a) where
	compare a b
		| cost a == cost b = comparing uuid a b
		| otherwise = comparing cost a b

instance ToUUID (RemoteA a) where
	toUUID = uuid

data Verification
	= UnVerified 
	-- ^ Content was not verified during transfer, but is probably
	-- ok, so if verification is disabled, don't verify it
	| Verified
	-- ^ Content was verified during transfer, so don't verify it
	-- again.
	| MustVerify
	-- ^ Content likely to have been altered during transfer,
	-- verify even if verification is normally disabled

unVerified :: Monad m => m Bool -> m (Bool, Verification)
unVerified a = do
	ok <- a
	return (ok, UnVerified)

-- Security policy indicating what keys can be safely retrieved from a
-- remote.
data RetrievalSecurityPolicy
	= RetrievalVerifiableKeysSecure
	-- ^ Transfer of keys whose content can be verified
	-- with a hash check is secure; transfer of unverifiable keys is
	-- not secure and should not be allowed.
	--
	-- This is used eg, when HTTP to a remote could be redirected to a
	-- local private web server or even a file:// url, causing private
	-- data from it that is not the intended content of a key to make
	-- its way into the git-annex repository.
	--
	-- It's also used when content is stored encrypted on a remote,
	-- which could replace it with a different encrypted file, and
	-- trick git-annex into decrypting it and leaking the decryption
	-- into the git-annex repository.
	--
	-- It's not (currently) used when the remote could alter the
	-- content stored on it, because git-annex does not provide
	-- strong guarantees about the content of keys that cannot be 
	-- verified with a hash check.
	-- (But annex.securehashesonly does provide such guarantees.)
	| RetrievalAllKeysSecure
	-- ^ Any key can be securely retrieved.

isExportSupported :: RemoteA a -> a Bool
isExportSupported r = exportSupported (remotetype r) (config r) (gitconfig r)

data ExportActions a = ExportActions 
	-- Exports content to an ExportLocation.
	-- The exported file should not appear to be present on the remote
	-- until all of its contents have been transferred.
	{ storeExport :: FilePath -> Key -> ExportLocation -> MeterUpdate -> a Bool
	-- Retrieves exported content to a file.
	-- (The MeterUpdate does not need to be used if it writes
	-- sequentially to the file.)
	, retrieveExport :: Key -> ExportLocation -> FilePath -> MeterUpdate -> a Bool
	-- Removes an exported file (succeeds if the contents are not present)
	, removeExport :: Key -> ExportLocation -> a Bool
	-- Removes an exported directory. Typically the directory will be
	-- empty, but it could possbly contain files or other directories,
	-- and it's ok to delete those. If the remote does not use
	-- directories, or automatically cleans up empty directories,
	-- this can be Nothing. Should not fail if the directory was
	-- already removed.
	, removeExportDirectory :: Maybe (ExportDirectory -> a Bool)
	-- Checks if anything is exported to the remote at the specified
	-- ExportLocation.
	-- Throws an exception if the remote cannot be accessed.
	, checkPresentExport :: Key -> ExportLocation -> a Bool
	-- Renames an already exported file.
	-- This may fail, if the file doesn't exist, or the remote does not
	-- support renames.
	, renameExport :: Key -> ExportLocation -> ExportLocation -> a Bool
	}
