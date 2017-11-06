module IRGraph
    ( IRGraph(..)
    , Named(..)
    , namedValue
    , unifyNamed
    , mapToInferred
    , IRClassData(..)
    , IREnumData(..)
    , IRType(..)
    , IRUnionRep(..)
    , irUnion_Null
    , irUnion_Integer
    , irUnion_Double
    , irUnion_Bool
    , irUnion_String
    , unionToList
    , Entry(..)
    , makeClass
    , emptyGraph
    , followIndex
    , getClassFromGraph
    , canBeNull
    , isArray
    , isClass
    , isMap
    , matchingProperties
    , mapClasses
    , classesInGraph
    , regatherClassNames
    , regatherUnionNames
    , filterTypes
    , removeNullFromUnion
    , nullableFromUnion
    , isUnionMember
    , forUnion_
    , mapUnionM
    , mapUnion
    , unionHasArray
    , unionHasClass
    , unionHasMap
    , emptyUnion
    ) where

import Prelude

import Control.Comonad (extract)
import Data.Identity (Identity(..))
import Data.Int.Bits as Bits
import Data.List (List, (:))
import Data.List as L
import Data.Map (Map)
import Data.Map as M
import Data.Maybe (Maybe(..), fromJust, maybe, fromMaybe)
import Data.Sequence as Seq
import Data.Set (Set)
import Data.Set as S
import Data.String.Util (singular)
import Data.Tuple (Tuple(..))
import Data.Tuple as T
import Partial.Unsafe (unsafePartial)

data Entry
    = NoType
    | Class IRClassData
    | Redirect Int

newtype IRGraph = IRGraph { classes :: Seq.Seq Entry, toplevels :: Map String IRType }

-- | Names for types are given or inferred.  Given names come from
-- | command line options and JSON Schema `title` properties.  Names
-- | are inferred from the property names for objects.  Given names
-- | always have priority over inferred names.
-- |
-- | `Named` is usually instantiated with a `Set String`, because
-- | classes can have more than one name.  With inferred names this is
-- | common, since we unify identical classes, and they might come from
-- | properties with different names.  It's also possible with given names:
-- | when the input is JSON Schema, one name for the top-level class could
-- | be given on the command line, the other could come from the `title`
-- | property in the schema.
data Named a
    = Given a
    | Inferred a

updateGiven :: forall a b. (Maybe a -> b) -> Named a -> Named b
updateGiven f (Given x) = Given $ f $ Just x
updateGiven f _ = Given $ f Nothing

updateInferred :: forall a. (a -> a) -> Named a -> Named a
updateInferred f (Inferred x) = Inferred $ f x
updateInferred _ given = given

namedValue :: forall a. Named a -> a
namedValue (Given x) = x
namedValue (Inferred x) = x

mapToInferred :: forall a b. (a -> b) -> Named a -> Named b
mapToInferred f n = Inferred $ f $ namedValue n

unifyNamed :: forall a. (a -> a -> a) -> Named a -> Named a -> Named a
unifyNamed f (Given ga) (Given gb) = Given $ f ga gb
unifyNamed f a@(Given _) _ = a
unifyNamed f _ b@(Given _) = b
unifyNamed f (Inferred ia) (Inferred ib) = Inferred $ f ia ib

instance functorNamed :: Functor Named where
    map f (Given x) = Given $ f x
    map f (Inferred x) = Inferred $ f x

-- | Classes have names and properties.  The choice of putting the names
-- | in the class data as opposed to keeping track of it separately is questionable,
-- | since names are subject to change, but properties aren't.  Also, we
-- | want the order of properties to be the same as the order in the original
-- | input, so we will have to switch from using `Map` to something else.  An
-- | order-preserving map would be nice.
newtype IRClassData = IRClassData { names :: Named (Set String), properties :: Map String IRType }

newtype IREnumData = IREnumData { names :: Named (Set String), values :: Set String }

-- | Unions have names and a set of constituent types.  The set is implemented
-- | in a specialized way to make union operations more efficient.
-- |
-- | `primitives` is a bit set, with constants for elements defined below.
newtype IRUnionRep = IRUnionRep
    { names :: Named (Set String)
    , primitives :: Int
    , arrayType :: Maybe IRType
    , classRef :: Maybe Int
    , mapType :: Maybe IRType
    , enumData :: Maybe IREnumData
    }

irUnion_Null :: Int
irUnion_Null = 2
irUnion_Integer :: Int
irUnion_Integer = 4
irUnion_Double :: Int
irUnion_Double = irUnion_Integer + 8
irUnion_Number :: Int
irUnion_Number = irUnion_Double
irUnion_Bool :: Int
irUnion_Bool = 16
irUnion_String :: Int
irUnion_String = 32

-- | The representation of types.
-- |
-- | `IRClass` is an integer indexing `IRGraph`'s `classes`.  This has some issues,
-- | and in any case is an implementation detail that should be hidden from
-- | higher-level users like the language renderers.
data IRType
    = IRNoInformation
    | IRAnyType
    | IRNull
    | IRInteger
    | IRDouble
    | IRBool
    | IRString
    | IRArray IRType
    | IRClass Int
    | IRMap IRType
    | IREnum IREnumData
    | IRUnion IRUnionRep

derive instance eqNamed :: Eq a => Eq (Named a)
derive instance ordNamed :: Ord a => Ord (Named a)
derive instance eqEntry :: Eq Entry
derive instance eqIRType :: Eq IRType
derive instance ordIRType :: Ord IRType
derive instance eqIRClassData :: Eq IRClassData
derive instance ordIRClassData :: Ord IRClassData
derive instance eqIREnumData :: Eq IREnumData
derive instance ordIREnumData :: Ord IREnumData
derive instance eqIRUnionRep :: Eq IRUnionRep
derive instance ordIRUnionRep :: Ord IRUnionRep
derive instance eqGraph :: Eq IRGraph

makeClass :: Named String -> Map String IRType -> IRClassData
makeClass name properties =
    IRClassData { names: map S.singleton name, properties }

emptyGraph :: IRGraph
emptyGraph = IRGraph { classes: Seq.empty, toplevels: M.empty }

followIndex :: IRGraph -> Int -> Tuple Int IRClassData
followIndex graph@(IRGraph { classes }) index =
    unsafePartial $
        case fromJust $ Seq.index index classes of
        Class cd -> Tuple index cd
        Redirect i -> followIndex graph i

getClassFromGraph :: IRGraph -> Int -> IRClassData
getClassFromGraph graph index = T.snd $ followIndex graph index

mapClasses :: forall a. (Int -> IRClassData -> a) -> IRGraph -> List a
mapClasses f (IRGraph { classes }) = L.concat $ L.mapWithIndex mapper (L.fromFoldable classes)
    where
        mapper _ NoType = L.Nil
        mapper _ (Redirect _) = L.Nil
        mapper i (Class cd) = (f i cd) : L.Nil

mapClassesInSeq :: (Int -> IRClassData -> IRClassData) -> Seq.Seq Entry -> Seq.Seq Entry
mapClassesInSeq f entries =
    Seq.fromFoldable $ L.mapWithIndex entryMapper $ L.fromFoldable entries
    where
        entryMapper i (Class cd) = Class $ f i cd
        entryMapper _ x = x

classesInGraph :: IRGraph -> List (Tuple Int IRClassData)
classesInGraph = mapClasses Tuple

isArray :: IRType -> Boolean
isArray (IRArray _) = true
isArray _ = false

isClass :: IRType -> Boolean
isClass (IRClass _) = true
isClass _ = false

isMap :: IRType -> Boolean
isMap (IRMap _) = true
isMap _ = false

canBeNull :: IRType -> Boolean
canBeNull =
    case _ of
    IRAnyType -> true
    IRNull -> true
    IRUnion (IRUnionRep { primitives }) -> (Bits.and primitives irUnion_Null) /= 0
    -- FIXME: this case should not occur!  Only renderers call this function,
    -- and by that time there must not be any IRNoInformation in the graph anymore.
    IRNoInformation -> true
    _ -> false

matchingProperties :: forall v. Eq v => Map String v -> Map String v -> Map String v
matchingProperties ma mb = M.fromFoldable $ L.concatMap getFromB (M.toUnfoldable ma)
    where
        getFromB (Tuple k va) =
            case M.lookup k mb of
            Just vb | va == vb -> Tuple k vb : L.Nil
                    | otherwise -> L.Nil
            Nothing -> L.Nil

regatherClassNames :: IRGraph -> IRGraph
regatherClassNames graph@(IRGraph { classes, toplevels }) =
    -- FIXME: gather names from top levels map, too
    IRGraph { classes: mapClassesInSeq classMapper classes, toplevels }
    where
        newNames = combine $ mapClasses gatherFromClassData graph
        classMapper :: Int -> IRClassData -> IRClassData
        classMapper i (IRClassData { names, properties }) =
            let newNamesForClass = updateInferred (\old -> fromMaybe old $ M.lookup i newNames) names
            in IRClassData { names: newNamesForClass, properties}
        gatherFromClassData :: Int -> IRClassData -> Map Int (Set String)
        gatherFromClassData _ (IRClassData { properties }) =
            combine $ map (\(Tuple n t) -> gatherFromType n t) (M.toUnfoldable properties :: List (Tuple String IRType))
        combine :: List (Map Int (Set String)) -> Map Int (Set String)
        combine =
            L.foldr (M.unionWith S.union) M.empty
        gatherFromType :: String -> IRType -> Map Int (Set String)
        gatherFromType name t =
            case t of
            IRClass i -> M.singleton i (S.singleton name)
            IRArray a -> gatherFromType (singular name) a
            IRMap m -> gatherFromType (singular name) m
            IRUnion (IRUnionRep { arrayType, classRef, mapType }) ->
                let fromArray = maybe M.empty (gatherFromType name) arrayType
                    fromMap = maybe M.empty (gatherFromType name) mapType
                    fromClass = maybe M.empty (\i -> gatherFromType name $ IRClass i) classRef
                in
                    combine $ (fromArray : fromMap : fromClass : L.Nil)
            _ -> M.empty

regatherUnionNames :: IRGraph -> IRGraph
regatherUnionNames graph@(IRGraph { classes, toplevels }) =
    let newClasses = mapClassesInSeq (const classMapper) classes
        newTopLevels = M.mapWithKey (updateType <<< Given) toplevels
    in
        IRGraph { classes: newClasses, toplevels: newTopLevels }
    where
        classMapper (IRClassData { names, properties }) =
            IRClassData { names, properties: M.mapWithKey (updateType <<< Inferred) properties }
        reassign name names =
            case name of
            Given g -> updateGiven (maybe (S.singleton g) (S.insert g)) names
            Inferred i -> updateInferred (const $ S.singleton i) names
        updateType :: Named String -> IRType -> IRType
        updateType name t =
            case t of
            IRArray a -> IRArray $ updateType name a
            IRMap m -> IRMap $ updateType name m
            IRUnion (IRUnionRep { names, primitives, arrayType, classRef, mapType, enumData }) ->
                let newNames = reassign name names
                    singularName = mapToInferred singular name
                    newArrayType = map (updateType singularName) arrayType
                    newMapType = map (updateType singularName) mapType
                in
                    IRUnion $ IRUnionRep { names: newNames, primitives, arrayType: newArrayType, classRef, mapType: newMapType, enumData }
            _ -> t

removeNullFromUnion :: IRUnionRep -> { hasNull :: Boolean, nonNullUnion :: IRUnionRep }
removeNullFromUnion union@(IRUnionRep ur@{ primitives }) =
    if (Bits.and irUnion_Null primitives) == 0 then
        { hasNull: false, nonNullUnion: union }
    else
        { hasNull: true, nonNullUnion: IRUnionRep $ ur { primitives = Bits.xor irUnion_Null primitives }}

unionHasArray :: IRUnionRep -> Maybe IRType
unionHasArray (IRUnionRep { arrayType }) = map IRArray arrayType

unionHasClass :: IRUnionRep -> Maybe IRType
unionHasClass (IRUnionRep { classRef }) = map IRClass classRef

unionHasMap :: IRUnionRep -> Maybe IRType
unionHasMap (IRUnionRep { mapType }) = map IRMap mapType

nullableFromUnion :: IRUnionRep -> Maybe IRType
nullableFromUnion union =
    let { hasNull, nonNullUnion } = removeNullFromUnion union
    in
        if hasNull then
            case unionToList nonNullUnion of
            x : L.Nil -> Just x
            _ -> Nothing
        else
            Nothing

isInPrimitives :: Int -> Int -> Boolean
isInPrimitives primitives bit = (Bits.and bit primitives) /= 0

isInNumber :: Int -> Int -> Boolean
isInNumber primitives bits = (Bits.and irUnion_Number primitives) == bits

forUnion_ :: forall m. Monad m => IRUnionRep -> (IRType -> m Unit) -> m Unit
forUnion_ (IRUnionRep { primitives, arrayType, classRef, mapType }) f = do
    when (inPrimitives irUnion_Null) do f IRNull
    when (inNumber irUnion_Integer) do f IRInteger
    when (inNumber irUnion_Double) do f IRDouble
    when (inPrimitives irUnion_Bool) do f IRBool
    when (inPrimitives irUnion_String) do f IRString
    case arrayType of
        Just a -> do f $ IRArray a
        Nothing -> pure unit
    case classRef of
        Just i -> do f $ IRClass i
        Nothing -> pure unit
    case mapType of
        Just m -> do f $ IRMap m
        Nothing -> pure unit
    where
        inPrimitives = isInPrimitives primitives
        inNumber = isInNumber primitives

mapUnionM :: forall a m. Monad m => (IRType -> m a) -> IRUnionRep -> m (List a)
mapUnionM f (IRUnionRep { primitives, arrayType, classRef, mapType }) = do
    pure L.Nil
        >>= mapGeneral mapType IRMap
        >>= mapGeneral classRef IRClass
        >>= mapGeneral arrayType IRArray
        >>= mapPrimitive isInPrimitives irUnion_String IRString
        >>= mapPrimitive isInPrimitives irUnion_Bool IRBool
        >>= mapPrimitive isInNumber irUnion_Double IRDouble
        >>= mapPrimitive isInNumber irUnion_Integer IRInteger
        >>= mapPrimitive isInPrimitives irUnion_Null IRNull
    where
        mapPrimitive :: (Int -> Int -> Boolean) -> Int -> IRType -> List a -> m (List a)
        mapPrimitive predicate bit t l =
            if predicate primitives bit then do
                result <- f t
                pure $ result : l
            else
                pure l

        mapGeneral :: forall x. Maybe x -> (x -> IRType) -> List a -> m (List a)
        mapGeneral Nothing _ l = pure l
        mapGeneral (Just x) convert l = do
            result <- f $ convert x
            pure $ result : l

mapUnion :: forall a. (IRType -> a) -> IRUnionRep -> List a
mapUnion f = extract <<< mapUnionM (Identity <<< f)

unionToList :: IRUnionRep -> List IRType
unionToList = mapUnion id

isUnionMember :: IRType -> IRUnionRep -> Boolean
isUnionMember t (IRUnionRep { primitives, arrayType, classRef, mapType, enumData }) =
    case t of
    IRNull -> inPrimitives irUnion_Null
    IRInteger -> inNumber irUnion_Integer
    IRDouble -> inNumber irUnion_Double
    IRBool -> inPrimitives irUnion_Bool
    IRString -> inPrimitives irUnion_String
    IRArray a -> maybe false (eq a) arrayType
    IRClass i -> maybe false (eq i) classRef
    IRMap m -> maybe false (eq m) mapType
    IREnum ed -> maybe false (eq ed) enumData
    IRUnion _ -> false
    IRAnyType -> false
    IRNoInformation -> false
    where
        inPrimitives = isInPrimitives primitives
        inNumber = isInNumber primitives

filterTypes :: forall a. Ord a => (IRType -> Maybe a) -> IRGraph -> Set a
filterTypes predicate graph@(IRGraph { classes, toplevels }) =
    let fromTopLevels = S.unions $ map filterType $ M.values toplevels
        fromGraph = S.unions $ mapClasses (\_ cd -> filterClass cd) graph
    in
        S.union fromTopLevels fromGraph
    where
        filterClass :: IRClassData -> Set a
        filterClass (IRClassData { properties }) =
            S.unions $ map filterType $ M.values properties
        recurseType t =
            case t of
            IRArray t' -> filterType t'
            IRMap t' -> filterType t'
            IRUnion r ->
                S.unions $ mapUnion filterType r
            _ -> S.empty
        filterType :: IRType -> Set a
        filterType t =
            let l = recurseType t
            in
                case predicate t of
                Nothing -> l
                Just x -> S.insert x l

emptyUnion :: IRUnionRep
emptyUnion =
    IRUnionRep { names: Inferred $ S.empty, primitives: 0, arrayType: Nothing, classRef: Nothing, mapType: Nothing, enumData: Nothing }
