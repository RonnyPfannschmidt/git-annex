{- git-annex links to content
 -
 - On file systems that support them, symlinks are used.
 -
 - On other filesystems, git instead stores the symlink target in a regular
 - file.
 -
 - Pointer files are used instead of symlinks for unlocked files.
 -
 - Copyright 2013-2018 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP, BangPatterns #-}

module Annex.Link where

import Annex.Common
import qualified Annex
import qualified Annex.Queue
import qualified Git.Queue
import qualified Git.UpdateIndex
import qualified Git.Index
import qualified Git.LockFile
import qualified Git.Env
import qualified Git
import Git.Types
import Git.FilePath
import Annex.HashObject
import Annex.InodeSentinal
import Utility.FileMode
import Utility.FileSystemEncoding
import Utility.InodeCache
import Utility.Tmp.Dir
import Utility.CopyFile

import qualified Data.ByteString.Lazy as L

type LinkTarget = String

{- Checks if a file is a link to a key. -}
isAnnexLink :: FilePath -> Annex (Maybe Key)
isAnnexLink file = maybe Nothing (fileKey . takeFileName) <$> getAnnexLinkTarget file

{- Gets the link target of a symlink.
 -
 - On a filesystem that does not support symlinks, fall back to getting the
 - link target by looking inside the file.
 -
 - Returns Nothing if the file is not a symlink, or not a link to annex
 - content.
 -}
getAnnexLinkTarget :: FilePath -> Annex (Maybe LinkTarget)
getAnnexLinkTarget f = getAnnexLinkTarget' f
	=<< (coreSymlinks <$> Annex.getGitConfig)

{- Pass False to force looking inside file. -}
getAnnexLinkTarget' :: FilePath -> Bool -> Annex (Maybe LinkTarget)
getAnnexLinkTarget' file coresymlinks = if coresymlinks
	then check readSymbolicLink $
		return Nothing
	else check readSymbolicLink $
		check probefilecontent $
			return Nothing
  where
	check getlinktarget fallback = 
		liftIO (catchMaybeIO $ getlinktarget file) >>= \case
			Just l
				| isLinkToAnnex (fromInternalGitPath l) -> return (Just l)
				| otherwise -> return Nothing
			Nothing -> fallback

	probefilecontent f = withFile f ReadMode $ \h -> do
		-- The first 8k is more than enough to read; link
		-- files are small.
		s <- take 8192 <$> hGetContents h
		-- If we got the full 8k, the file is too large
		if length s == 8192
			then return ""
			else 
				-- If there are any NUL or newline
				-- characters, or whitespace, we
				-- certianly don't have a link to a
				-- git-annex key.
				return $ if any (`elem` s) "\0\n\r \t"
					then ""
					else s

makeAnnexLink :: LinkTarget -> FilePath -> Annex ()
makeAnnexLink = makeGitLink

{- Creates a link on disk.
 -
 - On a filesystem that does not support symlinks, writes the link target
 - to a file. Note that git will only treat the file as a symlink if
 - it's staged as such, so use addAnnexLink when adding a new file or
 - modified link to git.
 -}
makeGitLink :: LinkTarget -> FilePath -> Annex ()
makeGitLink linktarget file = ifM (coreSymlinks <$> Annex.getGitConfig)
	( liftIO $ do
		void $ tryIO $ removeFile file
		createSymbolicLink linktarget file
	, liftIO $ writeFile file linktarget
	)

{- Creates a link on disk, and additionally stages it in git. -}
addAnnexLink :: LinkTarget -> FilePath -> Annex ()
addAnnexLink linktarget file = do
	makeAnnexLink linktarget file
	stageSymlink file =<< hashSymlink linktarget

{- Injects a symlink target into git, returning its Sha. -}
hashSymlink :: LinkTarget -> Annex Sha
hashSymlink linktarget = hashBlob (toInternalGitPath linktarget)

{- Stages a symlink to an annexed object, using a Sha of its target. -}
stageSymlink :: FilePath -> Sha -> Annex ()
stageSymlink file sha =
	Annex.Queue.addUpdateIndex =<<
		inRepo (Git.UpdateIndex.stageSymlink file sha)

{- Injects a pointer file content into git, returning its Sha. -}
hashPointerFile :: Key -> Annex Sha
hashPointerFile key = hashBlob (formatPointer key)

{- Stages a pointer file, using a Sha of its content -}
stagePointerFile :: FilePath -> Maybe FileMode -> Sha -> Annex ()
stagePointerFile file mode sha =
	Annex.Queue.addUpdateIndex =<<
		inRepo (Git.UpdateIndex.stageFile sha treeitemtype file)
  where
	treeitemtype
		| maybe False isExecutable mode = TreeExecutable
		| otherwise = TreeFile

writePointerFile :: FilePath -> Key -> Maybe FileMode -> IO ()
writePointerFile file k mode = do
	writeFile file (formatPointer k)
	maybe noop (setFileMode file) mode

newtype Restage = Restage Bool

{- Restage pointer file. This is used after updating a worktree file
 - when content is added/removed, to prevent git status from showing
 - it as modified.
 -
 - Asks git to refresh its index information for the file.
 - That in turn runs the clean filter on the file; when the clean
 - filter produces the same pointer that was in the index before, git
 - realizes that the file has not actually been modified.
 -
 - Note that, if the pointer file is staged for deletion, or has different
 - content than the current worktree content staged, this won't change
 - that. So it's safe to call at any time and any situation.
 -
 - If the index is known to be locked (eg, git add has run git-annex),
 - that would fail. Restage False will prevent the index being updated.
 - Will display a message to help the user understand why
 - the file will appear to be modified.
 -
 - This uses the git queue, so the update is not performed immediately,
 - and this can be run multiple times cheaply.
 -
 - The InodeCache is for the worktree file. It is used to detect when
 - the worktree file is changed by something else before git update-index
 - gets to look at it.
 -}
restagePointerFile :: Restage -> FilePath -> InodeCache -> Annex ()
restagePointerFile (Restage False) f _ =
	toplevelWarning True $ unableToRestage (Just f)
restagePointerFile (Restage True) f orig = withTSDelta $ \tsd -> do
	-- update-index is documented as picky about "./file" and it
	-- fails on "../../repo/path/file" when cwd is not in the repo 
	-- being acted on. Avoid these problems with an absolute path.
	absf <- liftIO $ absPath f
	Annex.Queue.addInternalAction runner [(absf, isunmodified tsd)]
  where
	isunmodified tsd = genInodeCache f tsd >>= return . \case
		Nothing -> False
		Just new -> compareStrong orig new

	-- Other changes to the files may have been staged before this
	-- gets a chance to run. To avoid a race with any staging of
	-- changes, first lock the index file. Then run git update-index
	-- on all still-unmodified files, using a copy of the index file,
	-- to bypass the lock. Then replace the old index file with the new
	-- updated index file.
	runner = Git.Queue.InternalActionRunner "restagePointerFile" $ \r l -> do
		realindex <- Git.Index.currentIndexFile r
		let lock = Git.Index.indexFileLock realindex
		    lockindex = catchMaybeIO $ Git.LockFile.openLock' lock
		    unlockindex = maybe noop Git.LockFile.closeLock
		    showwarning = warningIO $ unableToRestage Nothing
		    go Nothing = showwarning
		    go (Just _) = withTmpDirIn (Git.localGitDir r) "annexindex" $ \tmpdir -> do
			let tmpindex = tmpdir </> "index"
			let updatetmpindex = do
				r' <- Git.Env.addGitEnv r Git.Index.indexEnv 
					=<< Git.Index.indexEnvVal tmpindex
				Git.UpdateIndex.refreshIndex r' $ \feed ->
					forM_ l $ \(f', checkunmodified) ->
						whenM checkunmodified $
							feed f'
			let replaceindex = catchBoolIO $ do
				moveFile tmpindex realindex
				return True
			ok <- createLinkOrCopy realindex tmpindex
				<&&> updatetmpindex
				<&&> replaceindex
			unless ok showwarning
		bracket lockindex unlockindex go

unableToRestage :: Maybe FilePath -> String
unableToRestage mf = unwords
	[ "git status will show " ++ fromMaybe "some files" mf
	, "to be modified, since content availability has changed"
	, "and git-annex was unable to update the index."
	, "This is only a cosmetic problem affecting git status; git add,"
	, "git commit, etc won't be affected."
	, "To fix the git status display, you can run:"
	, "git update-index -q --refresh " ++ fromMaybe "<file>" mf
	]

{- Parses a symlink target or a pointer file to a Key.
 - Only looks at the first line, as pointer files can have subsequent
 - lines. -}
parseLinkOrPointer :: L.ByteString -> Maybe Key
parseLinkOrPointer = parseLinkOrPointer' 
	. decodeBS . L.take (fromIntegral maxPointerSz)
  where

{- Want to avoid buffering really big files in git into
 - memory when reading files that may be pointers.
 -
 - 8192 bytes is plenty for a pointer to a key.
 - Pad some more to allow for any pointer files that might have
 - lines after the key explaining what the file is used for. -}
maxPointerSz :: Integer
maxPointerSz = 81920

parseLinkOrPointer' :: String -> Maybe Key
parseLinkOrPointer' = go . fromInternalGitPath . takeWhile (not . lineend)
  where
	go l
		| isLinkToAnnex l = fileKey $ takeFileName l
		| otherwise = Nothing
	lineend '\n' = True
	lineend '\r' = True
	lineend _ = False

formatPointer :: Key -> String
formatPointer k = 
	toInternalGitPath (pathSeparator:objectDir </> keyFile k) ++ "\n"

{- Checks if a worktree file is a pointer to a key.
 -
 - Unlocked files whose content is present are not detected by this. -}
isPointerFile :: FilePath -> IO (Maybe Key)
isPointerFile f = catchDefaultIO Nothing $ bracket open close $ \h -> do
	b <- take (fromIntegral maxPointerSz) <$> hGetContents h
	-- strict so it reads before the file handle is closed
	let !mk = parseLinkOrPointer' b
	return mk
  where
	open = openBinaryFile f ReadMode
	close = hClose

{- Checks a symlink target or pointer file first line to see if it
 - appears to point to annexed content.
 -
 - We only look for paths inside the .git directory, and not at the .git
 - directory itself, because GIT_DIR may cause a directory name other
 - than .git to be used.
 -}
isLinkToAnnex :: FilePath -> Bool
isLinkToAnnex s = (pathSeparator:objectDir) `isInfixOf` s
#ifdef mingw32_HOST_OS
	-- '/' is still used inside pointer files on Windows, not the native
	-- '\'
	|| ('/':objectDir) `isInfixOf` s
#endif
