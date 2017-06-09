
module Test.Parallel(main) where

import Development.Shake
import Test.Type
import Data.Tuple.Extra
import Control.Monad
import Control.Concurrent.Extra
import Data.IORef


main = shakeTest_ test $ do
    let obj = id

    obj "AB.txt" %> \out -> do
        -- need [obj "A.txt", obj "B.txt"]
        (text1,text2) <- readFile' (obj "A.txt") `par` readFile' (obj "B.txt")
        writeFile' out $ text1 ++ text2

    phony "cancel" $ do
        writeFile' (obj "cancel") ""
        done <- liftIO $ newIORef 0
        lock <- liftIO newLock
        void $ parallel $ replicate 5 $ liftIO $ do
            x <- atomicModifyIORef done $ dupe . succ
            when (x == 3) $ do sleep 0.1; fail "boom"
            withLock lock $ appendFile (obj "cancel") "x"

    phony "parallel" $ do
        active <- liftIO $ newIORef 0
        peak <- liftIO $ newIORef 0    
        void $ parallel $ replicate 8 $ liftIO $ do
            now <- atomicModifyIORef active $ dupe . succ
            atomicModifyIORef peak $ dupe . max now
            sleep 0.1
            atomicModifyIORef active $ dupe . pred
        peak <- liftIO $ readIORef peak
        writeFile' (obj "parallel") $ show peak


test build = do
    let obj = id
    writeFile (obj "A.txt") "AAA"
    writeFile (obj "B.txt") "BBB"
    build ["AB.txt","--sleep"]
    assertContents (obj "AB.txt") "AAABBB"
    appendFile (obj "A.txt") "aaa"
    build ["AB.txt"]
    assertContents (obj "AB.txt") "AAAaaaBBB"

    assertException ["boom"] $ build ["cancel","-j1","--quiet"]
    assertContents (obj "cancel") "xx"
    build ["parallel","-j1"]
    assertContents (obj "parallel") "1"
    build ["parallel","-j5"]
    assertContents (obj "parallel") "5"
