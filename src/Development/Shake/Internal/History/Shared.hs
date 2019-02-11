{-# LANGUAGE RecordWildCards, TupleSections #-}

module Development.Shake.Internal.History.Shared(
    Shared, newShared, addShared, lookupShared
    ) where

import Development.Shake.Internal.Value
import Development.Shake.Internal.History.Types
import Development.Shake.Internal.History.Symlink
import Development.Shake.Classes
import General.Binary
import General.Extra
import General.Chunks
import Control.Monad.Extra
import System.FilePath
import System.IO
import Numeric
import Development.Shake.Internal.FileInfo
import General.Wait
import Development.Shake.Internal.FileName
import Data.Monoid
import Data.Functor
import Control.Monad.IO.Class
import Data.Maybe
import qualified Data.ByteString as BS
import Prelude


data Shared = Shared
    {globalVersion :: !Ver
    ,keyOp :: BinaryOp Key
    ,sharedRoot :: FilePath
    }

newShared :: BinaryOp Key -> Ver -> FilePath -> IO Shared
newShared keyOp globalVersion sharedRoot = return Shared{..}


data Entry = Entry
    {entryKey :: Key
    ,entryGlobalVersion :: !Ver
    ,entryBuiltinVersion :: !Ver
    ,entryUserVersion :: !Ver
    ,entryDepends :: [[(Key, BS_Identity)]]
    ,entryResult :: BS_Store
    ,entryFiles :: [(FilePath, FileHash)]
    } deriving (Show, Eq)

putEntry :: BinaryOp Key -> Entry -> Builder
putEntry binop Entry{..} =
    putExStorable entryGlobalVersion <>
    putExStorable entryBuiltinVersion <>
    putExStorable entryUserVersion <>
    putExN (putOp binop entryKey) <>
    putExN (putExList $ map (putExList . map putDepend) entryDepends) <>
    putExN (putExList $ map putFile entryFiles) <>
    putEx entryResult
    where
        putDepend (a,b) = putExN (putOp binop a) <> putEx b
        putFile (a,b) = putExStorable b <> putEx a

getEntry :: BinaryOp Key -> BS.ByteString -> Entry
getEntry binop x
    | (x1, x2, x3, x) <- binarySplit3 x
    , (x4, x) <- getExN x
    , (x5, x) <- getExN x
    , (x6, x7) <- getExN x
    = Entry
        {entryGlobalVersion = x1
        ,entryBuiltinVersion = x2
        ,entryUserVersion = x3
        ,entryKey = getOp binop x4
        ,entryDepends = map (map getDepend . getExList) $ getExList x5
        ,entryFiles = map getFile $ getExList x6
        ,entryResult = getEx x7
        }
    where
        getDepend x | (a, b) <- getExN x = (getOp binop a, getEx b)
        getFile x | (b, a) <- binarySplit x = (getEx a, b)

sharedFileDir :: Shared -> Key -> FilePath
sharedFileDir shared key = sharedRoot shared </> ".shake.cache" </> showHex (abs $ hash key) ""

loadSharedEntry :: Shared -> Key -> Ver -> Ver -> IO [Entry]
loadSharedEntry shared@Shared{..} key builtinVersion userVersion = do
    let file = sharedFileDir shared key </> "_key"
    b <- doesFileExist_ file
    if not b then return [] else do
        (items, slop) <- withFile file ReadMode $ \h ->
            readChunksDirect h maxBound
        unless (BS.null slop) $
            error $ "Corrupted key file, " ++ show file
        let eq Entry{..} = entryKey == key && entryGlobalVersion == globalVersion && entryBuiltinVersion == builtinVersion && entryUserVersion == userVersion
        return $ filter eq $ map (getEntry keyOp) items


-- | Given a way to get the identity, see if you can a stored cloud version
lookupShared :: Shared -> (Key -> Wait Locked (Maybe BS_Identity)) -> Key -> Ver -> Ver -> Wait Locked (Maybe (BS_Store, [[Key]], IO ()))
lookupShared shared ask key builtinVersion userVersion = do
    ents <- liftIO $ loadSharedEntry shared key builtinVersion userVersion
    flip firstJustWaitUnordered ents $ \Entry{..} -> do
        -- use Nothing to indicate success, Just () to bail out early on mismatch
        let result x = if isJust x then Nothing else Just $ (entryResult, map (map fst) entryDepends, ) $ do
                let dir = sharedFileDir shared entryKey
                forM_ entryFiles $ \(file, hash) ->
                    copyFileLink (dir </> show hash) file
        result <$> firstJustM id
            [ firstJustWaitUnordered id
                [ test <$> ask k | (k, i1) <- kis
                , let test = maybe (Just ()) (\i2 -> if i1 == i2 then Nothing else Just ())]
            | kis <- entryDepends]


saveSharedEntry :: Shared -> Entry -> IO ()
saveSharedEntry shared entry = do
    let dir = sharedFileDir shared (entryKey entry)
    createDirectoryRecursive dir
    withFile (dir </> "_key") AppendMode $ \h -> writeChunkDirect h $ putEntry (keyOp shared) entry
    forM_ (entryFiles entry) $ \(file, hash) ->
        unlessM (doesFileExist_ $ dir </> show hash) $
            copyFileLink file (dir </> show hash)


addShared :: Shared -> Key -> Ver -> Ver -> [[(Key, BS_Identity)]] -> BS_Store -> [FilePath] -> IO ()
addShared shared entryKey entryBuiltinVersion entryUserVersion entryDepends entryResult files = do
    hashes <- mapM (getFileHash . fileNameFromString) files
    saveSharedEntry shared Entry{entryFiles = zip files hashes, entryGlobalVersion = globalVersion shared, ..}
