open Prelude
open Tester
open Fluid_test_data
module B = BlankOr
module D = Defaults
module R = Refactor
module TL = Toplevel
module E = FluidExpression
open FluidShortcuts

let sampleFunctions =
  let par
      ?(paramDescription = "")
      ?(args = [])
      ?(paramOptional = false)
      paramName
      paramTipe : parameter =
    { paramName
    ; paramTipe
    ; paramOptional
    ; paramBlock_args = args
    ; paramDescription }
  in
  [ { fnName = "Int::add"
    ; fnParameters = [par "a" TInt; par "b" TInt]
    ; fnDescription = ""
    ; fnReturnTipe = TInt
    ; fnPreviewSafety = Safe
    ; fnDeprecated = false
    ; fnInfix = false
    ; fnIsSupportedInQuery = false
    ; fnOrigin = Builtin }
  ; { fnName = "List::getAt_v1"
    ; fnParameters = [par "list" TList; par "index" TInt]
    ; fnDescription = ""
    ; fnReturnTipe = TOption
    ; fnPreviewSafety = Safe
    ; fnDeprecated = false
    ; fnInfix = false
    ; fnIsSupportedInQuery = false
    ; fnOrigin = Builtin }
  ; { fnName = "Dict::map"
    ; fnParameters = [par "dict" TObj; par "f" TBlock ~args:["key"; "value"]]
    ; fnDescription = ""
    ; fnReturnTipe = TObj
    ; fnPreviewSafety = Safe
    ; fnDeprecated = false
    ; fnInfix = false
    ; fnIsSupportedInQuery = false
    ; fnOrigin = Builtin }
  ; { fnName = "DB::set_v1"
    ; fnParameters = [par "val" TObj; par "key" TStr; par "table" TDB]
    ; fnDescription = ""
    ; fnReturnTipe = TObj
    ; fnPreviewSafety = Unsafe
    ; fnDeprecated = false
    ; fnInfix = false
    ; fnIsSupportedInQuery = false
    ; fnOrigin = Builtin } ]


let defaultTLID = TLID.fromString "handler1"

let defaultHandler =
  { hTLID = defaultTLID
  ; pos = {x = 0; y = 0}
  ; ast = FluidAST.ofExpr (EBlank (gid ()))
  ; spec =
      {space = B.newF "HTTP"; name = B.newF "/src"; modifier = B.newF "POST"} }


let aFn name expr : userFunction =
  { ufTLID = gtlid ()
  ; ufMetadata =
      { ufmName = F (gid (), name)
      ; ufmParameters = []
      ; ufmDescription = ""
      ; ufmReturnTipe = F (gid (), TAny)
      ; ufmInfix = false }
  ; ufAST = FluidAST.ofExpr expr }


let run () =
  describe "takeOffRail & putOnRail" (fun () ->
      let f1 =
        { fnName = "Result::resulty"
        ; fnParameters = []
        ; fnDescription = ""
        ; fnReturnTipe = TResult
        ; fnPreviewSafety = Safe
        ; fnDeprecated = false
        ; fnInfix = false
        ; fnIsSupportedInQuery = false
        ; fnOrigin = Builtin }
      in
      let f2 =
        { fnName = "Int::notResulty"
        ; fnParameters = []
        ; fnDescription = ""
        ; fnReturnTipe = TInt
        ; fnPreviewSafety = Safe
        ; fnDeprecated = false
        ; fnInfix = false
        ; fnIsSupportedInQuery = false
        ; fnOrigin = Builtin }
      in
      let model hs =
        { D.defaultModel with
          functions =
            Functions.empty
            |> Functions.setBuiltins [f1; f2] defaultFunctionsProps
        ; handlers = Handlers.fromList hs }
      in
      let handlerWithPointer fnName fnRail =
        let id = ID.fromString "ast1" in
        let ast = FluidAST.ofExpr (E.EFnCall (id, fnName, [], fnRail)) in
        ({defaultHandler with ast}, id)
      in
      let init fnName fnRail =
        let h, pd = handlerWithPointer fnName fnRail in
        let m = model [h] in
        (m, h, pd)
      in
      test "toggles any fncall off rail" (fun () ->
          let m, h, id = init "Int::notResulty" Rail in
          let mod' = Refactor.takeOffRail m (TLHandler h) id in
          let res =
            match mod' with
            | AddOps ([SetHandler (_, _, h)], _) ->
              ( match FluidAST.toExpr h.ast with
              | EFnCall (_, "Int::notResulty", [], NoRail) ->
                  true
              | _ ->
                  false )
            | _ ->
                false
          in
          expect res |> toEqual true) ;
      test "toggles any fncall off rail in a thread" (fun () ->
          let fn = fn ~ster:Rail "List::getAt_v2" [pipeTarget; int 5] in
          let ast = pipe emptyList [fn] |> FluidAST.ofExpr in
          let h = {defaultHandler with ast} in
          let m = model [h] in
          let id = E.toID fn in
          (* this used to crash or just lose all its arguments *)
          let mod' = Refactor.takeOffRail m (TLHandler h) id in
          let res =
            match mod' with
            | AddOps ([SetHandler (_, _, h)], _) ->
              ( match FluidAST.toExpr h.ast with
              | EPipe
                  ( _
                  , [ EList (_, [])
                    ; EFnCall
                        ( _
                        , "List::getAt_v2"
                        , [EPipeTarget _; EInteger (_, "5")]
                        , NoRail ) ] ) ->
                  true
              | _ ->
                  false )
            | _ ->
                false
          in
          expect res |> toEqual true) ;
      test "toggles error-rail-y function onto rail" (fun () ->
          let m, h, pd = init "Result::resulty" NoRail in
          let mod' = Refactor.putOnRail m (TLHandler h) pd in
          let res =
            match mod' with
            | AddOps ([SetHandler (_, _, h)], _) ->
              ( match FluidAST.toExpr h.ast with
              | EFnCall (_, "Result::resulty", [], Rail) ->
                  true
              | _ ->
                  false )
            | _ ->
                false
          in
          expect res |> toEqual true) ;
      test "does not put non-error-rail-y function onto rail" (fun () ->
          let m, h, pd = init "Int::notResulty" NoRail in
          let mod' = Refactor.putOnRail m (TLHandler h) pd in
          let res = match mod' with NoChange -> true | _ -> false in
          expect res |> toEqual true)) ;
  describe "renameDBReferences" (fun () ->
      let db0 =
        { dbTLID = TLID.fromString "db0"
        ; dbName = B.newF "ElmCode"
        ; cols = []
        ; version = 0
        ; oldMigrations = []
        ; activeMigration = None
        ; pos = {x = 0; y = 0} }
      in
      test "datastore renamed, handler updates variable" (fun () ->
          let h =
            { ast = FluidAST.ofExpr (EVariable (ID "ast1", "ElmCode"))
            ; spec =
                { space = B.newF "HTTP"
                ; name = B.newF "/src"
                ; modifier = B.newF "POST" }
            ; hTLID = defaultTLID
            ; pos = {x = 0; y = 0} }
          in
          let f =
            { ufTLID = TLID.fromString "tl-3"
            ; ufMetadata =
                { ufmName = B.newF "f-1"
                ; ufmParameters = []
                ; ufmDescription = ""
                ; ufmReturnTipe = B.new_ ()
                ; ufmInfix = false }
            ; ufAST = FluidAST.ofExpr (EVariable (ID "ast3", "ElmCode")) }
          in
          let model =
            { D.defaultModel with
              dbs = DB.fromList [db0]
            ; handlers = Handlers.fromList [h]
            ; userFunctions = UserFunctions.fromList [f] }
          in
          let ops = R.renameDBReferences model "ElmCode" "WeirdCode" in
          let res =
            match List.sortBy ~f:Encoders.tlidOf ops with
            | [SetHandler (_, _, h); SetFunction f] ->
              ( match (FluidAST.toExpr h.ast, FluidAST.toExpr f.ufAST) with
              | EVariable (_, "WeirdCode"), EVariable (_, "WeirdCode") ->
                  true
              | _ ->
                  false )
            | _ ->
                false
          in
          expect res |> toEqual true) ;
      test "datastore renamed, handler does not change" (fun () ->
          let h =
            { ast = FluidAST.ofExpr (EVariable (ID "ast1", "request"))
            ; spec =
                { space = B.newF "HTTP"
                ; name = B.newF "/src"
                ; modifier = B.newF "POST" }
            ; hTLID = defaultTLID
            ; pos = {x = 0; y = 0} }
          in
          let model =
            { D.defaultModel with
              dbs = DB.fromList [db0]
            ; handlers = Handlers.fromList [h] }
          in
          let ops = R.renameDBReferences model "ElmCode" "WeirdCode" in
          expect ops |> toEqual []) ;
      ()) ;
  describe "generateUserType" (fun () ->
      test "with None input" (fun () ->
          expect
            ( match R.generateUserType None with
            | Ok _ ->
                false
            | Error _ ->
                true )
          |> toEqual true) ;
      test "with Some non-DObj input" (fun () ->
          expect
            ( match R.generateUserType (Some (DStr "foo")) with
            | Ok _ ->
                false
            | Error _ ->
                true )
          |> toEqual true) ;
      test "with Some DObj input" (fun () ->
          let dobj =
            DObj
              ( [ ("str", DStr "foo")
                ; ("int", DInt 1)
                ; ("float", DFloat 1.0)
                ; ("obj", DObj StrDict.empty)
                ; ("date", DDate "2019-07-10T20:42:11Z")
                ; ("datestr", DStr "2019-07-10T20:42:11Z")
                ; ("uuid", DUuid "0a18ca77-9bae-4dfb-816f-0d12cb81c17b")
                ; ("uuidstr", DStr "0a18ca77-9bae-4dfb-816f-0d12cb81c17b") ]
              |> StrDict.fromList )
          in
          let expectedFields =
            (* Note: datestr and uuidstr are TDate and TUuid respectively, _not_ TStr *)
            [ ("str", TStr)
            ; ("int", TInt)
            ; ("float", TFloat)
            ; ("obj", TObj)
            ; ("date", TDate)
            ; ("datestr", TStr)
              (* for now, TStr; in future, maybe we coerce to
                                   TDate *)
            ; ("uuid", TUuid)
            ; ("uuidstr", TStr)
              (* for now, TStr; in future, maybe we coerce to
                                   TUuid *)
            ]
            |> List.map ~f:(fun (k, v) -> (Some k, Some v))
            (* sortBy here because the dobj gets sorted - not sure exactly
               where, but order doesn't matter except in this test *)
            |> List.sortBy ~f:(fun (k, _) -> k)
          in
          let _ = (dobj, expectedFields) in
          let tipe = R.generateUserType (Some dobj) in
          let fields =
            match tipe with
            | Error _ ->
                []
            | Ok ut ->
              ( match ut.utDefinition with
              | UTRecord utr ->
                  utr
                  |> List.map ~f:(fun urf ->
                         (urf.urfName |> B.toOption, urf.urfTipe |> B.toOption))
              )
          in
          expect fields |> toEqual expectedFields)) ;
  describe "extractVarInAst" (fun () ->
      let modelAndTl (ast : FluidAST.t) =
        let hTLID = defaultTLID in
        let tl =
          { hTLID
          ; ast
          ; pos = {x = 0; y = 0}
          ; spec =
              { space = B.newF "HTTP"
              ; name = B.newF "/src"
              ; modifier = B.newF "POST" } }
        in
        let m =
          { D.defaultModel with
            functions =
              Functions.empty
              |> Functions.setBuiltins sampleFunctions defaultFunctionsProps
          ; handlers = [(hTLID, tl)] |> TLIDDict.fromList
          ; fluidState =
              {Defaults.defaultFluidState with ac = FluidAutocomplete.init} }
        in
        (m, TLHandler tl)
      in
      test "with sole expression" (fun () ->
          let ast = FluidAST.ofExpr (int 4) in
          let m, tl = modelAndTl ast in
          expect
            ( R.extractVarInAst m tl (FluidAST.toID ast) "var" ast
            |> FluidAST.toExpr
            |> FluidPrinter.eToTestString )
          |> toEqual "let var = 4\nvar") ;
      test "with expression inside let" (fun () ->
          let expr = fn "Int::add" [var "b"; int 4] in
          let ast = FluidAST.ofExpr (let' "b" (int 5) expr) in
          let m, tl = modelAndTl ast in
          expect
            ( R.extractVarInAst m tl (E.toID expr) "var" ast
            |> FluidAST.toExpr
            |> FluidPrinter.eToTestString )
          |> toEqual "let b = 5\nlet var = Int::add b 4\nvar") ;
      test "with expression inside thread inside let" (fun () ->
          let expr =
            fn
              "DB::set_v1"
              [fieldAccess (var "request") "body"; fn "toString" [var "id"]; b]
          in
          let threadedExpr = fn "Dict::set" [str "id"; var "id"] in
          let exprInThread = pipe expr [threadedExpr] in
          let ast =
            FluidAST.ofExpr (let' "id" (fn "Uuid::generate" []) exprInThread)
          in
          let m, tl = modelAndTl ast in
          expect
            ( R.extractVarInAst m tl (E.toID expr) "var" ast
            |> FluidAST.toExpr
            |> FluidPrinter.eToTestString )
          |> toEqual
               "let id = Uuid::generate\nlet var = DB::setv1 request.body toString id ___________________\nvar\n|>Dict::set \"id\" id\n") ;
      ()) ;
  describe "reorderFnCallArgs" (fun () ->
      let matchExpr a e =
        expect e
        |> withEquality FluidExpression.testEqualIgnoringIds
        |> toEqual a
      in
      test "simple example" (fun () ->
          fn "myFn" [int 1; int 2; int 3]
          |> AST.reorderFnCallArgs "myFn" 0 2
          |> matchExpr (fn "myFn" [int 2; int 1; int 3])) ;
      test "inside another function's arguments" (fun () ->
          fn "anotherFn" [int 0; fn "myFn" [int 1; int 2; int 3]]
          |> AST.reorderFnCallArgs "myFn" 0 2
          |> matchExpr (fn "anotherFn" [int 0; fn "myFn" [int 2; int 1; int 3]])) ;
      test "inside its own arguments" (fun () ->
          fn "myFn" [int 0; fn "myFn" [int 1; int 2; int 3]; int 4]
          |> AST.reorderFnCallArgs "myFn" 1 0
          |> matchExpr
               (fn "myFn" [fn "myFn" [int 2; int 1; int 3]; int 0; int 4])) ;
      test "simple pipe first argument not moved" (fun () ->
          pipe (int 1) [fn "myFn" [pipeTarget; int 2; int 3]]
          |> AST.reorderFnCallArgs "myFn" 2 1
          |> matchExpr (pipe (int 1) [fn "myFn" [pipeTarget; int 3; int 2]])) ;
      test "simple pipe first argument moved" (fun () ->
          pipe (int 1) [fn "myFn" [pipeTarget; int 2; int 3]]
          |> AST.reorderFnCallArgs "myFn" 0 3
          |> matchExpr
               (pipe
                  (int 1)
                  [lambdaWithBinding "x" (fn "myFn" [int 2; int 3; var "x"])])) ;
      test "pipe but the fn is later" (fun () ->
          pipe
            (int 1)
            [ fn "other1" [pipeTarget]
            ; fn "other2" [pipeTarget]
            ; fn "myFn" [pipeTarget; int 2; int 3]
            ; fn "other3" [pipeTarget] ]
          |> AST.reorderFnCallArgs "myFn" 2 1
          |> matchExpr
               (pipe
                  (int 1)
                  [ fn "other1" [pipeTarget]
                  ; fn "other2" [pipeTarget]
                  ; fn "myFn" [pipeTarget; int 3; int 2]
                  ; fn "other3" [pipeTarget] ])) ;
      test "pipe and first argument moved" (fun () ->
          pipe
            (int 1)
            [ fn "other1" [pipeTarget]
            ; fn "other2" [pipeTarget]
            ; fn "myFn" [pipeTarget; int 2; int 3]
            ; fn "other3" [pipeTarget] ]
          |> AST.reorderFnCallArgs "myFn" 1 0
          |> matchExpr
               (pipe
                  (int 1)
                  [ fn "other1" [pipeTarget]
                  ; fn "other2" [pipeTarget]
                  ; lambdaWithBinding "x" (fn "myFn" [int 2; var "x"; int 3])
                  ; fn "other3" [pipeTarget] ])) ;
      test "recurse into piped lambda exprs" (fun () ->
          pipe (int 1) [fn "myFn" [pipeTarget; int 2; int 3]]
          |> AST.reorderFnCallArgs "myFn" 0 1
          |> AST.reorderFnCallArgs "myFn" 0 1
          |> matchExpr
               (pipe
                  (int 1)
                  [lambdaWithBinding "x" (fn "myFn" [var "x"; int 2; int 3])])) ;
      test "inside another expression in a pipe" (fun () ->
          pipe
            (int 0)
            [fn "anotherFn" [pipeTarget; int 1; fn "myFn" [int 2; int 3; int 4]]]
          |> AST.reorderFnCallArgs "myFn" 1 0
          |> matchExpr
               (pipe
                  (int 0)
                  [ fn
                      "anotherFn"
                      [pipeTarget; int 1; fn "myFn" [int 3; int 2; int 4]] ])) ;
      test "inside nested pipes" (fun () ->
          pipe
            (int 1)
            [ lambdaWithBinding
                "a"
                (pipe (var "a") [fn "myFn" [pipeTarget; int 2; int 3]]) ]
          |> AST.reorderFnCallArgs "myFn" 0 3
          |> matchExpr
               (pipe
                  (int 1)
                  [ lambdaWithBinding
                      "a"
                      (pipe
                         (var "a")
                         [ lambdaWithBinding
                             "x"
                             (fn "myFn" [int 2; int 3; var "x"]) ]) ])) ;
      ()) ;
  describe "calculateUserUnsafeFunctions" (fun () ->
      let userFunctions =
        [ aFn "callsUnsafeBuiltin" (fn "DB::set_v1" [])
        ; aFn "callsSafeBuiltin" (fn "List::getAt_v1" [])
        ; aFn "callsSafeUserfn" (fn "callsSafeBuiltin" [])
        ; aFn "callsUnsafeUserfn" (fn "callsUnsafeBuiltin" []) ]
        |> List.map ~f:(fun fn -> (fn.ufTLID, fn))
        |> TLIDDict.fromList
      in
      test "simple example" (fun () ->
          let props = {userFunctions; usedFns = StrDict.empty} in
          expect
            ( Functions.empty
            |> Functions.setBuiltins sampleFunctions props
            |> Functions.testCalculateUnsafeUserFunctions props
            |> StrSet.toList
            |> List.sortWith compare )
          |> toEqual ["callsUnsafeBuiltin"; "callsUnsafeUserfn"]) ;
      ()) ;
  describe "convert-if-to-match" (fun () ->
      let model hs =
        { D.defaultModel with
          functions = Functions.empty
        ; handlers = Handlers.fromList hs }
      in
      let handlerWithPointer cond =
        let id = ID.fromString "ast1" in
        let ast =
          FluidAST.ofExpr
            (E.EIf
               ( id
               , cond
               , EBool (ID.fromString "bool1", true)
               , EBool (ID.fromString "bool2", false) ))
        in
        ({defaultHandler with ast}, id)
      in
      let binOp which lhs rhs =
        E.EBinOp (ID.fromString "binop1", which, lhs, rhs, NoRail)
      in
      let init cond =
        let h, pd = handlerWithPointer cond in
        let m = model [h] in
        (m, h, pd)
      in
      test "generic true false arms" (fun () ->
          let m, h, id = init (binOp "<" (int 3) (int 4)) in
          let mod' = IfToMatch.refactor m (TLHandler h) id in
          let res =
            match mod' with
            | AddOps ([SetHandler (_, _, h)], _) ->
              ( match FluidAST.toExpr h.ast with
              | EMatch
                  ( _
                  , E.EBinOp (_, "<", _, _, _)
                  , [ (FPBool (_, _, true), EBool (_, true))
                    ; (FPBool (_, _, false), EBool (_, false)) ] ) ->
                  true
              | _ ->
                  false )
            | _ ->
                false
          in
          expect res |> toEqual true) ;
      test "fallback true false arms" (fun () ->
          let m, h, id = init (binOp "==" aFnCall aFnCall) in
          let mod' = IfToMatch.refactor m (TLHandler h) id in
          let res =
            match mod' with
            | AddOps ([SetHandler (_, _, h)], _) ->
              ( match FluidAST.toExpr h.ast with
              | EMatch
                  ( _
                  , E.EBinOp (_, "==", _, _, _)
                  , [ (FPBool (_, _, true), EBool (_, true))
                    ; (FPBool (_, _, false), EBool (_, false)) ] ) ->
                  true
              | _ ->
                  false )
            | _ ->
                false
          in
          expect res |> toEqual true) ;
      test "pattern in arm" (fun () ->
          let m, h, id = init (binOp "==" (int 3) aFnCall) in
          let mod' = IfToMatch.refactor m (TLHandler h) id in
          let res =
            match mod' with
            | AddOps ([SetHandler (_, _, h)], _) ->
              ( match FluidAST.toExpr h.ast with
              | EMatch
                  ( _
                  , EFnCall _
                  , [ (FPInteger (_, _, "3"), EBool (_, true))
                    ; (FPVariable (_, _, "_"), EBool (_, false)) ] ) ->
                  true
              | _ ->
                  false )
            | _ ->
                false
          in
          expect res |> toEqual true) ;
      ()) ;
  ()
