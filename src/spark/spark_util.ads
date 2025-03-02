------------------------------------------------------------------------------
--                                                                          --
--                            GNAT2WHY COMPONENTS                           --
--                                                                          --
--                            S P A R K _ U T I L                           --
--                                                                          --
--                                  S p e c                                 --
--                                                                          --
--                     Copyright (C) 2012-2023, AdaCore                     --
--                                                                          --
-- gnat2why is  free  software;  you can redistribute  it and/or  modify it --
-- under terms of the  GNU General Public License as published  by the Free --
-- Software  Foundation;  either version 3,  or (at your option)  any later --
-- version.  gnat2why is distributed  in the hope that  it will be  useful, --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of  MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public License  distributed with  gnat2why;  see file COPYING3. --
-- If not,  go to  http://www.gnu.org/licenses  for a complete  copy of the --
-- license.                                                                 --
--                                                                          --
-- gnat2why is maintained by AdaCore (http://www.adacore.com)               --
--                                                                          --
------------------------------------------------------------------------------

with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Directories;
with Assumption_Types;      use Assumption_Types;
with Atree;                 use Atree;
with Checked_Types;         use Checked_Types;
with Common_Containers;     use Common_Containers;
with Einfo.Entities;        use Einfo.Entities;
with Einfo.Utils;           use Einfo.Utils;
with Lib;                   use Lib;
with Namet;                 use Namet;
with Nlists;                use Nlists;
with Sem_Aux;               use Sem_Aux;
with Sem_Util;              use Sem_Util;
with Sinfo.Nodes;           use Sinfo.Nodes;
with Sinput;                use Sinput;
with Snames;                use Snames;
with Types;                 use Types;
with Uintp;                 use Uintp;
with Urealp;                use Urealp;

package SPARK_Util is

   ---------------------------------------------------
   --  Utility types related to entities and nodes  --
   ---------------------------------------------------

   subtype N_Ignored_In_Marking is Node_Kind with
     Predicate =>
       N_Ignored_In_Marking in
           N_Call_Marker
         | N_Exception_Declaration
         | N_Freeze_Entity
         | N_Freeze_Generic_Entity
         | N_Implicit_Label_Declaration
         | N_Incomplete_Type_Declaration
         | N_Null_Statement
         | N_Number_Declaration
         | N_Representation_Clause

         --  Renamings are replaced by the renamed object in the frontend, but
         --  the renaming declarations are not removed from the tree. We can
         --  safely ignore them, except for renaming object declarations, which
         --  need to be analyzed for possible RTE.

         | N_Exception_Renaming_Declaration
         | N_Package_Renaming_Declaration
         | N_Subprogram_Renaming_Declaration
         | N_Generic_Renaming_Declaration

         --  Generic instantiations are expanded into the corresponding
         --  declarations in the frontend. The instantiations themselves can be
         --  ignored.

         | N_Package_Instantiation
         | N_Subprogram_Instantiation
         | N_Generic_Subprogram_Declaration
         | N_Generic_Package_Declaration
         | N_Use_Package_Clause
         | N_Use_Type_Clause
         | N_Validate_Unchecked_Conversion
         | N_Variable_Reference_Marker;

   --  After marking, ignore also labels (used in marking for targets of goto),
   --  and body stubs (used in marking to reach out to the proper bodies).
   subtype N_Ignored_In_SPARK is Node_Kind with
     Predicate =>
       N_Ignored_In_SPARK in
           N_Ignored_In_Marking
         | N_Label
         | N_Body_Stub;

   subtype N_Entity_Body is Node_Kind
     with Static_Predicate => N_Entity_Body in N_Proper_Body | N_Entry_Body;

   type Execution_Kind_T is
     (Normal_Execution,      --  regular subprogram
      Barrier,               --  conditional execution
      Abnormal_Termination,  --  No_Return, no output
      Infinite_Loop);        --  No_Return, some output
   --  Expected kind of execution for a called procedure. This does not apply
   --  to main procedures, which should not be called.
   --
   --  Please be *exceptionally* alert when adding elements to this type,
   --  as many checks simply check for one of the options (and do not
   --  explicitly make sure all cases are considered).

   type Scalar_Check_Kind is
     (RCK_Overflow,
      RCK_FP_Overflow,
      RCK_Range,
      RCK_Length,
      RCK_Index,
      RCK_Range_Not_First,
      RCK_Range_Not_Last,
      RCK_Overflow_Not_First,
      RCK_FP_Overflow_Not_First,
      RCK_Overflow_Not_Last,
      RCK_FP_Overflow_Not_Last);
   --  Kind for checks on scalar types

   type Continuation_Type is record
      Ada_Node : Node_Id;
      Message  : Unbounded_String;
   end record;
   --  Continuation message located at Ada_Node

   package Continuation_Vectors is new Ada.Containers.Vectors
     (Positive, Continuation_Type);

   type Fix_Info_Type is record
      Range_Check_Ty : Opt_Type_Kind_Id;
      Divisor        : Node_Or_Entity_Id;
   end record;
   --  Extra information to get better possible fix messages

   type Check_Info_Type is record
      Fix_Info     : Fix_Info_Type;
      Continuation : Continuation_Vectors.Vector;
   end record;
   --  Extra information for checks that is useful for generating better
   --  messages.

   subtype Volatile_Pragma_Id is Pragma_Id with Static_Predicate =>
     Volatile_Pragma_Id in Pragma_Async_Readers
                         | Pragma_Async_Writers
                         | Pragma_Effective_Reads
                         | Pragma_Effective_Writes;
   --  A subtype for our special SPARK volatility aspects

   ------------------------------
   -- Extra tables on entities --
   ------------------------------

   --  The information provided by the frontend is not always sufficient. For
   --  GNATprove, we need in particular:

   --  - the link from the full view to the partial view for private types and
   --    deferred constants (the GNAT tree only contains the opposite link in
   --    Full_View)
   --  - the link from a classwide type to the corresponding specific tagged
   --    type

   --  We store this additional information in extra tables during the SPARK
   --  checking phase, so that it's available during flow analysis and proof.

   procedure Set_Partial_View (E, V : Entity_Id);
   --  Create a link from the full view to the partial view of an entity.
   --  @param E full view of private type or deferred constant
   --  @param V partial view of the same private type or deferred constant

   function Partial_View (E : Entity_Id) return Entity_Id;
   --  @param E type or constant
   --  @return if E is the full view of a private type or deferred constant,
   --    return the partial view for entity E, otherwise Empty

   function Is_Full_View (E : Entity_Id) return Boolean;
   --  @param E type or constant
   --  @return True iff E is the full view of a private type or deferred
   --     constant

   function Is_Partial_View (E : Entity_Id) return Boolean;
   --  @param E any entity
   --  @return True iff E is the partial view of a private type or deferred
   --     constant

   procedure Set_Specific_Tagged (E : Class_Wide_Kind_Id; V : Record_Kind_Id);
   --  Create a link from the classwide type to its specific tagged type
   --  in SPARK, which can be either V or its partial view if the full view of
   --  V is not in SPARK.
   --  @param E classwide type
   --  @param V specific tagged type corresponding to the classwide type E

   function Specific_Tagged (E : Class_Wide_Kind_Id) return Record_Kind_Id;
   --  @param E classwide type
   --  @return the specific tagged type corresponding to classwide type E

   procedure Set_Overlay_Alias (New_Id, Old_Id : Object_Kind_Id);
   --  Register that New_Id is aliasing Old_Id via overlays

   function Overlay_Alias (E : Object_Kind_Id) return Node_Sets.Set
   with Post => not Overlay_Alias'Result.Contains (E);
   --  Return the objects which are aliases of E via overlays. This does not
   --  return E itself.

   ---------------------------------
   -- Extra tables on expressions --
   ---------------------------------

   procedure Set_Dispatching_Contract (C, D : Node_Id);
   --  @param C expression of a classwide pre- or postcondition
   --  @param D dispatching expression for C, in which a reference to a
   --    controlling formal is interpreted as having the class-wide type. This
   --    is used to create a suitable pre- or postcondition expression for
   --    analyzing dispatching calls.

   function Canonical_Entity
     (Ref     : Entity_Id;
      Context : Entity_Id)
      return Entity_Id
   with Pre => Ekind (Context) in Entry_Kind
                                | E_Function
                                | E_Package
                                | E_Procedure
                                | E_Protected_Type
                                | E_Task_Type
                                | Record_Kind
                                | Private_Kind;
   --  Subsidiary to the parsing of flow contracts, i.e. [Refined_]Depends,
   --  [Refined_] Global and Initializes, and default expressions.
   --
   --  If entity Ref denotes the current instance of a concurrent type, as seen
   --  from Context, then returns the entity of that concurrent type;
   --  otherwise, returns Unique_Entity of E.
   --
   --  Note: this routine converts references to the current instance of a
   --  concurrent type within a single concurrent unit from E_Variable (which
   --  is more convenient for the frontend) to the type entity (which is more
   --  convenient to the SPARK backend).

   function Dispatching_Contract (C : Node_Id) return Node_Id;
   --  @param C expression of a classwide pre- or postcondition
   --  @return the dispatching expression previously stored for C, or Empty if
   --    no such expression was stored for C.

   -----------------------------------------
   -- General queries related to entities --
   -----------------------------------------

   function Enclosing_Generic_Instance
     (E : Entity_Id)
      return Opt_E_Package_Id;
   --  @param E any entity
   --  @return entity of the enclosing generic instance package, if any

   function Enclosing_Unit (E : Entity_Id) return Unit_Kind_Id;
   --  Returns the entity of the package, subprogram, entry, protected type,
   --  task type, or subprogram type enclosing E.

   function Directly_Enclosing_Subprogram_Or_Entry
     (E : Entity_Id)
      return Opt_Callable_Kind_Id;
   --  Returns the entity of the first subprogram or entry enclosing E. Returns
   --  Empty if there is no such subprogram or if something else than a package
   --  (a concurrent type or a block statement) is encountered while going up
   --  the scope of E

   function Entity_Comes_From_Source (E : Entity_Id) return Boolean is
      (Comes_From_Source (E)
        or else Comes_From_Source (Atree.Parent (E)));
   --  Ideally we should only look at whether entity E comes from source,
   --  but in various cases this is not properly set in the frontend (for
   --  subprogram inlining and generic instantiations), which cannot be fixed
   --  easily. So we also look at whether the parent node comes from source,
   --  which is more often correct.

   function Full_Name (E : Entity_Id) return String;
   --  @param E any entity
   --  @return the name to use for E in Why3

   function Full_Name_Is_Not_Unique_Name (E : Entity_Id) return Boolean;
   --  In almost all cases, the name to use for an entity in Why3 is based on
   --  its unique name in GNAT AST, so that this name can be used everywhere
   --  to refer to the entity (for example to retrieve completion theories).
   --  A few cases require special handling because their name is predefined
   --  in Why3. This concerns currently only Standard_Boolean and its full
   --  subtypes.
   --  @param E any entity
   --  @return True iff the name to use in Why3 (returned by Full_Name) does
   --     not correspond to unique name in GNAT AST.

   function Full_Source_Name (E : Entity_Id) return String
     with Pre => Present (E) and then Sloc (E) /= No_Location;
   --  For an entity E, return its scoped name, e.g. for a subprogram
   --  nested in
   --
   --    package body P is
   --       procedure Lib_Level is
   --          procedure Nested is
   --          ...
   --  return P.Lib_Level.Nested. Casing of names is taken as it appears in the
   --  source.
   --  @param E an entity
   --  @return the fully scoped name of E as it appears in the source

   function Is_Declared_In_Unit
     (E     : Entity_Id;
      Scope : Entity_Id) return Boolean;
   --  @param E any entity
   --  @param Scope scope
   --  @return True iff E is declared directly in Scope

   function Is_Declared_In_Main_Unit_Or_Parent (N : Node_Id) return Boolean;
   --  @param N any node which is not in Standard
   --  @return True iff N is declared in the analysed unit or any of its
   --     parents.

   function Is_Declared_In_Private (E : Entity_Id) return Boolean;
   --  @param E any entity
   --  @return True iff E is declared in the private part of a package

   function Is_Ignored_Internal (N : Node_Or_Entity_Id) return Boolean is
     (In_Internal_Unit (N)
       and then not Is_Internal_Unit (Main_Unit));
   --  @return True iff N can be ignored because it is an internal node and the
   --  current unit analyzed is not internal.

   function In_SPARK_Library_Unit (N : Node_Or_Entity_Id) return Boolean;
   --  Return True if the source unit for N is in the SPARK library, ie. if
   --  the unit name starts with "spark-" and ends with ".ads" or ".adb".

   function Is_In_Analyzed_Files (E : Entity_Id) return Boolean;
   --  Use this routine to ensure that the entity will be processed only by one
   --  invocation of gnat2why within a single pass of gnatprove. Technically,
   --  the "analyzed files" means either the spec alone or the spec and body.
   --
   --  @param E any entity
   --  @return True iff E is contained in a file that should be analyzed, i.e.
   --     in the spec file, the body file, or any file for a separate body
   --     declared in the body file.
   --
   --  Note: front end offers few similar, but subtly different queries, e.g.
   --  Entity_Is_In_Main_Unit (which is probably the most similar but returns
   --  False for the entity of the unit itself and crashes on Itypes),
   --  In_Extended_Main_Code_Unit (which returns True for entities in
   --  subunits), Sem_Ch12.Is_In_Main_Unit, Inline.In_Main_Unit_Or_Subunit
   --  (which do yet something else).

   function Source_Name (N : Node_Id) return String
     with Pre => Present (N) and then Nkind (N) in N_Has_Chars;
   --  @param N any node with Chars field
   --  @return The unqualified name of N as it appears in the source code

   function Is_Local_Context (Scop : Entity_Id) return Boolean;
   --  Return if a given scope defines a local context where it is legal to
   --  declare a variable of anonymous access type.

   ----------------------------------------------
   -- Queries related to objects or components --
   ----------------------------------------------

   function Comes_From_Declare_Expr (E : Entity_Id) return Boolean;
   --  True if E is an object declared in an expression with actions. In SPARK,
   --  this should correspond to a declare expression.

   function Component_Is_Visible_In_SPARK (E : Entity_Id) return Boolean
     with Pre => Ekind (E) in E_Component | E_Discriminant;
   --  @param E component
   --  @return True iff the component E should be visible in the translation
   --     into Why3, i.e. it is a discriminant (which cannot be hidden in
   --     SPARK) or the full view of the enclosing record is in SPARK.

   function Enclosing_Concurrent_Type (E : Entity_Id) return Concurrent_Kind_Id
   with Pre  => Is_Part_Of_Concurrent_Object (E) or else
                Is_Concurrent_Component_Or_Discr (E);
   --  @param E is the entity of a component, discriminant or Part of
   --     concurrent type
   --  @return concurrent type

   function Has_Volatile (E : N_Entity_Id) return Boolean
   with Pre  => Ekind (E) in E_Abstract_State
                           | E_Protected_Type
                           | E_Task_Type
                           | Object_Kind
                           | Type_Kind,
        Post => (if Ekind (E) in E_Protected_Type | E_Task_Type
                 then not Has_Volatile'Result);
   --  @param E an abstract state, object (including concurrent types, which
   --     might be implicit parameters and globals) or type
   --  @return True iff E is an external state or a volatile object or type

   function Has_Volatile_Property
     (E : N_Entity_Id;
      P : Volatile_Pragma_Id)
      return Boolean
   with Pre => Has_Volatile (E);
   --  @param E an external state, a volatile object or type, or a protected
   --     component
   --  @return True iff E has the specified property P of volatility, either
   --     directly or through its (base) type.

   function Is_Constant_After_Elaboration (E : E_Variable_Id) return Boolean;
   --  @param E entity of a variable
   --  @return True iff a Constant_After_Elaboration applies to E

   function Is_Constant_In_SPARK (E : Object_Kind_Id) return Boolean;
   --  Return True if E is a constant in SPARK (ie. a constant which is not
   --  of access-to-variable type).

   function Is_Concurrent_Component_Or_Discr (E : Entity_Id) return Boolean;
   --  @param E an entity
   --  @return True iff the entity is a component or discriminant of a
   --            concurrent type

   function Is_Constant_Borrower (E : Object_Kind_Id) return Boolean with
     Pre => Is_Local_Borrower (E);
   --  Return True if E is a local borrower which is acting like an observer
   --  (it is directly or indirectly rooted at the first parameter of a
   --  borrowing traversal function).

   function Is_For_Loop_Parameter (E : Entity_Id) return Boolean;
   --  Returns True iff E is the loop parameter of a for loop with a loop
   --  parameter specification.

   function Is_Global_Entity (E : Entity_Id) return Boolean;
   --  Returns True iff E represent an entity that can be a global

   function Is_Local_Borrower (E : Entity_Id) return Boolean;
   --  Return True if E is a constant or a variable of an anonymous access to
   --  variable type.

   function Is_Not_Hidden_Discriminant (E : E_Discriminant_Id) return Boolean;
   --  @param E entity of a discriminant
   --  @return Return True if E is visible in SPARK. A discriminant might not
   --    be visible if it cames from the full view of a private type which
   --    is not in SPARK.

   function Is_Package_State (E : Entity_Id) return Boolean;
   --  @param E any entity
   --  @return True iff E can appear on the LHS of an Initializes contract

   function Is_Part_Of_Concurrent_Object (E : Entity_Id) return Boolean;
   --  @param E any entity
   --  @return True iff the object has a Part_Of pragma that makes it part of a
   --    task or protected object.

   function Is_Part_Of_Protected_Object (E : Entity_Id) return Boolean;
   --  @param E any entity
   --  @return True iff the object has a Part_Of pragma that makes it part of a
   --    protected object.

   function Is_Predefined_Initialized_Entity (E : Entity_Id) return Boolean;
   --  @param E any entity
   --  @return True if E is predefined and initialized variable (see below)
   --
   --  Note: this function, as it is implemented now, may fail to recognize
   --  some variables as initialized, but this is acceptable (i.e. this will
   --  only cause false alarms and not missing checks). If this happens, then
   --  the implementation should be improved to match the spec.

   function Is_Protected_Component_Or_Discr (E : Entity_Id) return Boolean;
   --  @param E an entity
   --  @return True iff the entity is a component or discriminant of a
   --            protected type

   function Is_Protected_Component_Or_Discr_Or_Part_Of
     (E : Entity_Id) return Boolean
   is (Is_Protected_Component_Or_Discr (E) or else
       Is_Part_Of_Protected_Object (E));
   --  @param E an entity
   --  @return True iff E is logically part of a protected object, either being
   --    a discriminant of field of the object, or being a "part_of".

   function Is_Quantified_Loop_Param (E : Entity_Id) return Boolean
     with Pre => Ekind (E) in E_Loop_Parameter | E_Variable;
   --  @param E loop parameter
   --  @return True iff E has been introduced by a quantified expression

   function Is_Synchronized (E : Entity_Id) return Boolean
   with Pre => Ekind (E) in E_Abstract_State |
                            E_Protected_Type |
                            E_Task_Type      |
                            Object_Kind;
   --  @param E an entity that represents a global
   --  @return True if E is safe to be accesses from multiple tasks

   function Is_Writable_Parameter (E : Entity_Id) return Boolean
   with Pre => Ekind (E) = E_In_Parameter
         and then Ekind (Scope (E)) in E_Procedure
                                     | E_Entry
                                     | E_Subprogram_Type;
   --  @param E entity of a procedure or entry formal parameter of mode IN
   --  @return True if E can be written despite being of mode IN

   function Root_Discriminant (E : E_Discriminant_Id) return Entity_Id;
   --  Given discriminant of a record (sub-)type, return the corresponding
   --  discriminant of the root retysp, if any. This is the identity when E is
   --  the discriminant of a root type.

   function Search_Component_By_Name
     (Rec  : Record_Like_Kind_Id;
      Comp : Record_Field_Kind_Id)
      return Opt_Record_Field_Kind_Id;
   --  Given a record type entity and a component/discriminant entity, search
   --  in Rec a component/discriminant entity with the same name and the same
   --  original record component. Returns Empty if no such component is found.
   --  In particular returns empty on hidden components.

   function Unique_Component
     (E : Record_Field_Kind_Id)
      return Record_Field_Kind_Id
   with Post => Ekind (Unique_Component'Result) = Ekind (E);
   --  Given an entity of a record component or discriminant, possibly from a
   --  derived type, return the corresponding component or discriminant from
   --  the base type. The returned entity provides a unique representation of
   --  components and discriminants between both the base type and all types
   --  derived from it.

   function Is_Unique_Component (E : Entity_Id) return Boolean is
     (E = Unique_Component (E)) with Ghost;
   --  A trivial wrapper to be used in assertions when converting from the
   --  frontend to flow representation of discriminants and components.

   procedure Objects_Have_Compatible_Alignments
     (X           : Constant_Or_Variable_Kind_Id;
      Y           : Object_Kind_Id;
      Result      : out Boolean;
      Explanation : out Unbounded_String)
   with Post => Result = (Explanation = Null_Unbounded_String);
   --  @param X a stand-alone object that overlays the other
   --            (object with Address clause)
   --  @param Y object that is overlaid (object whose 'Address is used in
   --            the Address clause of X)
   --  @return True iff X'Alignment and Y'Alignment are known and Y'Alignment
   --          is an integral multiple of X'Alignment

   --------------------------------
   -- Queries related to pragmas --
   --------------------------------

   function Is_Ignored_Pragma_Check (N : N_Pragma_Id) return Boolean;
   --  @param N pragma
   --  @return True iff N is a pragma Check that can be ignored by analysis,
   --     because it is already taken into account elsewhere (precondition,
   --     postcondition, predicates).

   function Is_Pragma (N : Node_Id; Name : Pragma_Id) return Boolean;
   --  @param N any node
   --  @param Name pragma name
   --  @return True iff N is a pragma with the given Name

   function Is_Pragma_Annotate_GNATprove (N : Node_Id) return Boolean;
   --  @param N any node
   --  @return True iff N is a pragma Annotate (GNATprove, ...);

   function Is_Pragma_Check (N : Node_Id; Name : Name_Id) return Boolean;
   --  @param N any node
   --  @return True iff N is a pragma Check (Name, ...);

   function Is_Pragma_Assert_And_Cut (N : N_Pragma_Id) return Boolean;
   --  @param N pragma
   --  @return True iff N is a pragma Assert_And_Cut

   ---------------------------------
   -- Queries for arbitrary nodes --
   ---------------------------------

   function String_Of_Node (N : N_Subexpr_Id) return String;
   --  @param N any expression node
   --  @return the node as pretty printed Ada code, limited to 50 chars

   generic
      with function Property (N : Node_Id) return Boolean;
   function First_Parent_With_Property (N : Node_Id) return Node_Id with
     Post => No (First_Parent_With_Property'Result)
       or else Property (First_Parent_With_Property'Result);
   --  @param N any node
   --  @return the first node in the chain of parents of N for which Property
   --     returns True.

   function Get_Initialized_Object
     (N : N_Subexpr_Id)
      return Opt_Object_Kind_Id;
   --  @param N any expression node
   --  @return if N is used to initialize an object, return this object. Return
   --      Empty otherwise. This is used to get a stable name for aggregates
   --      used as definition of objects.

   function In_Loop_Entry_Or_Old_Attribute (N : Node_Id) return Boolean;
   --  @param N any node
   --  @return True if the node is a Loop_Entry or Old attribute

   function Is_In_Statically_Dead_Branch (N : Node_Id) return Boolean;
   --  @param N any node
   --  @return True if the node is in a branch that is statically dead. Only
   --      if-statements are detected for now.

   function May_Issue_Warning_On_Node (N : Node_Id) return Boolean;
   --  We do not issue any warnings on nodes which stem from inlining or
   --  instantiation, or in subprograms or library packages whose analysis
   --  has not been requested, such as subprograms that are always inlined
   --  in proof.

   function Shape_Of_Node (Node : Node_Id) return String;
   --  Return a string representing the shape of the Ada code surrounding the
   --  input node. This is used to name the VC file for manual proof.

   function Location_String (Input         : Source_Ptr;
                             Columns       : Boolean := True;
                             Chain_Markers : Boolean := True;
                             Natural_Order : Boolean := False) return String;
   --  Build a string that represents the source location of the source
   --  pointer. This includes the chain of generic instantiations.
   --  Columns - If set to False, remove column information from the string to
   --    keep only line information.
   --  Chain_Markers - If set to True, add strings to differentiate
   --    instances/inlining.
   --  Natural_Order - If set to True, build instantiation chain outermost
   --    first (e.g. location of instantiation before location of generic)

   ----------------------------------
   -- Queries for particular nodes --
   ----------------------------------

   function Aggregate_Is_In_Assignment (Expr : Node_Id) return Boolean with
     Pre => Expr in N_Aggregate_Kind_Id
       or else Is_Attribute_Update (Expr);
   --  Returns whether Expr is on the rhs of an assignment, either directly or
   --  through other enclosing aggregates, with possible type conversions and
   --  qualifications.

   type Unrolling_Type is
     (No_Unrolling,
      Simple_Unrolling,
      --  body of the loop repeated N times
      Unrolling_With_Condition
      --  value used for unrolling with a condition to check loop test, which
      --  is necessary when the loop has a dynamic range
     );

   function Is_Selected_For_Loop_Unrolling
     (Loop_Stmt : N_Loop_Statement_Id)
      return Boolean;
   --  Return whether [Loop_Stmt] is unrolled or not

   procedure Candidate_For_Loop_Unrolling
     (Loop_Stmt   : N_Loop_Statement_Id;
      Output_Info : Boolean;
      Result      : out Unrolling_Type;
      Low_Val     : out Uint;
      High_Val    : out Uint);
   --  @param Output_Info whether the reason for not unrolling should be
   --         displayed when the loop has no loop invariant, and a positive
   --         message that the loop is unrolled when applicable.
   --  @param Result whether a loop is a candidate for loop unrolling
   --  @param Low_Val the loop bound for loop unrolling
   --  @param High_Val the high bound for loop unrolling

   function Full_Entry_Name (N : Node_Id) return String
     with Pre => Nkind (N) in N_Expanded_Name
                            | N_Identifier
                            | N_Indexed_Component
                            | N_Selected_Component;
   --  @param N is a prefix of an entry call; it denotes either a stand-alone
   --     protected object or a protected component within a composite object
   --  @return a name that uniquely identifies the prefix

   function Generic_Actual_Subprograms (E : E_Package_Id) return Node_Sets.Set
   with Pre  => Is_Generic_Instance (E),
        Post => (for all S of Generic_Actual_Subprograms'Result =>
                    Is_Subprogram (S));
   --  @param E instance of a generic package (or a wrapper package for
   --    instances of generic subprograms)
   --  @return actual subprogram parameters of E

   function Get_Formal_From_Actual
     (Actual : N_Subexpr_Id)
      return Formal_Kind_Id
   with Pre  => Nkind (Parent (Actual)) in N_Subprogram_Call
                                         | N_Entry_Call_Statement
                                         | N_Parameter_Association
                                         | N_Unchecked_Type_Conversion;
   --  @param Actual actual parameter of a call (or expression of an unchecked
   --    conversion which comes from a rewritten call to instance of
   --    Ada.Unchecked_Conversion)
   --  @return the corresponding formal parameter

   function Get_Operator_Symbol (N : Node_Id) return String
     with Pre => Is_Operator_Symbol_Name (Chars (N));
   --  Lookup function (based on the contents of the Snames package) to
   --  convert "operator symbol" to a user-meaningful operator.

   function Get_Range (N : Node_Id) return Node_Id
     with Post => Present (Low_Bound (Get_Range'Result)) and then
                  Present (High_Bound (Get_Range'Result));
   --  @param N more or less any node which has some kind of range, e.g. a
   --     scalar type entity or occurrence, a variable of such type, the type
   --     declaration or a subtype indication.
   --  @return the N_Range node of such a node

   function Get_Observed_Or_Borrowed_Expr
     (Expr : N_Subexpr_Id)
      return N_Subexpr_Id
   with
     Pre => Is_Path_Expression (Expr);
   --  Return the expression being borrowed/observed when borrowing or
   --  observing Expr, as computed by Get_Observed_Or_Borrowed_Info.

   procedure Get_Observed_Or_Borrowed_Info
     (Expr   : N_Subexpr_Id;
      B_Expr : out N_Subexpr_Id;
      B_Ty   : in out Opt_Type_Kind_Id)
   with Pre => Is_Path_Expression (Expr);
   --  Compute both the expression being borrowed/observed when borrowing or
   --  observing Expr and the type used for this borrow/observe.
   --  @param Expr a path used for a borrow/observe
   --  @param B_Expr the expression being borrowed/observed when borrowing or
   --      observing Expr. If Expr contains a call to traversal function, this
   --      is the first actual of the first such call, otherwise it is Expr.
   --  @param B_Ty the type of the first borrower/observer in Expr. If Expr
   --      contains a call to traversal function, this is the type of the first
   --      formal of the function, otherwise it is B_Ty.
   --      Note that B_Ty is not the type of B_Expr but a compatible anonymous
   --      access type.

   function Get_Root_Object
     (Expr              : N_Subexpr_Id;
      Through_Traversal : Boolean := True)
      return Opt_Object_Kind_Id
   with
     Pre => Is_Path_Expression (Expr);
   --  Return the root of the path expression Expr, or Empty for an allocator,
   --  NULL, or a function call. Through_Traversal is True if it should follow
   --  through calls to traversal functions.

   function Get_Specialized_Parameters
     (Call                 : Node_Id;
      Specialized_Entities : Node_Maps.Map := Node_Maps.Empty_Map)
      return Node_Maps.Map;
   --  @param Call any node
   --  @param Specialized_Entities map of formal parameter which are
   --     specialized in the current context.
   --  @return a map which associates specialized formals in a function call
   --  with higher order specialization to the actual entity.

   function Is_Access_Attribute_Of_Function (Expr : Node_Id) return Boolean;
   --  Return True if Expr is an access attribute on a function identifier

   function Is_Action (N : N_Object_Declaration_Id) return Boolean;
   --  @param N is an object declaration
   --  @return if the given node N is an action

   function Is_Additional_Param_Of_Access_Subp_Wrapper
     (E : Formal_Kind_Id)
      return Boolean;
   --  Return True if E is the in parameter introduced for the
   --  access-to-subprogram object in a wrapper generated for an
   --  access-to-subprogram type with a contract.

   function Is_Converted_Actual_Output_Parameter
     (N : N_Subexpr_Id)
      return Boolean;
   --  @param N expression
   --  @return True iff N is either directly an out or in out actual parameter,
   --     or under one or multiple type conversions, where the most enclosing
   --     type conversion is an out or in out actual parameter.

   function Is_Call_Arg_To_Predicate_Function
     (N : Opt_N_Subexpr_Id)
      return Boolean;
   --  @param N expression node or Empty
   --  @return True iff N is the argument to a call to a frontend-generated
   --     predicate function. This should only occur when analyzing the code
   --     for the predicate function of a derived type, so the argument
   --     should take the form of a type conversion. Node N should be the
   --     expression being converted rather than the type conversion itself.

   function Is_Empty_Others
     (N : N_Case_Statement_Alternative_Id)
      return Boolean
   with Post => (if Is_Empty_Others'Result
                 then No (Next (N))
                   and then List_Length (Discrete_Choices (N)) = 1);
   --  Returns True iff N is an "others" case alternative with empty set
   --  of discrite choices (this set is statically determined by the front
   --  end). Such an alternative must not be followed by other alternatives
   --  and "others" must be its only choice.

   function Is_Error_Signaling_Statement (N : Node_Id) return Boolean;
   --  Returns True iff N is a statement used to signal an error:
   --    . a raise statement or expression
   --    . a pragma Assert (False)
   --    . a call to an error-signaling procedure
   --    . a call to a function with precondition False

   function Is_External_Call (N : N_Call_Id) return Boolean
   with Pre => Within_Protected_Type (Get_Called_Entity (N));
   --  @param N call node
   --  @return True iff N is an external call to a protected subprogram or
   --     a protected entry.
   --
   --  Note: calls to protected functions in preconditions and guards of the
   --  Contract_Cases are external, but this routine treats them as internal.
   --  However, the front end rejects these two cases. For the SPARK back end,
   --  this routine gives correct results.

   function Is_Path_Expression (Expr : N_Subexpr_Id) return Boolean;
   --  Return whether Expr corresponds to a path

   function Is_Strict_Subpath (Expr : N_Subexpr_Id) return Boolean
   with Pre => Is_Path_Expression (Expr)
     and then Present (Get_Root_Object (Expr));
   --  Return True is the structure referenced from Expr is a strictly
   --  smaller substructure of the structure referenced from its root.

   function Is_Predicate_Function_Call (N : Node_Id) return Boolean;
   --  @param N any node
   --  @return True iff N is a call to a frontend-generated predicate function

   function Is_Singleton_Choice (Choices : List_Id) return Boolean;
   --  Return whether Choices is a singleton choice

   function Is_Specializable_Formal (Formal : Formal_Kind_Id) return Boolean;
   --  Return True if Formal can be specialized, ie. it is an IN parameter of
   --  an anonymous access-to-function type.

   function Is_Specialized_Actual
     (Expr                 : Node_Id;
      Specialized_Entities : Node_Maps.Map := Node_Maps.Empty_Map)
      return Boolean;
   --  @param Expr any node
   --  @param Specialized_Entities map of formal parameter which are
   --     specialized in the current context.
   --  @return True iff Expr is a parameter of a call to a function annotated
   --     with higher order specialization and it needs special handling.

   function Is_Specialized_Call
     (Call                 : Node_Id;
      Specialized_Entities : Node_Maps.Map := Node_Maps.Empty_Map)
      return Boolean;
   --  @param Call any node
   --  @param Specialized_Entities map of formal parameter which are
   --     specialized in the current context.
   --  @return True if Call is a call to a function with higher order
   --  specialization which has at least a specialized parameter.
   --  ??? We could also consider the call to be specialized only if at
   --  least one of its specialized parameters has global inputs.

   function Is_Traversal_Function_Call (Expr : Node_Id) return Boolean;
   --  @param Expr any node
   --  @return True iff Expr is a call to a traversal function

   function Loop_Entity_Of_Exit_Statement
     (N : N_Exit_Statement_Id)
      return Entity_Id;
   --  Return the Defining_Identifier of the loop that belongs to an exit
   --  statement.

   function Number_Of_Assocs_In_Expression (N : Node_Id) return Natural;
   --  @param N any node
   --  @return the number of N_Component_Association nodes in N.

   function Expr_Has_Relaxed_Init
     (Expr    : N_Subexpr_Id;
      No_Eval : Boolean := True) return Boolean;
   --  Return True if Expr is an expression with relaxed initialization. If
   --  No_Eval is True, then we don't consider the expression to be evaluated.

   function Obj_Has_Relaxed_Init (Obj : Object_Kind_Id) return Boolean;
   --  Return True if Obj is an object with relaxed initialization

   function Fun_Has_Relaxed_Init (Subp : E_Function_Id) return Boolean;
   --  Return True if the result of Subp has relaxed initialization

   function Borrower_For_At_End_Borrow_Call
     (Call : N_Function_Call_Id)
      return Entity_Id;
   --  From a call to a function annotated with At_End_Borrow, get the entity
   --  whose scope the at end refers to.

   procedure Set_At_End_Borrow_Call
     (Call     : N_Function_Call_Id;
      Borrower : Entity_Id);
   --  Store the link between a call to a function annotated with
   --  At_End_Borrow and the entity whose scope the at end refers to.

   function Path_Contains_Traversal_Calls (Expr : N_Subexpr_Id) return Boolean
   with
     Pre => Is_Path_Expression (Expr);
   --  Return True if the path from Expr contains a call to a traversal
   --  function.

   function Traverse_Access_To_Constant (Expr : N_Subexpr_Id) return Boolean
   with
     Pre => Is_Path_Expression (Expr);
   --  Return True if the path from Expr goes through a dereference of an
   --  access-to-constant type.

   function Is_Rooted_In_Constant (Expr : N_Subexpr_Id) return Boolean;
   --  Return True if Expr is a path rooted inside a constant part of an
   --  object. We do not return True if Expr is rooted inside an IN parameter,
   --  as the actual might be a variable object.

   function Supported_Alias (Expr : Node_Id) return Entity_Id;
   --  If Expr is of the form "X'Address", return the root object of X.
   --  Otherwise, return Empty. This function accepts empty expressions.

   ---------------------------------
   -- Misc operations and queries --
   ---------------------------------

   procedure Append
     (To    : in out Node_Lists.List;
      Elmts : Node_Lists.List);
   --  Append all elements from list Elmts to the list To

   function Char_To_String_Representation (C : Character) return String;
   --  @param C a character to print in a counterexample
   --  @return a string representing the character for humans to read, which is
   --     the character itself if it is a graphic one, otherwise its name.

   function Get_Flat_Statement_And_Declaration_List
     (Stmts : List_Id) return Node_Lists.List;
   --  Given a list of statements and declarations Stmts, returns the flattened
   --  list that includes these statements and declarations, and recursively
   --  all inner declarations and statements that appear in block statements.
   --  Block statements are kept to mark the end of the corresponding scope,
   --  in order to apply some treatments at the end of local scopes, like
   --  checking the absence of resource leaks at the end of scope.

   function Is_Null_Owning_Access (Expr : Node_Id) return Boolean is
     (Nkind (Expr) = N_Null
      and then
        (Is_Anonymous_Access_Type (Etype (Expr))
         or else Is_Access_Variable (Etype (Expr))));
   --  Return True if Expr is exactly null and has an anomyous access type
   --  or an access-to-variable type.
   --  This is used to recognize actuals of calls which are not a part of a
   --  variable object though they are used as a mutable parameter.

   function Is_Others_Choice (Choices : List_Id) return Boolean;
   --  Returns True if Choices is the singleton list with an "others" element

   function Real_Image (U : Ureal; Max_Length : Integer) return String;
   --  Return a string, of maximum length Max_length, representing U.

   function String_Value (Str_Id : String_Id) return String
     with Pre => Str_Id /= No_String;

   function Append_Multiple_Index (S : String) return String;
   --  If the current file contains multiple units, add a suffix to S that
   --  corresponds to the currently analyzed unit.

   function Unit_Name return String is
     (Append_Multiple_Index
        (Ada.Directories.Base_Name
           (Get_Name_String (Unit_File_Name (Main_Unit)))));

   function File_Name (Loc : Source_Ptr) return String is
     (Get_Name_String (File_Name (Get_Source_File_Index (Loc))));
   --  @param Loc any source pointer
   --  @return the file name of the source pointer (will return the file of the
   --    generic in case of instances)

   function Contains_Volatile_Function_Call (N : Node_Id) return Boolean;
   --  @param N any node
   --  @return True iff the tree starting with N contains an N_Function_Call
   --    node whose callee is a function with pragma/aspect Volatile_Function
   --    set.

   function Contains_Allocator (N : Node_Id) return Boolean;
   --  @param N any node
   --  @return True iff the tree starting with N contains an N_Allocator
   --    node.

   function Contains_Cut_Operations (N : N_Subexpr_Id) return Boolean;
   --  @param N an expression
   --  @return True iff the tree starting with N contains a call to a cut
   --    operation. Takes advantage of the supported context for these nodes
   --    to cut branches.

   function Contains_Function_Call (N : Node_Id) return Boolean;
   --  Return True iff N contains an N_Function_Call node

   function Safe_First_Sloc (N : Node_Id) return Source_Ptr
   with Post => (N = Empty) = (Safe_First_Sloc'Result = No_Location);
   --  Wrapper for First_Sloc that is safe to use for nodes coming from
   --  instances of generic units and subprograms inlined for proof.
   --  For valid nodes it returns a valid location; for an empty node it
   --  returns an invalid location.
   --
   --  ??? this is only a temporary fix and should be removed once the
   --  underlying problem with First_Sloc is fixed.

   function Safe_Last_Sloc (N : Node_Id) return Source_Ptr;
   --  Wrapper for Last_Sloc, similar to Safe_First_Sloc.

   function Entity_To_Subp_Assumption (E : Entity_Id) return Subp_Type
   with Pre => (if Is_Internal (E)
                then Is_Type (E) or else Is_Predicate_Function (E));
   --  Transform an entity into a Assumption_Types.Subp_Type
   --  ??? At the moment we are checking whether E is a predicate function but
   --  this will have to be removed as soon as we will not create graphs for
   --  type predicates.

   function Unique_Main_Unit_Entity return Entity_Id
   with Post => Ekind (Unique_Main_Unit_Entity'Result) in E_Function
                                                        | E_Procedure
                                                        | E_Package
                                                        | Generic_Unit_Kind;
   --  Wrapper for Lib.Main_Unit_Entity, which deals with library-level
   --  instances of generic subprograms (where the Main_Unit_Entity has a
   --  void Ekind).

   function Attr_Constrained_Statically_Known (N : Node_Id) return Boolean;
   --  Approximation of cases where we know that the Constrained attribute of
   --  N is known statically.

   function Statement_Enclosing_Label (E : E_Label_Id) return Node_Id;
   --  Return the parent of the N_Label node associated to E

   function States_And_Objects (E : E_Package_Id) return Node_Sets.Set
   with Pre  => not Is_Wrapper_Package (E),
        Post => (for all Obj of States_And_Objects'Result =>
                    Ekind (Obj) in E_Abstract_State | E_Constant | E_Variable);
   --  Return objects that can appear on the LHS of the Initializes contract
   --  for a package E.

   function Conversion_Is_Move_To_Constant (Expr : Node_Id) return Boolean with
     Pre => Nkind (Expr) in N_Type_Conversion | N_Unchecked_Type_Conversion;
   --  Return True if a conversion can cause an object to be moved.
   --  Currently, we return True iff:
   --    * We are converting from an access-to-variable type to a named
   --      access-to-constant type
   --    * The prefix is not part of a constant and we are not in an assertion,
   --      otherwise this is not a move.

   function Value_Is_Never_Leaked (Expr : N_Subexpr_Id) return Boolean;
   --  Checks whether a created access value is known to never leak

   procedure Structurally_Decreases_In_Call
     (Param       : Formal_Kind_Id;
      Call        : N_Call_Id;
      Result      : out Boolean;
      Explanation : out Unbounded_String);
   --  Return True if Param is a structural variant for the recursive call Call

   procedure Structurally_Decreases_In_Loop
     (Brower      : Entity_Id;
      Loop_Stmt   : N_Loop_Statement_Id;
      Result      : out Boolean;
      Explanation : out Unbounded_String);
   --  Return True if Brower is a structural variant for Loop_Stmt

   procedure Register_Exception (E : E_Exception_Id);
   --  Register an exception

   function All_Exceptions return Node_Sets.Set;
   --  Get all the exceptions visible from analyzed code

   function Might_Raise_Exceptions (E : Entity_Id) return Boolean is
     (Present (Get_Pragma (E, Pragma_Exceptional_Cases)));

   function Exception_Handled
     (E    : E_Exception_Id;
      Stmt : Node_Id)
      return Boolean;
   --  Return True is a raise of E is handled above Stmt. For now, this occurs
   --  only if Stmt occurs in the body of a subprogram annotated with
   --  Exceptional_Cases.

   procedure Collect_Raised_Exceptions
     (Subp    : Entity_Id;
      All_Exc : out Boolean;
      Exc_Set : out Node_Sets.Set)
   with Post => (if All_Exc then Exc_Set.Is_Empty);
   --  Retrieve all exceptions raise by Subp. If any exception can be raise,
   --  then All_Exc is set to True. Otherwise raised exceptions are stored in
   --  Exc_Set.

   procedure Collect_Handled_Exceptions
     (Call    : Node_Id;
      All_Exc : out Boolean;
      Exc_Set : out Node_Sets.Set)
   with Post => (if All_Exc then Exc_Set.Is_Empty);
   --  Retrieve all exceptions raise by Call handled above it. If all
   --  exceptions are handled, All_Exc is set to True. Otherwise handled
   --  exceptions are stored in Exc_Set.

   function Call_Raises_Handled_Exceptions (Call : Node_Id) return Boolean;
   --  Return True if a call needs handling for exceptional paths

   function By_Copy (Obj : Formal_Kind_Id) return Boolean;
   --  Return True if Obj is known to be passed by copy. In parameters of an
   --  access-to-variable type are considered to be passed by reference in
   --  accordance to ownership principles.

   function By_Reference (Obj : Formal_Kind_Id) return Boolean;
   --  Return True if Obj is known to be passed by reference. See above.

end SPARK_Util;
