-- In the package body the abstract state refinement contract defines its
-- constituents, that is, the state items which make up the abstraction.
-- The global (and derives, if present) contracts have to be refined in terms
-- ot the constituents of the state abstraction.
-- A state refinement contract is required for each state abstraction declared
-- within the package specification.
-- Placing the state refinement contracts at the start of the package body
-- collects in one place all of the state constituents of the package and all
-- of the state abstractions in one place whether the constituents are declared
-- in the private part of a the package or in its child packages. This should
-- make analysis easier.
-- The subprograms in this package body cannot be shown to be free of RTE
-- without more defensive programming or incorporating preconditions.
package body The_Stack
with 
   Refined_State => State => (S, Pointer) -- State refinement
is
   Max_Stack_Size : constant := 1024;
   type Pointer_Range is range 0 .. Max_Stack_Size;
   subtype Index_Range is Pointer_Range
   range 1 .. Max_Stack_Size;
   type Vector is array (Index_Range) of Integer;

   S: Vector;                              -- Declaration of constituents
   Pointer: Pointer_Range;

   -- The subprogram global definitions are refined in terms of the constituents

   function Is_Empty  return Boolean
   with 
      Refined_Global => Pointer
   is
   begin
      return Pointer = 0;
   end Is_Empty;

   function Is_Full  return Boolean
   with 
      Refined_Global => Pointer
   is
   begin
      return Pointer = Max_Stack_Size;
   end Is_Full;

   function Top return Integer
   with 
      Refined_Global => (Pointer, S)
   is
   begin
      return S (Pointer);
   end Top;

   procedure Push(X: in Integer)
   with 
      Refined_Global => In_Out => (Pointer, S)
   is
   begin
      Pointer := Pointer + 1;
      S (Pointer) := X;
   end Push;

   procedure Pop(X: out Integer)
   with 
      Refined_Global => (In_Out => Pointer,
			 Input  => S)
   is
   begin
      X := S (Pointer);
      Pointer := Pointer - 1;
   end Pop;

   procedure Swap (X: in Integer)
   with 
      Refined_Global => (Input  => Pointer,
                         In_Out => S)
   is
   begin
      S (Pointer) := X;
   end Swap;

begin -- Initialization - we promised to initialize the state
  Pointer := 0;
  S := Vector'(Index_Range => 0);
end The_Stack;
