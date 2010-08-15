{-# LANGUAGE BangPatterns, CPP, Rank2Types #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- |
-- Module      : Data.Text
-- Copyright   : (c) 2008, 2009 Tom Harper,
--               (c) 2009, 2010 Bryan O'Sullivan,
--               (c) 2009 Duncan Coutts
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com, rtomharper@googlemail.com,
--               duncan@haskell.org
-- Stability   : experimental
-- Portability : GHC
--
-- A time and space-efficient implementation of Unicode text using
-- packed Word16 arrays.  Suitable for performance critical use, both
-- in terms of large data quantities and high speed.
--
-- This module is intended to be imported @qualified@, to avoid name
-- clashes with "Prelude" functions, e.g.
--
-- > import qualified Data.Text as T

module Data.Text
    (
    -- * Fusion
    -- $fusion

    -- * Types
      Text

    -- * Creation and elimination
    , pack
    , unpack
    , singleton
    , empty

    -- * Basic interface
    , cons
    , snoc
    , append
    , uncons
    , head
    , last
    , tail
    , init
    , null
    , length

    -- * Transformations
    , map
    , intercalate
    , intersperse
    , transpose
    , reverse
    , replace

    -- ** Case conversion
    -- $case
    , toCaseFold
    , toLower
    , toUpper

    -- ** Justification
    , justifyLeft
    , justifyRight
    , center

    -- * Folds
    , foldl
    , foldl'
    , foldl1
    , foldl1'
    , foldr
    , foldr1

    -- ** Special folds
    , concat
    , concatMap
    , any
    , all
    , maximum
    , minimum

    -- * Construction

    -- ** Scans
    , scanl
    , scanl1
    , scanr
    , scanr1

    -- ** Accumulating maps
    , mapAccumL
    , mapAccumR

    -- ** Generation and unfolding
    , replicate
    , unfoldr
    , unfoldrN

    -- * Substrings

    -- ** Breaking strings
    , take
    , drop
    , takeWhile
    , dropWhile
    , dropWhileEnd
    , dropAround
    , strip
    , stripStart
    , stripEnd
    , splitAt
    , spanBy
    , break
    , breakEnd
    , breakBy
    , group
    , groupBy
    , inits
    , tails

    -- ** Breaking into many substrings
    -- $split
    , split
    , splitBy
    , chunksOf

    -- ** Breaking into lines and words
    , lines
    --, lines'
    , words
    , unlines
    , unwords

    -- * Predicates
    , isPrefixOf
    , isSuffixOf
    , isInfixOf

    -- ** View patterns
    , prefixed
    , suffixed

    -- * Searching
    , filter
    , find
    , findBy
    , partitionBy

    -- , findSubstring
    
    -- * Indexing
    -- $index
    , index
    , findIndex
    , count

    -- * Zipping and unzipping
    , zip
    , zipWith

    -- -* Ordered text
    -- , sort
    ) where

import Prelude (Char, Bool(..), Functor(..), Int, Maybe(..), String,
                Eq(..), Ord(..), (++),
                Read(..), Show(..),
                (&&), (||), (+), (-), (.), ($), ($!), (>>), (*),
                div, error, not, return, otherwise)
#if defined(HAVE_DEEPSEQ)
import Control.DeepSeq (NFData)
#endif
#if defined(ASSERTS)
import Control.Exception (assert)
#endif
import Data.Char (isSpace)
import Data.Data (Data(gfoldl, toConstr, gunfold, dataTypeOf))
#if __GLASGOW_HASKELL__ >= 612
import Data.Data (mkNoRepType)
#else
import Data.Data (mkNorepType)
#endif
import Control.Monad (foldM)
import qualified Data.Text.Array as A
import qualified Data.List as L
import Data.Monoid (Monoid(..))
import Data.String (IsString(..))
import qualified Data.Text.Fusion as S
import qualified Data.Text.Fusion.Common as S
import Data.Text.Fusion (stream, reverseStream, unstream)
import Data.Text.Internal (Text(..), empty, text, textP)
import qualified Prelude as P
import Data.Text.Unsafe (Iter(..), iter, iter_, reverseIter, unsafeHead, unsafeTail)
import Data.Text.UnsafeChar (unsafeChr)
import qualified Data.Text.Encoding.Utf16 as U16
import Data.Text.Search (indices)

-- $fusion
--
-- Most of the functions in this module are subject to /fusion/,
-- meaning that a pipeline of such functions will usually allocate at
-- most one 'Text' value.

instance Eq Text where
    t1 == t2 = stream t1 == stream t2
    {-# INLINE (==) #-}

instance Ord Text where
    compare t1 t2 = compare (stream t1) (stream t2)
    {-# INLINE compare #-}

instance Show Text where
    showsPrec p ps r = showsPrec p (unpack ps) r

instance Read Text where
    readsPrec p str = [(pack x,y) | (x,y) <- readsPrec p str]

instance Monoid Text where
    mempty  = empty
    mappend = append
    mconcat = concat

instance IsString Text where
    fromString = pack

#if defined(HAVE_DEEPSEQ)
instance NFData Text
#endif

-- This instance preserves data abstraction at the cost of inefficiency.
-- We omit reflection services for the sake of data abstraction.
-- 
-- This instance was created by copying the behavior of Data.Set and
-- Data.Map. If you feel a mistake has been made, please feel free to
-- submit improvements.
--
-- Original discussion is archived here:

--  "could we get a Data instance for Data.Text.Text?"
--  http://groups.google.com/group/haskell-cafe/browse_thread/thread/b5bbb1b28a7e525d/0639d46852575b93

instance Data Text where
  gfoldl f z txt = z pack `f` (unpack txt)
  toConstr _     = error "Data.Text.Text.toConstr"
  gunfold _ _    = error "Data.Text.Text.gunfold"
#if __GLASGOW_HASKELL__ >= 612
  dataTypeOf _   = mkNoRepType "Data.Text.Text"
#else
  dataTypeOf _   = mkNorepType "Data.Text.Text"
#endif

-- -----------------------------------------------------------------------------
-- * Conversion to/from 'Text'

-- | /O(n)/ Convert a 'String' into a 'Text'.  Subject to fusion.
pack :: String -> Text
pack = unstream . S.streamList
{-# INLINE [1] pack #-}

-- | /O(n)/ Convert a Text into a String.  Subject to fusion.
unpack :: Text -> String
unpack = S.unstreamList . stream
{-# INLINE [1] unpack #-}

-- | /O(1)/ Convert a character into a Text.
-- Subject to fusion.
singleton :: Char -> Text
singleton = unstream . S.singleton
{-# INLINE [1] singleton #-}

-- -----------------------------------------------------------------------------
-- * Basic functions

-- | /O(n)/ Adds a character to the front of a 'Text'.  This function
-- is more costly than its 'List' counterpart because it requires
-- copying a new array.  Subject to fusion.
cons :: Char -> Text -> Text
cons c t = unstream (S.cons c (stream t))
{-# INLINE cons #-}

-- | /O(n)/ Adds a character to the end of a 'Text'.  This copies the
-- entire array in the process, unless fused.  Subject to fusion.
snoc :: Text -> Char -> Text
snoc t c = unstream (S.snoc (stream t) c)
{-# INLINE snoc #-}

-- | /O(n)/ Appends one 'Text' to the other by copying both of them
-- into a new 'Text'.  Subject to fusion.
append :: Text -> Text -> Text
append (Text arr1 off1 len1) (Text arr2 off2 len2) = Text (A.run x) 0 len
    where
      len = len1+len2
      x = do
        arr <- A.unsafeNew len
        A.partialCopyI arr 0 arr1 off1 len1
        A.partialCopyI arr len1 arr2 off2 (len1+len2)
        return arr
{-# INLINE append #-}

{-# RULES
"TEXT append -> fused" [~1] forall t1 t2.
    append t1 t2 = unstream (S.append (stream t1) (stream t2))
"TEXT append -> unfused" [1] forall t1 t2.
    unstream (S.append (stream t1) (stream t2)) = append t1 t2
 #-}

-- | /O(1)/ Returns the first character of a 'Text', which must be
-- non-empty.  Subject to fusion.
head :: Text -> Char
head t = S.head (stream t)
{-# INLINE head #-}

-- | /O(1)/ Returns the first character and rest of a 'Text', or
-- 'Nothing' if empty. Subject to fusion.
uncons :: Text -> Maybe (Char, Text)
uncons t@(Text arr off len)
    | len <= 0  = Nothing
    | otherwise = Just (c, textP arr (off+d) (len-d))
    where Iter c d = iter t 0
{-# INLINE [1] uncons #-}

-- | Lifted from Control.Arrow and specialized.
second :: (b -> c) -> (a,b) -> (a,c)
second f (a, b) = (a, f b)

{-# RULES
"TEXT uncons -> fused" [~1] forall t.
    uncons t = fmap (second unstream) (S.uncons (stream t))
"TEXT uncons -> unfused" [1] forall t.
    fmap (second unstream) (S.uncons (stream t)) = uncons t
  #-}

-- | /O(1)/ Returns the last character of a 'Text', which must be
-- non-empty.  Subject to fusion.
last :: Text -> Char
last (Text arr off len)
    | len <= 0                 = emptyError "last"
    | n < 0xDC00 || n > 0xDFFF = unsafeChr n
    | otherwise                = U16.chr2 n0 n
    where n  = A.unsafeIndex arr (off+len-1)
          n0 = A.unsafeIndex arr (off+len-2)
{-# INLINE [1] last #-}

{-# RULES
"TEXT last -> fused" [~1] forall t.
    last t = S.last (stream t)
"TEXT last -> unfused" [1] forall t.
    S.last (stream t) = last t
  #-}

-- | /O(1)/ Returns all characters after the head of a 'Text', which
-- must be non-empty.  Subject to fusion.
tail :: Text -> Text
tail t@(Text arr off len)
    | len <= 0  = emptyError "tail"
    | otherwise = textP arr (off+d) (len-d)
    where d = iter_ t 0
{-# INLINE [1] tail #-}

{-# RULES
"TEXT tail -> fused" [~1] forall t.
    tail t = unstream (S.tail (stream t))
"TEXT tail -> unfused" [1] forall t.
    unstream (S.tail (stream t)) = tail t
 #-}

-- | /O(1)/ Returns all but the last character of a 'Text', which must
-- be non-empty.  Subject to fusion.
init :: Text -> Text
init (Text arr off len) | len <= 0                   = emptyError "init"
                        | n >= 0xDC00 && n <= 0xDFFF = textP arr off (len-2)
                        | otherwise                  = textP arr off (len-1)
    where
      n = A.unsafeIndex arr (off+len-1)
{-# INLINE [1] init #-}

{-# RULES
"TEXT init -> fused" [~1] forall t.
    init t = unstream (S.init (stream t))
"TEXT init -> unfused" [1] forall t.
    unstream (S.init (stream t)) = init t
 #-}

-- | /O(1)/ Tests whether a 'Text' is empty or not.  Subject to
-- fusion.
null :: Text -> Bool
null (Text _arr _off len) =
#if defined(ASSERTS)
    assert (len >= 0) $
#endif
    len <= 0
{-# INLINE [1] null #-}

{-# RULES
"TEXT null -> fused" [~1] forall t.
    null t = S.null (stream t)
"TEXT null -> unfused" [1] forall t.
    S.null (stream t) = null t
 #-}

-- | /O(1)/ Tests whether a 'Text' contains exactly one character.
-- Subject to fusion.
isSingleton :: Text -> Bool
isSingleton = S.isSingleton . stream
{-# INLINE isSingleton #-}

-- | /O(n)/ Returns the number of characters in a 'Text'.
-- Subject to fusion.
length :: Text -> Int
length t = S.length (stream t)
{-# INLINE length #-}

-- -----------------------------------------------------------------------------
-- * Transformations
-- | /O(n)/ 'map' @f@ @t@ is the 'Text' obtained by applying @f@ to
-- each element of @t@.  Subject to fusion.
map :: (Char -> Char) -> Text -> Text
map f t = unstream (S.map f (stream t))
{-# INLINE [1] map #-}

-- | /O(n)/ The 'intercalate' function takes a 'Text' and a list of
-- 'Text's and concatenates the list after interspersing the first
-- argument between each element of the list.
intercalate :: Text -> [Text] -> Text
intercalate t = concat . (L.intersperse t)
{-# INLINE intercalate #-}

-- | /O(n)/ The 'intersperse' function takes a character and places it
-- between the characters of a 'Text'.  Subject to fusion.
intersperse     :: Char -> Text -> Text
intersperse c t = unstream (S.intersperse c (stream t))
{-# INLINE intersperse #-}

-- | /O(n)/ Reverse the characters of a string. Subject to fusion.
reverse :: Text -> Text
reverse t = S.reverse (stream t)
{-# INLINE reverse #-}

-- | /O(m+n)/ Replace every occurrence of one substring with another.
replace :: Text                 -- ^ Text to search for
        -> Text                 -- ^ Replacement text
        -> Text                 -- ^ Input text
        -> Text
replace s d = intercalate d . split s
{-# INLINE replace #-}

-- ----------------------------------------------------------------------------
-- ** Case conversions (folds)

-- $case
--
-- When case converting 'Text' values, do not use combinators like
-- @map toUpper@ to case convert each character of a string
-- individually, as this gives incorrect results according to the
-- rules of some writing systems.  The whole-string case conversion
-- functions from this module, such as @toUpper@, obey the correct
-- case conversion rules.  As a result, these functions may map one
-- input character to two or three output characters. For examples,
-- see the documentation of each function.

-- | /O(n)/ Convert a string to folded case.  This function is mainly
-- useful for performing caseless (also known as case insensitive)
-- string comparisons.
--
-- A string @x@ is a caseless match for a string @y@ if and only if:
--
-- @toCaseFold x == toCaseFold y@
--
-- The result string may be longer than the input string, and may
-- differ from applying 'toLower' to the input string.  For instance,
-- the Armenian small ligature \"&#xfb13;\" (men now, U+FB13) is case
-- folded to the sequence \"&#x574;\" (men, U+0574) followed by
-- \"&#x576;\" (now, U+0576), while the Greek \"&#xb5;\" (micro sign,
-- U+00B5) is case folded to \"&#x3bc;\" (small letter mu, U+03BC)
-- instead of itself.
toCaseFold :: Text -> Text
toCaseFold t = unstream (S.toCaseFold (stream t))
{-# INLINE [0] toCaseFold #-}

-- | /O(n)/ Convert a string to lower case, using simple case
-- conversion.  The result string may be longer than the input string.
-- For instance, \"&#x130;\" (Latin capital letter I with dot above,
-- U+0130) maps to the sequence \"i\" (Latin small letter i, U+0069) followed
-- by \" &#x307;\" (combining dot above, U+0307).
toLower :: Text -> Text
toLower t = unstream (S.toLower (stream t))
{-# INLINE toLower #-}

-- | /O(n)/ Convert a string to upper case, using simple case
-- conversion.  The result string may be longer than the input string.
-- For instance, the German \"&#xdf;\" (eszett, U+00DF) maps to the
-- two-letter sequence \"SS\".
toUpper :: Text -> Text
toUpper t = unstream (S.toUpper (stream t))
{-# INLINE toUpper #-}

-- | /O(n)/ Left-justify a string to the given length, using the
-- specified fill character on the right. Subject to fusion. Examples:
--
-- > justifyLeft 7 'x' "foo"    == "fooxxxx"
-- > justifyLeft 3 'x' "foobar" == "foobar"
justifyLeft :: Int -> Char -> Text -> Text
justifyLeft k c t
    | len >= k  = t
    | otherwise = t `append` replicateChar (k-len) c
  where len = length t
{-# INLINE [1] justifyLeft #-}

{-# RULES
"TEXT justifyLeft -> fused" [~1] forall k c t.
    justifyLeft k c t = unstream (S.justifyLeftI k c (stream t))
"TEXT justifyLeft -> unfused" [1] forall k c t.
    unstream (S.justifyLeftI k c (stream t)) = justifyLeft k c t
  #-}

-- | /O(n)/ Right-justify a string to the given length, using the
-- specified fill character on the left. Examples:
--
-- > justifyRight 7 'x' "bar"    == "xxxxbar"
-- > justifyRight 3 'x' "foobar" == "foobar"
justifyRight :: Int -> Char -> Text -> Text
justifyRight k c t
    | len >= k  = t
    | otherwise = replicateChar (k-len) c `append` t
  where len = length t
{-# INLINE justifyRight #-}

-- | /O(n)/ Center a string to the given length, using the
-- specified fill character on either side. Examples:
--
-- > center 8 'x' "HS" = "xxxHSxxx"
center :: Int -> Char -> Text -> Text
center k c t
    | len >= k  = t
    | otherwise = replicateChar l c `append` t `append` replicateChar r c
  where len = length t
        d   = k - len
        r   = d `div` 2
        l   = d - r
{-# INLINE center #-}

-- | /O(n)/ The 'transpose' function transposes the rows and columns
-- of its 'Text' argument.  Note that this function uses 'pack',
-- 'unpack', and the list version of transpose, and is thus not very
-- efficient.
transpose :: [Text] -> [Text]
transpose ts = P.map pack (L.transpose (P.map unpack ts))

-- -----------------------------------------------------------------------------
-- * Reducing 'Text's (folds)

-- | /O(n)/ 'foldl', applied to a binary operator, a starting value
-- (typically the left-identity of the operator), and a 'Text',
-- reduces the 'Text' using the binary operator, from left to right.
-- Subject to fusion.
foldl :: (b -> Char -> b) -> b -> Text -> b
foldl f z t = S.foldl f z (stream t)
{-# INLINE foldl #-}

-- | /O(n)/ A strict version of 'foldl'.  Subject to fusion.
foldl' :: (b -> Char -> b) -> b -> Text -> b
foldl' f z t = S.foldl' f z (stream t)
{-# INLINE foldl' #-}

-- | /O(n)/ A variant of 'foldl' that has no starting value argument,
-- and thus must be applied to a non-empty 'Text'.  Subject to fusion.
foldl1 :: (Char -> Char -> Char) -> Text -> Char
foldl1 f t = S.foldl1 f (stream t)
{-# INLINE foldl1 #-}

-- | /O(n)/ A strict version of 'foldl1'.  Subject to fusion.
foldl1' :: (Char -> Char -> Char) -> Text -> Char
foldl1' f t = S.foldl1' f (stream t)
{-# INLINE foldl1' #-}

-- | /O(n)/ 'foldr', applied to a binary operator, a starting value
-- (typically the right-identity of the operator), and a 'Text',
-- reduces the 'Text' using the binary operator, from right to left.
-- Subject to fusion.
foldr :: (Char -> b -> b) -> b -> Text -> b
foldr f z t = S.foldr f z (stream t)
{-# INLINE foldr #-}

-- | /O(n)/ A variant of 'foldr' that has no starting value argument,
-- and thust must be applied to a non-empty 'Text'.  Subject to
-- fusion.
foldr1 :: (Char -> Char -> Char) -> Text -> Char
foldr1 f t = S.foldr1 f (stream t)
{-# INLINE foldr1 #-}

-- -----------------------------------------------------------------------------
-- ** Special folds

-- | /O(n)/ Concatenate a list of 'Text's.
concat :: [Text] -> Text
concat ts = Text (A.run go) 0 len
  where
    len = L.sum (L.map (\(Text _ _ l) -> l) ts)
    go = do
      arr <- A.unsafeNew len
      let step i (Text a o l) = let j = i + l in A.partialCopyI arr i a o j >> return j
      foldM step 0 ts >> return arr
{-# INLINE concat #-}

-- | /O(n)/ Map a function over a 'Text' that results in a 'Text', and
-- concatenate the results.
concatMap :: (Char -> Text) -> Text -> Text
concatMap f = concat . foldr ((:) . f) []
{-# INLINE concatMap #-}

-- | /O(n)/ 'any' @p@ @t@ determines whether any character in the
-- 'Text' @t@ satisifes the predicate @p@. Subject to fusion.
any :: (Char -> Bool) -> Text -> Bool
any p t = S.any p (stream t)
{-# INLINE any #-}

-- | /O(n)/ 'all' @p@ @t@ determines whether all characters in the
-- 'Text' @t@ satisify the predicate @p@. Subject to fusion.
all :: (Char -> Bool) -> Text -> Bool
all p t = S.all p (stream t)
{-# INLINE all #-}

-- | /O(n)/ 'maximum' returns the maximum value from a 'Text', which
-- must be non-empty. Subject to fusion.
maximum :: Text -> Char
maximum t = S.maximum (stream t)
{-# INLINE maximum #-}

-- | /O(n)/ 'minimum' returns the minimum value from a 'Text', which
-- must be non-empty. Subject to fusion.
minimum :: Text -> Char
minimum t = S.minimum (stream t)
{-# INLINE minimum #-}

-- -----------------------------------------------------------------------------
-- * Building 'Text's

-- | /O(n)/ 'scanl' is similar to 'foldl', but returns a list of
-- successive reduced values from the left. Subject to fusion.
--
-- > scanl f z [x1, x2, ...] == [z, z `f` x1, (z `f` x1) `f` x2, ...]
--
-- Note that
--
-- > last (scanl f z xs) == foldl f z xs.
scanl :: (Char -> Char -> Char) -> Char -> Text -> Text
scanl f z t = unstream (S.scanl f z (stream t))
{-# INLINE scanl #-}

-- | /O(n)/ 'scanl1' is a variant of 'scanl' that has no starting
-- value argument.  Subject to fusion.
--
-- > scanl1 f [x1, x2, ...] == [x1, x1 `f` x2, ...]
scanl1 :: (Char -> Char -> Char) -> Text -> Text
scanl1 f t | null t    = empty
           | otherwise = scanl f (unsafeHead t) (unsafeTail t)
{-# INLINE scanl1 #-}

-- | /O(n)/ 'scanr' is the right-to-left dual of 'scanl'.
--
-- > scanr f v == reverse . scanl (flip f) v . reverse
scanr :: (Char -> Char -> Char) -> Char -> Text -> Text
scanr f z = S.reverse . S.reverseScanr f z . reverseStream
{-# INLINE scanr #-}

-- | /O(n)/ 'scanr1' is a variant of 'scanr' that has no starting
-- value argument.  Subject to fusion.
scanr1 :: (Char -> Char -> Char) -> Text -> Text
scanr1 f t | null t    = empty
           | otherwise = scanr f (last t) (init t)
{-# INLINE scanr1 #-}

-- | /O(n)/ Like a combination of 'map' and 'foldl'. Applies a
-- function to each element of a 'Text', passing an accumulating
-- parameter from left to right, and returns a final 'Text'.
mapAccumL :: (a -> Char -> (a,Char)) -> a -> Text -> (a, Text)
mapAccumL f s t = case uncons t of
                    Nothing -> (s, empty)
                    Just (x, xs) -> (s'', cons y ys)
                        where (s', y ) = f s x
                              (s'',ys) = mapAccumL f s' xs

-- | The 'mapAccumR' function behaves like a combination of 'map' and
-- 'foldr'; it applies a function to each element of a 'Text', passing
-- an accumulating parameter from right to left, and returning a final
-- value of this accumulator together with the new 'Text'.
mapAccumR :: (a -> Char -> (a,Char)) -> a -> Text -> (a, Text)
mapAccumR f s t = case uncons t of
                    Nothing -> (s, empty)
                    Just (x, xs) ->  (s'', cons y ys)
                        where (s'',y ) = f s' x
                              (s', ys) = mapAccumR f s xs

-- -----------------------------------------------------------------------------
-- ** Generating and unfolding 'Text's

-- | /O(n*m)/ 'replicate' @n@ @t@ is a 'Text' consisting of the input
-- @t@ repeated @n@ times.
replicate :: Int -> Text -> Text
replicate n t@(Text a o l)
    | n <= 0 || l <= 0 = empty
    | n == 1           = t
    | isSingleton t    = replicateChar n (unsafeHead t)
    | otherwise        = Text (A.run x) 0 len
  where
    len = l * n
    x = do
      arr <- A.unsafeNew len
      let loop !d !i | i >= n    = return arr
                     | otherwise = let m = d + l
                                   in A.partialCopyI arr d a o m >> loop m (i+1)
      loop 0 0
{-# INLINE [1] replicate #-}

{-# RULES
"TEXT replicate/singleton -> replicateChar" [~1] forall n c.
    replicate n (singleton c) = replicateChar n c
  #-}

-- | /O(n)/ 'replicateChar' @n@ @c@ is a 'Text' of length @n@ with @c@ the
-- value of every element. Subject to fusion.
replicateChar :: Int -> Char -> Text
replicateChar n c = unstream (S.replicateCharI n c)
{-# INLINE replicateChar #-}

-- | /O(n)/, where @n@ is the length of the result. The 'unfoldr'
-- function is analogous to the List 'L.unfoldr'. 'unfoldr' builds a
-- 'Text' from a seed value. The function takes the element and
-- returns 'Nothing' if it is done producing the 'Text', otherwise
-- 'Just' @(a,b)@.  In this case, @a@ is the next 'Char' in the
-- string, and @b@ is the seed value for further production. Subject
-- to fusion.
unfoldr     :: (a -> Maybe (Char,a)) -> a -> Text
unfoldr f s = unstream (S.unfoldr f s)
{-# INLINE unfoldr #-}

-- | /O(n)/ Like 'unfoldr', 'unfoldrN' builds a 'Text' from a seed
-- value. However, the length of the result should be limited by the
-- first argument to 'unfoldrN'. This function is more efficient than
-- 'unfoldr' when the maximum length of the result is known and
-- correct, otherwise its performance is similar to 'unfoldr'. Subject
-- to fusion.
unfoldrN     :: Int -> (a -> Maybe (Char,a)) -> a -> Text
unfoldrN n f s = unstream (S.unfoldrN n f s)
{-# INLINE unfoldrN #-}

-- -----------------------------------------------------------------------------
-- * Substrings

-- | /O(n)/ 'take' @n@, applied to a 'Text', returns the prefix of the
-- 'Text' of length @n@, or the 'Text' itself if @n@ is greater than
-- the length of the Text. Subject to fusion.
take :: Int -> Text -> Text
take n t@(Text arr off len)
    | n <= 0    = empty
    | n >= len  = t
    | otherwise = Text arr off (loop 0 0)
  where
      loop !i !cnt
           | i >= len || cnt >= n = i
           | otherwise            = loop (i+d) (cnt+1)
           where d = iter_ t i
{-# INLINE [1] take #-}

{-# RULES
"TEXT take -> fused" [~1] forall n t.
    take n t = unstream (S.take n (stream t))
"TEXT take -> unfused" [1] forall n t.
    unstream (S.take n (stream t)) = take n t
  #-}

-- | /O(n)/ 'drop' @n@, applied to a 'Text', returns the suffix of the
-- 'Text' after the first @n@ characters, or the empty 'Text' if @n@
-- is greater than the length of the 'Text'. Subject to fusion.
drop :: Int -> Text -> Text
drop n t@(Text arr off len)
    | n <= 0    = t
    | n >= len  = empty
    | otherwise = loop 0 0
  where loop !i !cnt
            | i >= len || cnt >= n   = Text arr (off+i) (len-i)
            | otherwise              = loop (i+d) (cnt+1)
            where d = iter_ t i
{-# INLINE [1] drop #-}

{-# RULES
"TEXT drop -> fused" [~1] forall n t.
    drop n t = unstream (S.drop n (stream t))
"TEXT drop -> unfused" [1] forall n t.
    unstream (S.drop n (stream t)) = drop n t
  #-}

-- | /O(n)/ 'takeWhile', applied to a predicate @p@ and a 'Text',
-- returns the longest prefix (possibly empty) of elements that
-- satisfy @p@.  Subject to fusion.
takeWhile :: (Char -> Bool) -> Text -> Text
takeWhile p t@(Text arr off len) = loop 0
  where loop !i | i >= len    = t
                | p c         = loop (i+d)
                | otherwise   = textP arr off i
            where Iter c d    = iter t i
{-# INLINE [1] takeWhile #-}

{-# RULES
"TEXT takeWhile -> fused" [~1] forall p t.
    takeWhile p t = unstream (S.takeWhile p (stream t))
"TEXT takeWhile -> unfused" [1] forall p t.
    unstream (S.takeWhile p (stream t)) = takeWhile p t
  #-}

-- | /O(n)/ 'dropWhile' @p@ @t@ returns the suffix remaining after
-- 'takeWhile' @p@ @t@. Subject to fusion.
dropWhile :: (Char -> Bool) -> Text -> Text
dropWhile p t@(Text arr off len) = loop 0 0
  where loop !i !l | l >= len  = empty
                   | p c       = loop (i+d) (l+d)
                   | otherwise = Text arr (off+i) (len-l)
            where Iter c d     = iter t i
{-# INLINE [1] dropWhile #-}

{-# RULES
"TEXT dropWhile -> fused" [~1] forall p t.
    dropWhile p t = unstream (S.dropWhile p (stream t))
"TEXT dropWhile -> unfused" [1] forall p t.
    unstream (S.dropWhile p (stream t)) = dropWhile p t
  #-}

-- | /O(n)/ 'dropWhileEnd' @p@ @t@ returns the prefix remaining after
-- dropping characters that fail the predicate @p@ from the end of
-- @t@.  Subject to fusion.
-- Examples:
--
-- > dropWhileEnd (=='.') "foo..." == "foo"
dropWhileEnd :: (Char -> Bool) -> Text -> Text
dropWhileEnd p t@(Text arr off len) = loop (len-1) len
  where loop !i !l | l <= 0    = empty
                   | p c       = loop (i+d) (l+d)
                   | otherwise = Text arr off l
            where (c,d)        = reverseIter t i
{-# INLINE [1] dropWhileEnd #-}

{-# RULES
"TEXT dropWhileEnd -> fused" [~1] forall p t.
    dropWhileEnd p t = S.reverse (S.dropWhile p (S.reverseStream t))
"TEXT dropWhileEnd -> unfused" [1] forall p t.
    S.reverse (S.dropWhile p (S.reverseStream t)) = dropWhileEnd p t
  #-}

-- | /O(n)/ 'dropAround' @p@ @t@ returns the substring remaining after
-- dropping characters that fail the predicate @p@ from both the
-- beginning and end of @t@.  Subject to fusion.
dropAround :: (Char -> Bool) -> Text -> Text
dropAround p = dropWhile p . dropWhileEnd p
{-# INLINE [1] dropAround #-}

-- | /O(n)/ Remove leading white space from a string.  Equivalent to:
--
-- > dropWhile isSpace
stripStart :: Text -> Text
stripStart = dropWhile isSpace
{-# INLINE [1] stripStart #-}

-- | /O(n)/ Remove trailing white space from a string.  Equivalent to:
--
-- > dropWhileEnd isSpace
stripEnd :: Text -> Text
stripEnd = dropWhileEnd isSpace
{-# INLINE [1] stripEnd #-}

-- | /O(n)/ Remove leading and trailing white space from a string.
-- Equivalent to:
--
-- > dropAround isSpace
strip :: Text -> Text
strip = dropAround isSpace
{-# INLINE [1] strip #-}

-- | /O(n)/ 'splitAt' @n t@ returns a pair whose first element is a
-- prefix of @t@ of length @n@, and whose second is the remainder of
-- the string. It is equivalent to @('take' n t, 'drop' n t)@.
splitAt :: Int -> Text -> (Text, Text)
splitAt n t@(Text arr off len)
    | n <= 0    = (empty, t)
    | n >= len  = (t, empty)
    | otherwise = (Text arr off k, Text arr (off+k) (len-k))
  where k = loop 0 0
        loop !i !cnt
            | i >= len || cnt >= n = i
            | otherwise            = loop (i+d) (cnt+1)
            where d                = iter_ t i
{-# INLINE splitAt #-}

-- | /O(n)/ 'spanBy', applied to a predicate @p@ and text @t@, returns
-- a pair whose first element is the longest prefix (possibly empty)
-- of @t@ of elements that satisfy @p@, and whose second is the
-- remainder of the list.
spanBy :: (Char -> Bool) -> Text -> (Text, Text)
spanBy p t@(Text arr off len) = (textP arr off k, textP arr (off+k) (len-k))
  where k = loop 0
        loop !i | i >= len || not (p c) = i
                | otherwise             = loop (i+d)
            where Iter c d              = iter t i
{-# INLINE spanBy #-}

-- | /O(n)/ 'breakBy' is like 'spanBy', but the prefix returned is
-- over elements that fail the predicate @p@.
breakBy :: (Char -> Bool) -> Text -> (Text, Text)
breakBy p = spanBy (not . p)
{-# INLINE breakBy #-}

-- | /O(n)/ Group characters in a string according to a predicate.
groupBy :: (Char -> Char -> Bool) -> Text -> [Text]
groupBy p = loop
  where
    loop t@(Text arr off len)
        | null t    = []
        | otherwise = text arr off n : loop (text arr (off+n) (len-n))
        where Iter c d = iter t 0
              n     = d + findAIndexOrEnd (not . p c) (Text arr (off+d) (len-d))

-- | Returns the /array/ index (in units of 'Word16') at which a
-- character may be found.  This is /not/ the same as the logical
-- index returned by e.g. 'findIndex'.
findAIndexOrEnd :: (Char -> Bool) -> Text -> Int
findAIndexOrEnd q t@(Text _arr _off len) = go 0
    where go !i | i >= len || q c       = i
                | otherwise             = go (i+d)
                where Iter c d          = iter t i
    
-- | /O(n)/ Group characters in a string by equality.
group :: Text -> [Text]
group = groupBy (==)

-- | /O(n)/ Return all initial segments of the given 'Text', shortest
-- first.
inits :: Text -> [Text]
inits t@(Text arr off len) = loop 0
    where loop i | i >= len = [t]
                 | otherwise = Text arr off i : loop (i + iter_ t i)

-- | /O(n)/ Return all final segments of the given 'Text', longest
-- first.
tails :: Text -> [Text]
tails t | null t    = [empty]
        | otherwise = t : tails (unsafeTail t)

-- $split
--
-- Splitting functions in this library do not perform character-wise
-- copies to create substrings; they just construct new 'Text's that
-- are slices of the original.

-- | /O(m+n)/ Break a 'Text' into pieces separated by the first
-- 'Text' argument, consuming the delimiter. An empty delimiter is
-- invalid, and will cause an error to be raised.
--
-- Examples:
--
-- > split "\r\n" "a\r\nb\r\nd\r\ne" == ["a","b","d","e"]
-- > split "aaa"  "aaaXaaaXaaaXaaa"  == ["","X","X","X",""]
-- > split "x"    "x"                == ["",""]
-- 
-- and
--
-- > intercalate s . split s         == id
-- > split (singleton c)             == splitBy (==c)
--
-- In (unlikely) bad cases, this function's time complexity degrades
-- towards /O(n*m)/.
split :: Text -> Text -> [Text]
split pat@(Text _ _ l) src@(Text arr off len)
    | l <= 0          = emptyError "split"
    | isSingleton pat = splitBy (== unsafeHead pat) src
    | otherwise       = go 0 (indices pat src)
  where
    go !s (x:xs) =  textP arr (s+off) (x-s) : go (x+l) xs
    go  s _      = [textP arr (s+off) (len-s)]
{-# INLINE [1] split #-}

{-# RULES
"TEXT split/singleton -> splitBy/==" [~1] forall c t.
    split (singleton c) t = splitBy (==c) t
  #-}

-- | /O(n)/ Splits a 'Text' into components delimited by separators,
-- where the predicate returns True for a separator element.  The
-- resulting components do not contain the separators.  Two adjacent
-- separators result in an empty component in the output.  eg.
--
-- > splitBy (=='a') "aabbaca" == ["","","bb","c",""]
-- > splitBy (=='a') ""        == [""]
splitBy :: (Char -> Bool) -> Text -> [Text]
splitBy _ t@(Text _off _arr 0) = [t]
splitBy p t = loop t
    where loop s | null s'   = [l]
                 | otherwise = l : loop (unsafeTail s')
              where (l, s') = breakBy p s
{-# INLINE splitBy #-}

-- | /O(n)/ Splits a 'Text' into components of length @k@.  The last
-- element may be shorter than the other chunks, depending on the
-- length of the input. Examples:
--
-- > chunksOf 3 "foobarbaz"   == ["foo","bar","baz"]
-- > chunksOf 4 "haskell.org" == ["hask","ell.","org"]
chunksOf :: Int -> Text -> [Text]
chunksOf k = go
  where
    go t = case splitAt k t of
             (a,b) | null a    -> []
                   | otherwise -> a : go b
{-# INLINE chunksOf #-}

-- ----------------------------------------------------------------------------
-- * Searching

-------------------------------------------------------------------------------
-- ** Searching with a predicate

-- | /O(n)/ The 'findBy' function takes a predicate and a 'Text', and
-- returns the first element in matching the predicate, or 'Nothing'
-- if there is no such element.
findBy :: (Char -> Bool) -> Text -> Maybe Char
findBy p t = S.findBy p (stream t)
{-# INLINE findBy #-}

-- | /O(n)/ The 'partitionBy' function takes a predicate and a 'Text',
-- and returns the pair of 'Text's with elements which do and do not
-- satisfy the predicate, respectively; i.e.
--
-- > partitionBy p t == (filter p t, filter (not . p) t)
partitionBy :: (Char -> Bool) -> Text -> (Text, Text)
partitionBy p t = (filter p t, filter (not . p) t)
{-# INLINE partitionBy #-}

-- | /O(n)/ 'filter', applied to a predicate and a 'Text',
-- returns a 'Text' containing those characters that satisfy the
-- predicate.
filter :: (Char -> Bool) -> Text -> Text
filter p t = unstream (S.filter p (stream t))
{-# INLINE filter #-}

-- | /O(n+m)/ Find the first instance of @needle@ (which must be
-- non-'null') in @haystack@.  The first element of the returned tuple
-- is the prefix of @haystack@ before @needle@ is matched.  The second
-- is the remainder of @haystack@, starting with the match.
--
-- Examples:
--
-- > break "::" "a::b::c" ==> ("a", "::b::c")
-- > break "/" "foobar"   ==> ("foobar", "")
--
-- Laws:
--
-- > append prefix match == haystack
-- >   where (prefix, match) = break needle haystack
--
-- If you need to break a string by a substring repeatedly (e.g. you
-- want to break on every instance of a substring), use 'find'
-- instead, as it has lower startup overhead.
--
-- In (unlikely) bad cases, this function's time complexity degrades
-- towards /O(n*m)/.
break :: Text -> Text -> (Text, Text)
break pat src@(Text arr off len)
    | null pat  = emptyError "break"
    | otherwise = case indices pat src of
                    []    -> (src, empty)
                    (x:_) -> (textP arr off x, textP arr (off+x) (len-x))
{-# INLINE break #-}

-- | /O(n+m)/ Similar to 'break', but searches from the end of the string.
--
-- The first element of the returned tuple is the prefix of @haystack@
-- up to and including the last match of @needle@.  The second is the
-- remainder of @haystack@, following the match.
--
-- > breakEnd "::" "a::b::c" ==> ("a::b::", "c")
breakEnd :: Text -> Text -> (Text, Text)
breakEnd pat src = let (a,b) = break (reverse pat) (reverse src)
                   in  (reverse b, reverse a)
{-# INLINE breakEnd #-}

-- | /O(n+m)/ Find all non-overlapping instances of @needle@ in
-- @haystack@.  Each element of the returned list consists of a pair:
--
-- * The entire string prior to the /k/th match (i.e. the prefix)
--
-- * The /k/th match, followed by the remainder of the string
--
-- Examples:
--
-- > find "::" ""
-- > ==> []
-- > find "/" "a/b/c/"
-- > ==> [("a", "/b/c/"), ("a/b", "/c/"), ("a/b/c", "/")]
--
-- In (unlikely) bad cases, this function's time complexity degrades
-- towards /O(n*m)/.
--
-- The @needle@ parameter may not be empty.
find :: Text                    -- ^ @needle@ to search for
     -> Text                    -- ^ @haystack@ in which to search
     -> [(Text, Text)]
find pat src@(Text arr off slen)
    | null pat  = emptyError "find"
    | otherwise = L.map step (indices pat src)
  where
    step       x = (chunk 0 x, chunk x (slen-x))
    chunk !n !l  = textP arr (n+off) l
{-# INLINE find #-}

-------------------------------------------------------------------------------
-- ** Indexing 'Text's

-- $index
--
-- If you think of a 'Text' value as an array of 'Char' values (which
-- it is not), you run the risk of writing inefficient code.
--
-- An idiom that is common in some languages is to find the numeric
-- offset of a character or substring, then use that number to split
-- or trim the searched string.  With a 'Text' value, this approach
-- would require two /O(n)/ operations: one to perform the search, and
-- one to operate from wherever the search ended.
--
-- For example, suppose you have a string that you want to split on
-- the substring @\"::\"@, such as @\"foo::bar::quux\"@. Instead of
-- searching for the index of @\"::\"@ and taking the substrings
-- before and after that index, you would instead use @find \"::\"@.

-- | /O(n)/ 'Text' index (subscript) operator, starting from 0.
index :: Text -> Int -> Char
index t n = S.index (stream t) n
{-# INLINE index #-}

-- | /O(n)/ The 'findIndex' function takes a predicate and a 'Text'
-- and returns the index of the first element in the 'Text' satisfying
-- the predicate. Subject to fusion.
findIndex :: (Char -> Bool) -> Text -> Maybe Int
findIndex p t = S.findIndex p (stream t)
{-# INLINE findIndex #-}

-- | /O(n+m)/ The 'count' function returns the number of times the
-- query string appears in the given 'Text'. An empty query string is
-- invalid, and will cause an error to be raised.
--
-- In (unlikely) bad cases, this function's time complexity degrades
-- towards /O(n*m)/.
count :: Text -> Text -> Int
count pat src
    | null pat        = emptyError "count"
    | isSingleton pat = countChar (unsafeHead pat) src
    | otherwise       = L.length (indices pat src)
{-# INLINE [1] count #-}

{-# RULES
"TEXT count/singleton -> countChar" [~1] forall c t.
    count (singleton c) t = countChar c t
  #-}

-- | /O(n)/ The 'countChar' function returns the number of times the
-- query element appears in the given 'Text'. Subject to fusion.
countChar :: Char -> Text -> Int
countChar c t = S.countChar c (stream t)
{-# INLINE countChar #-}

-------------------------------------------------------------------------------
-- * Zipping

-- | /O(n)/ 'zip' takes two 'Text's and returns a list of
-- corresponding pairs of bytes. If one input 'Text' is short,
-- excess elements of the longer 'Text' are discarded. This is
-- equivalent to a pair of 'unpack' operations.
zip :: Text -> Text -> [(Char,Char)]
zip a b = S.unstreamList $ S.zipWith (,) (stream a) (stream b)
{-# INLINE [0] zip #-}

-- | /O(n)/ 'zipWith' generalises 'zip' by zipping with the function
-- given as the first argument, instead of a tupling function.
zipWith :: (Char -> Char -> Char) -> Text -> Text -> Text
zipWith f t1 t2 = unstream (S.zipWith f (stream t1) (stream t2))
{-# INLINE [0] zipWith #-}

-- | /O(n)/ Breaks a 'Text' up into a list of words, delimited by 'Char's
-- representing white space.
words :: Text -> [Text]
words t@(Text arr off len) = loop 0 0
  where
    loop !start !n
        | n >= len = if start == n
                     then []
                     else [Text arr (start+off) (n-start)]
        | isSpace c =
            if start == n
            then loop (start+1) (start+1)
            else Text arr (start+off) (n-start) : loop (n+d) (n+d)
        | otherwise = loop start (n+d)
        where Iter c d = iter t n
{-# INLINE words #-}

-- | /O(n)/ Breaks a 'Text' up into a list of 'Text's at
-- newline 'Char's. The resulting strings do not contain newlines.
lines :: Text -> [Text]
lines ps | null ps   = []
         | otherwise = h : if null t
                           then []
                           else lines (unsafeTail t)
    where (h,t) = spanBy (/= '\n') ps
{-# INLINE lines #-}

{-
-- | /O(n)/ Portably breaks a 'Text' up into a list of 'Text's at line
-- boundaries.
--
-- A line boundary is considered to be either a line feed, a carriage
-- return immediately followed by a line feed, or a carriage return.
-- This accounts for both Unix and Windows line ending conventions,
-- and for the old convention used on Mac OS 9 and earlier.
lines' :: Text -> [Text]
lines' ps | null ps   = []
          | otherwise = h : case uncons t of
                              Nothing -> []
                              Just (c,t')
                                  | c == '\n' -> lines t'
                                  | c == '\r' -> case uncons t' of
                                                   Just ('\n',t'') -> lines t''
                                                   _               -> lines t'
    where (h,t)    = span notEOL ps
          notEOL c = c /= '\n' && c /= '\r'
{-# INLINE lines' #-}
-}

-- | /O(n)/ Joins lines, after appending a terminating newline to
-- each.
unlines :: [Text] -> Text
unlines = concat . L.map (`snoc` '\n')
{-# INLINE unlines #-}

-- | /O(n)/ Joins words using single space characters.
unwords :: [Text] -> Text
unwords = intercalate (singleton ' ')
{-# INLINE unwords #-}

-- | /O(n)/ The 'isPrefixOf' function takes two 'Text's and returns
-- 'True' iff the first is a prefix of the second.  This function is
-- subject to fusion.
isPrefixOf :: Text -> Text -> Bool
isPrefixOf a@(Text _ _ alen) b@(Text _ _ blen) =
    alen <= blen && S.isPrefixOf (stream a) (stream b)
{-# INLINE [1] isPrefixOf #-}

{-# RULES
"TEXT isPrefixOf -> fused" [~1] forall s t.
    isPrefixOf s t = S.isPrefixOf (stream s) (stream t)
"TEXT isPrefixOf -> unfused" [1] forall s t.
    S.isPrefixOf (stream s) (stream t) = isPrefixOf s t
  #-}

-- | /O(n)/ The 'isSuffixOf' function takes two 'Text's and returns
-- 'True' iff the first is a suffix of the second.
isSuffixOf :: Text -> Text -> Bool
isSuffixOf a@(Text _aarr _aoff alen) b@(Text barr boff blen) =
    d >= 0 && a == b'
  where d              = blen - alen
        b' | d == 0    = b
           | otherwise = Text barr (boff+d) alen
{-# INLINE isSuffixOf #-}

-- | /O(n+m)/ The 'isInfixOf' function takes two 'Text's and returns
-- 'True' iff the first is contained, wholly and intact, anywhere
-- within the second.
--
-- In (unlikely) bad cases, this function's time complexity degrades
-- towards /O(n*m)/.
isInfixOf :: Text -> Text -> Bool
isInfixOf needle haystack
    | null needle        = True
    | isSingleton needle = S.elem (unsafeHead needle) . S.stream $ haystack
    | otherwise          = not . L.null . indices needle $ haystack
{-# INLINE [1] isInfixOf #-}

{-# RULES
"TEXT isInfixOf/singleton -> S.elem/S.stream" [~1] forall n h.
    isInfixOf (singleton n) h = S.elem n (S.stream h)
  #-}

-------------------------------------------------------------------------------
-- * View patterns

-- | /O(n)/ Returns the suffix of the second string if its prefix
-- matches the first.
--
-- Examples:
--
-- > prefixed "foo" "foobar" == Just "bar"
-- > prefixed "foo" "quux"   == Nothing
--
-- This is particularly useful with the @ViewPatterns@ extension to
-- GHC, as follows:
--
-- > {-# LANGUAGE ViewPatterns #-}
-- > import Data.Text as T
-- >
-- > fnordLength :: Text -> Int
-- > fnordLength (prefixed "fnord" -> Just suf) = T.length suf
-- > fnordLength _                              = -1
prefixed :: Text -> Text -> Maybe Text
prefixed p@(Text _arr _off plen) t@(Text arr off len)
    | p `isPrefixOf` t = Just $! textP arr (off+plen) (len-plen)
    | otherwise        = Nothing

-- | /O(n)/ Returns the prefix of the second string if its suffix
-- matches the first.
--
-- Examples:
--
-- > suffixed "bar" "foobar" == Just "foo"
-- > suffixed "foo" "quux"   == Nothing
--
-- This is particularly useful with the @ViewPatterns@ extension to
-- GHC, as follows:
--
-- > {-# LANGUAGE ViewPatterns #-}
-- > import Data.Text as T
-- >
-- > quuxLength :: Text -> Int
-- > quuxLength (suffixed "quux" -> Just pre) = T.length pre
-- > quuxLength _                             = -1
suffixed :: Text -> Text -> Maybe Text
suffixed p@(Text _arr _off plen) t@(Text arr off len)
    | p `isSuffixOf` t = Just $! textP arr off (len-plen)
    | otherwise        = Nothing

emptyError :: String -> a
emptyError fun = P.error ("Data.Text." ++ fun ++ ": empty input")
