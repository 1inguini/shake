
module Test.Cache(main) where

import Development.Shake
import Development.Shake.FilePath
import Data.Char
import Test.Type


main = shakenCwd test $ \args obj -> do
    want $ map obj args
    vowels <- newCache $ \file -> do
        src <- readFile' file
        liftIO $ appendFile (obj "trace.txt") "1"
        return $ length $ filter isDigit src
    obj "*.out*" %> \x ->
        writeFile' x . show =<< vowels (dropExtension x <.> "txt")


test build obj = do
    writeFile (obj "trace.txt") ""
    writeFile (obj "vowels.txt") "abc123a"
    build ["vowels.out1","vowels.out2","-j3","--sleep"]
    assertContents (obj "trace.txt") "1"
    assertContents (obj "vowels.out1") "3"
    assertContents (obj "vowels.out2") "3"

    build ["vowels.out2","-j3"]
    assertContents (obj "trace.txt") "1"
    assertContents (obj "vowels.out1") "3"

    writeFile (obj "vowels.txt") "12xyz34"
    build ["vowels.out2","-j3","--sleep"]
    assertContents (obj "trace.txt") "11"
    assertContents (obj "vowels.out2") "4"

    build ["vowels.out1","-j3","--sleep"]
    assertContents (obj "trace.txt") "111"
    assertContents (obj "vowels.out1") "4"
