
module Test.Journal(main) where

import Control.Monad
import Data.IORef
import Development.Shake
import Development.Shake.FilePath
import Test.Type
import System.IO.Unsafe


{-# NOINLINE rebuilt #-}
rebuilt :: IORef Int
rebuilt = unsafePerformIO $ newIORef 0


main = shakenCwd test $ \args obj -> do
    want $ map obj ["a.out","b.out","c.out"]
    obj "*.out" %> \out -> do
        liftIO $ atomicModifyIORef rebuilt $ \a -> (a+1,())
        copyFile' (out -<.> "in") out


test build obj = do
    
    let change x = writeFile (obj $ x <.> "in") x
    let count x = do
            before <- readIORef rebuilt
            build ["--sleep"]
            after <- readIORef rebuilt
            x === after - before

    change "a"
    change "b"
    change "c"
    count 3

    -- test that compressing the database doesn't corrupt anything
    replicateM_ 4 $ do
        change "a"
        count 1
        change "a"
        change "c"
        count 2
