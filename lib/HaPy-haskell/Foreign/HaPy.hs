module Foreign.HaPy (
    initHaPy,
    pythonExport,
    __exportInfo,
    module Foreign.C
) where

import Foreign.HaPy.Internal ( peekList, copyList, getVarIType )
import Language.Haskell.TH
import Language.Haskell.TH.Syntax ( Lift(lift) )
import Language.Haskell.TH.Lift ( deriveLift )
import Foreign.StablePtr

import Foreign.C
    ( CInt(..),
      CDouble(..),
      CChar(..),
      CLLong(..),
      castCharToCChar,
      castCCharToChar )
import Foreign.Ptr ( Ptr )
import Foreign.Marshal.Array ()
import Foreign.Marshal.Alloc ( free )

import Data.Int ( Int64(..) )
import Data.List ( intercalate )
import Control.Monad ( zipWithM, replicateM, ap )

import Debug.Trace


data FType = FBool | FChar | FInt | FInt64 | FDouble | FUnit
           | FList FType | FIO FType
           | FStablePtr
           | FUnknown
           deriving (Eq, Ord, Show)

deriveLift ''FType

__exportInfo :: [FType] -> IO (Ptr [CChar])
__exportInfo ftypes = copyList $ map castCharToCChar typeString
  where typeString = intercalate ";" $ map toTypeString ftypes
        toTypeString (FList t)  = "List " ++ toTypeString t
        toTypeString (FIO t)    = toTypeString t
        toTypeString FBool      = "Bool"
        toTypeString FChar      = "Char"
        toTypeString FInt       = "Int"
        toTypeString FInt64     = "Int64"
        toTypeString FDouble    = "Double"
        toTypeString FUnit      = "Unit"
        toTypeString FStablePtr = "StablePtr"
        toTypeString _          = "Unknown"


-- Can't use e.g. ''Bool when pattern matching
fromHaskellType :: Type -> FType
fromHaskellType (ConT nm) | nm == ''Bool   = FBool
                          | nm == ''Char   = FChar
                          | nm == ''Int    = FInt
                          | nm == ''Int64  = FInt64
                          | nm == ''Double = FDouble
                          | nm == ''String = FList FChar
                          | otherwise      = FStablePtr
fromHaskellType (AppT (ConT nm) t) | nm == ''IO = FIO (fromHaskellType t)
fromHaskellType (AppT ListT t) = FList (fromHaskellType t)
fromHaskellType (TupleT 0) = FUnit
fromHaskellType t | trace (show t) True = FUnknown

toForeignType :: FType -> Bool -> TypeQ
toForeignType t ret | ret       = [t| IO $(toF t) |]
                    | otherwise = toF t
    where toF FBool               = [t| Bool |]
          toF FChar               = [t| CChar |]
          toF FInt                = [t| CInt |]
          toF FInt64              = [t| CLLong |]
          toF FDouble             = [t| CDouble |]
          toF (FList t)           = [t| Ptr [$(toF t)] |]
          toF FStablePtr          = [t| Ptr () |]
          toF FUnit   | ret       = [t| () |]
                      | otherwise = error "invalid type - Unit is only supported as return value"
          toF (FIO t) | ret       = toF t
                      | otherwise = error "invalid type - IO action as argument is not supported"
          toF _                   = error "unknown type - cannot convert!"


-- Converts the type of a function to a list of the type of its args and return value
toTypeList :: Type -> [Type]
toTypeList (AppT (AppT ArrowT t) ts) = t : toTypeList ts
toTypeList t                         = [t]

-- Converts the a list of the types of a function's args and return value to the type of a function
fromTypeList :: [Type] -> Type
fromTypeList []     = error "type list empty!"
fromTypeList (t:[]) = t
fromTypeList (t:ts) = (AppT (AppT ArrowT t) (fromTypeList ts))

fromForeignExp :: FType -> ExpQ -> ExpQ
fromForeignExp FBool      exp = [| return $ $exp |]
fromForeignExp FChar      exp = [| return $ castCCharToChar $exp |]
fromForeignExp FInt       exp = [| return $ fromIntegral $exp |]
fromForeignExp FInt64     exp = [| return $ fromIntegral $exp |]
fromForeignExp FDouble    exp = [| return $ realToFrac $exp |]
fromForeignExp (FList t)  exp = [| peekList $exp >>= mapM (\x -> $(fromForeignExp t [|x|])) |]
fromForeignExp FStablePtr exp = [| deRefStablePtr $ castPtrToStablePtr $exp |]
fromForeignExp FUnit      exp = [| return () |]
fromForeignExp (FIO _)    _   = fail "IO actions not supported as arguments"
fromForeignExp _          _   = fail "conversion failed: unsupported type!"

toForeignExp :: FType -> ExpQ -> ExpQ
toForeignExp FBool      exp = [| return $ $exp |]
toForeignExp FChar      exp = [| return $ castCharToCChar $exp |]
toForeignExp FInt       exp = [| return $ fromIntegral $exp |]
toForeignExp FInt64     exp = [| return $ fromIntegral $exp |]
toForeignExp FDouble    exp = [| return $ realToFrac $exp |]
toForeignExp (FList t)  exp = [| mapM (\x -> $(toForeignExp t [|x|])) $exp >>= copyList |]
toForeignExp FStablePtr exp = [| newStablePtr ($exp) >>= return . castStablePtrToPtr |]
toForeignExp FUnit      exp = [| return () |]
toForeignExp (FIO t)    exp = [| $exp >>= (\x -> $(toForeignExp t [|x|])) |]
toForeignExp _          _   = fail "conversion failed: unsupported type!"


makeFunction :: (String -> String) -> (Name -> [FType] -> ClauseQ) -> ([FType] -> TypeQ) -> Name -> DecsQ
makeFunction changeName makeClause makeType origName = do
  reified <- reify origName
  let t = $(getVarIType) reified

  let types = map fromHaskellType $ toTypeList t
      name = mkName . changeName . nameBase $  origName
      cl   = makeClause origName types
      func = funD name [cl]

      typ  = makeType types
      dec = ForeignD `fmap` ExportF CCall (nameBase name) name `fmap` typ
  sequence [func, dec]

makeInfoFunction :: Name -> DecsQ
makeInfoFunction name = makeFunction makeName makeClause (const [t| IO (Ptr [CChar]) |]) name
    where makeName = (++ "__info")
          makeClause _ types = let body = normalB $ [| __exportInfo $(lift types) |] in
                                clause [] body []


makeExportFunction :: Name -> DecsQ
makeExportFunction = makeFunction makeName makeClause makeType
    where makeName = (++ "__export")
          makeType ts = fmap fromTypeList $ zipWithM toForeignType ts (replicate (length ts - 1) False ++ [True])
          makeClause nm types = do
              vars <- replicateM (length types - 1) (newName "x")
              let args = map varP vars
                  convertedArgs = zipWith fromForeignExp types (map varE vars)
                  appliedFunction = foldl apArg [|return $(varE nm)|] convertedArgs
                  body = normalB $ [| $appliedFunction >>= \x -> $(toForeignExp (last types) [|x|]) |]
              clause args body []
          apArg :: ExpQ -> ExpQ -> ExpQ
          apArg f arg = [| ap $f $arg |]

pythonExport :: Name -> DecsQ
pythonExport nm = do
  info <- makeInfoFunction nm
  export <- makeExportFunction nm
  return $ info ++ export

initHaPy :: DecsQ
initHaPy = do
  exportType <- [t| Ptr () -> IO () |]
  let export = ForeignD $ ExportF CCall "__free" (mkName "__free") exportType
  func <- [d| __free = free |]
  let stexport = ForeignD $ ExportF CCall "__freeStablePtr" (mkName "__freeStablePtr") exportType
  stfunc <- [d| __freeStablePtr = freeStablePtr . castPtrToStablePtr |]
  return $ (export:func) ++ (stexport:stfunc)
