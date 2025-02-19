/-
Copyright (c) 2023 Scott Morrison. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Scott Morrison
-/
import Lean.CoreM
import Lean4Checker.Lean

open Lean

structure Context where
  newConstants : HashMap Name ConstantInfo

structure State where
  env : Environment
  remaining : NameSet := {}
  pending : NameSet := {}

abbrev M := ReaderT Context <| StateT State IO

def M.run (env : Environment) (newConstants : HashMap Name ConstantInfo) (act : M α) : IO α :=
  StateT.run' (s := { env, remaining := newConstants.keyNameSet }) do
    ReaderT.run (r := { newConstants }) do
      act

/-- Check if a `Name` still needs processing. If so, move it from `remaining` to `pending`. -/
def isTodo (name : Name) : M Bool := do
  let r := (← get).remaining
  if r.contains name then
    modify fun s => { s with remaining := s.remaining.erase name, pending := s.pending.insert name }
    return true
  else
    return false

/-- Use the current `Environment` to throw a `KernelException`. -/
def throwKernelException (ex : KernelException) : M Unit := do
    let ctx := { fileName := "", options := ({} : KVMap), fileMap := default }
    let state := { env := (← get).env }
    Prod.fst <$> (Lean.Core.CoreM.toIO · ctx state) do Lean.throwKernelException ex

/-- Add a declaration, possibly throwing a `KernelException`. -/
def addDecl (d : Declaration) : M Unit := do
  match (← get).env.addDecl d with
  | .ok env => modify fun s => { s with env := env }
  | .error ex => throwKernelException ex

mutual
/--
Check if a `Name` still needs to be processed (i.e. is in `remaining`).

If so, recursively replay any constants it refers to,
to ensure we add declarations in the right order.

The construct the `Declaration` from its stored `ConstantInfo`,
and add it to the environment.
-/
partial def replayConstant (name : Name) : M Unit := do
  if ← isTodo name then
    let some ci := (← read).newConstants.find? name | unreachable!
    replayConstants ci.getUsedConstants
    -- Check that this name is still pending: a mutual block may have taken care of it.
    if (← get).pending.contains name then
      match ci with
      | .defnInfo   info =>
        IO.println s!"Replaying defn {name}"
        addDecl (Declaration.defnDecl   info)
      | .thmInfo    info =>
        IO.println s!"Replaying thm {name}"
        addDecl (Declaration.thmDecl    info)
      | .axiomInfo  info =>
        IO.println s!"Replaying axiom {name}"
        addDecl (Declaration.axiomDecl  info)
      | .opaqueInfo info =>
        IO.println s!"Replaying opaque {name}"
        addDecl (Declaration.opaqueDecl info)
      | .inductInfo info =>
        IO.println s!"Replaying inductive {name}"
        let lparams := info.levelParams
        let nparams := info.numParams
        let all ← info.all.mapM fun n => do pure <| ((← read).newConstants.find! n)
        for o in all do
          modify fun s =>
            { s with remaining := s.remaining.erase o.name, pending := s.pending.erase o.name }
        let ctorInfo ← all.mapM fun ci => do
          pure (ci, ← ci.inductiveVal!.ctors.mapM fun n => do
            pure ((← read).newConstants.find! n))
        -- Make sure we are really finished with the constructors.
        for (_, ctors) in ctorInfo do
          for ctor in ctors do
            replayConstants ctor.getUsedConstants
        let types : List InductiveType := ctorInfo.map fun ⟨ci, ctors⟩ =>
          { name := ci.name
            type := ci.type
            ctors := ctors.map fun ci => { name := ci.name, type := ci.type } }
        addDecl (Declaration.inductDecl lparams nparams types false)
      -- We discard `ctorInfo` and `recInfo` constants. These are added when generating inductives.
      | .ctorInfo _ =>
        IO.println s!"Skipping constructor {name}"
      | .recInfo _ =>
        IO.println s!"Skipping recursor {name}"
      | .quotInfo _ =>
        IO.println s!"Replaying quotient {name}"
        addDecl (Declaration.quotDecl)
      modify fun s => { s with pending := s.pending.erase name }

/-- Replay a set of constants one at a time. -/
partial def replayConstants (names : NameSet) : M Unit := do
  for n in names do replayConstant n

end

/--
Given a module, obtain the environments
* `before`, by importing all its imports but not processing the contents of the module
* `after`, by importing the module
and then run a function `act before after`.
-/
unsafe def diffEnvironments (module : Name) (act : Environment → Environment → IO α) : IO α := do
  Lean.withImportModules #[{module}] {} 0 fun after => do
    Lean.withImportModules (after.importsOf module) {} 0 fun before =>
      act before after

unsafe def replay (module : Name) : IO Unit := do
  diffEnvironments module fun before after => do
    let newConstants := after.constants.map₁.toList.filter
      -- We skip unsafe constants, and also partial constants. Later we may want to handle partial constants.
      fun ⟨n, ci⟩ => !before.constants.map₁.contains n && !ci.isUnsafe && !ci.isPartial
    M.run before (HashMap.ofList newConstants) do
      for (n, _) in newConstants do
        replayConstant n

/--
Run as e.g. `lake exe lean4checker Mathlib.Data.Nat.Basic`.

This will replay all the new declarations from this file into the `Environment`
as it was at the beginning of the file, using the kernel to check them.

This is not an external verifier, simply a tool to detect "environment hacking".
-/
unsafe def main (args : List String) : IO UInt32 := do
  initSearchPath (← findSysroot)
  let module ← match args with
    | [mod] => match Syntax.decodeNameLit s!"`{mod}" with
      | some m => pure m
      | none => throw <| IO.userError s!"Could not resolve module: {mod}"
    | _ => throw <| IO.userError "Usage: lake exe lean4checker Mathlib.Data.Nat.Basic"
  replay module
  return 0
