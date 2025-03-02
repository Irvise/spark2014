------------------------------------------------------------------------------
--                                                                          --
--                            GNAT2WHY COMPONENTS                           --
--                                                                          --
--                            S P A R K _ U T I L                           --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--                     Copyright (C) 2011-2023, AdaCore                     --
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

with Ada.Characters.Latin_1;      use Ada.Characters.Latin_1;
with Ada.Text_IO;
with Common_Iterators;            use Common_Iterators;
with Errout;                      use Errout;
with Flow_Dependency_Maps;        use Flow_Dependency_Maps;
with Flow_Refinement;             use Flow_Refinement;
with Flow_Types;                  use Flow_Types;
with Flow_Utility;                use Flow_Utility;
with Flow_Utility.Initialization; use Flow_Utility.Initialization;
with GNATCOLL.Utils;              use GNATCOLL.Utils;
with Gnat2Why_Args;
with Lib.Xref;
with Opt;
with Osint;
with Output;
with Pprint;                      use Pprint;
with SPARK_Definition;            use SPARK_Definition;
with SPARK_Definition.Annotate;   use SPARK_Definition.Annotate;
with SPARK_Util.Hardcoded;        use SPARK_Util.Hardcoded;
with SPARK_Util.Subprograms;      use SPARK_Util.Subprograms;
with SPARK_Util.Types;            use SPARK_Util.Types;
with Sem_Ch12;                    use Sem_Ch12;
with Sem_Eval;                    use Sem_Eval;
with Sem_Prag;                    use Sem_Prag;
with Sem_Type;                    use Sem_Type;
with Sinfo.Utils;                 use Sinfo.Utils;
with Stand;                       use Stand;
with Stringt;                     use Stringt;

package body SPARK_Util is

   -----------------------
   -- Local Subprograms --
   -----------------------

   function No_Deep_Updates
     (Stmts       : List_Id;
      Variable    : Entity_Id;
      Explanation : out Unbounded_String;
      Decls       : List_Id := No_List;
      End_Stmt    : Node_Id := Empty) return Boolean;
   --  Return True if Decls & Stmts contains no updates to a deep part of
   --  Variable. Stop before the statement End_Stmt if any. If an update is
   --  found, check that it is not followed by a return statement in the
   --  sequence of statement. If it is, the update is in a path which does not
   --  lead to the next iteration or the next recursive call, so it can be
   --  ignored. If a deep update is found, Explanation is set.

   Goto_Found : exception;

   function Is_Reborrowed_On_All_Paths
     (Stmts       : List_Id;
      Brower      : Entity_Id;
      Explanation : out Unbounded_String;
      Decls       : List_Id := No_List;
      End_Stmt    : Node_Id := Empty) return Boolean;
   --  Traverse recursively the list of statements Decls & Stmts and check that
   --  there is at least an update of Brower with a strict subpath of itself
   --  on all program paths which do not exit the loop.
   --  Raise Goto_Found if a goto statement is encountered before any
   --  reborrows on a particular path. They are not handled precisely.
   --  Stop before the statement End_Stmt if any. If Brower is not reborrowed
   --  on all paths, Explanation is set.

   ------------------------------
   -- Extra tables on entities --
   ------------------------------

   Partial_Views : Node_Maps.Map;
   --  Map from full views of entities to their partial views, for deferred
   --  constants and private types.

   Overlay_Aliases : Node_Graphs.Map;
   --  Map from an entity to all its overlay aliases. This map is filled during
   --  marking and queried (via a getter function) during flow and proof.
   --  ??? this could be a map from nodes to lists of nodes (not set of nodes)

   Exceptions : Node_Sets.Set;
   --  All exceptions visible from analyzed code

   ----------------------
   -- Set_Partial_View --
   ----------------------

   procedure Set_Partial_View (E, V : Entity_Id) is
   begin
      Partial_Views.Insert (E, V);
   end Set_Partial_View;

   ------------------
   -- Partial_View --
   ------------------

   function Partial_View (E : Entity_Id) return Entity_Id
   is
      C : constant Node_Maps.Cursor := Partial_Views.Find (E);
      use Node_Maps;

   begin
      return (if Has_Element (C)
              then Element (C)
              else Standard.Types.Empty);
   end Partial_View;

   ---------------------------
   -- Is_For_Loop_Parameter --
   ---------------------------

   function Is_For_Loop_Parameter (E : Entity_Id) return Boolean is
     (Ekind (E) = E_Loop_Parameter
      and then Nkind (Parent (E)) = N_Loop_Parameter_Specification);

   ------------------
   -- Is_Full_View --
   ------------------

   function Is_Full_View (E : Entity_Id) return Boolean is
     (Present (Partial_View (E)));

   ---------------------
   -- Is_Partial_View --
   ---------------------

   function Is_Partial_View (E : Entity_Id) return Boolean is
     ((Is_Type (E) or else Ekind (E) = E_Constant) and then
        Present (Full_View (E)));

   Specific_Tagged_Types : Node_Maps.Map;
   --  Map from classwide types to the corresponding specific tagged type

   -------------------------
   -- Set_Specific_Tagged --
   -------------------------

   procedure Set_Specific_Tagged (E : Class_Wide_Kind_Id; V : Record_Kind_Id)
   is
   begin
      Specific_Tagged_Types.Insert
        (E,
         (if Is_Full_View (V)
            and then Full_View_Not_In_SPARK (Partial_View (V))
          then Partial_View (V)
          else V));
   end Set_Specific_Tagged;

   ---------------------
   -- Specific_Tagged --
   ---------------------

   function Specific_Tagged (E : Class_Wide_Kind_Id) return Record_Kind_Id is
   begin
      return Specific_Tagged_Types.Element (E);
   end Specific_Tagged;

   -----------------------
   -- Set_Overlay_Alias --
   -----------------------

   procedure Set_Overlay_Alias (New_Id, Old_Id : Object_Kind_Id) is
      New_Aliases : Node_Sets.Set;
      C           : Node_Graphs.Cursor;
      Inserted    : Boolean;
   begin
      --  Find existing aliases of Old_Id

      Overlay_Aliases.Insert (Key      => Old_Id,
                              Position => C,
                              Inserted => Inserted);

      --  New_Id is overlaying all the aliases of Old_Id; all those aliases of
      --  Old_Id overlay New_Id as well.

      for Old_Alias of Overlay_Aliases (C) loop
         New_Aliases.Insert (Old_Alias);
         Overlay_Aliases (Old_Alias).Insert (New_Id);
      end loop;

      --  New_Id is overlaying the Old_Id; Old_Id is overlaying New_Id as well

      New_Aliases.Insert (Old_Id);
      Overlay_Aliases (C).Insert (New_Id);

      --  Finally, move the collected aliases of New_Id to map

      Overlay_Aliases.Insert (Key      => New_Id,
                              Position => C,
                              Inserted => Inserted);
      pragma Assert (Inserted);

      Node_Sets.Move (Target => Overlay_Aliases (C),
                      Source => New_Aliases);
   end Set_Overlay_Alias;

   -------------------
   -- Overlay_Alias --
   -------------------

   function Overlay_Alias (E : Object_Kind_Id) return Node_Sets.Set is
      C : constant Node_Graphs.Cursor := Overlay_Aliases.Find (E);
      use Node_Graphs;
   begin
      --  Given that the alias set for E contains E itself, we remove it here

      if Has_Element (C) then
         return Overlay_Aliases (C);
      else
         return Node_Sets.Empty_Set;
      end if;

   end Overlay_Alias;

   ------------------------
   -- Register_Exception --
   ------------------------

   procedure Register_Exception (E : E_Exception_Id) is
   begin
      Exceptions.Include (E);
   end Register_Exception;

   --------------------
   -- All_Exceptions --
   --------------------

   function All_Exceptions return Node_Sets.Set is (Exceptions);

   ---------------------------------
   -- Extra tables on expressions --
   ---------------------------------

   Dispatching_Contracts : Node_Maps.Map;
   --  Map from classwide pre- and postcondition expressions to versions of
   --  the same expressions where the type of the controlling operand is of
   --  class-wide type, and corresponding calls to primitive subprograms are
   --  dispatching calls.

   At_End_Borrow_Call_Map : Node_Maps.Map;
   --  Map from calls to functions annotated with At_End_Borrow to the related
   --  borrower entity.

   -------------------------------------
   -- Borrower_For_At_End_Borrow_Call --
   -------------------------------------

   function Borrower_For_At_End_Borrow_Call
     (Call : N_Function_Call_Id)
      return Entity_Id
   is
      Cu : constant Node_Maps.Cursor := At_End_Borrow_Call_Map.Find (Call);
   begin
      if Node_Maps.Has_Element (Cu) then
         return Node_Maps.Element (Cu);
      else
         return Empty;
      end if;
   end Borrower_For_At_End_Borrow_Call;

   --------------------------
   -- Dispatching_Contract --
   --------------------------

   function Dispatching_Contract (C : Node_Id) return Node_Id is
      Primitive : constant Node_Maps.Cursor := Dispatching_Contracts.Find (C);
      use Node_Maps;

   begin
      return (if Has_Element (Primitive)
              then Element (Primitive)
              else Standard.Types.Empty);
   end Dispatching_Contract;

   ----------------------------
   -- Set_At_End_Borrow_Call --
   ----------------------------

   procedure Set_At_End_Borrow_Call
     (Call     : N_Function_Call_Id;
      Borrower : Entity_Id)
   is
      Inserted : Boolean;
      Position : Node_Maps.Cursor;
   begin
      At_End_Borrow_Call_Map.Insert (Call, Borrower, Position, Inserted);
      pragma Assert (Inserted or else Node_Maps.Element (Position) = Borrower);
   end Set_At_End_Borrow_Call;

   ------------------------------
   -- Set_Dispatching_Contract --
   ------------------------------

   procedure Set_Dispatching_Contract (C, D : Node_Id) is
   begin
      Dispatching_Contracts.Insert (C, D);
   end Set_Dispatching_Contract;

   --------------------------------
   -- Aggregate_Is_In_Assignment --
   --------------------------------

   function Aggregate_Is_In_Assignment (Expr : Node_Id) return Boolean is
      P    : Node_Id := Parent (Expr);
      Prev : Node_Id := Expr;

   begin
      while Present (P) loop
         --  Check if we reached an assignment from its expression

         if Nkind (P) = N_Assignment_Statement
           and then Prev = Expression (P)
         then
            return True;
         end if;

         case Nkind (P) is
            when N_Qualified_Expression
               | N_Type_Conversion
               | N_Unchecked_Type_Conversion
            =>
               null;

            --  Reach past an enclosing aggregate

            when N_Aggregate
               | N_Delta_Aggregate
               | N_Extension_Aggregate
            =>
               null;

            --  Deep aggregate cannot be the prefix of an expression (SPARK RM
            --  3.10(6)) except for the special case of 'Update.

            when N_Attribute_Reference =>
               pragma Assert (Attribute_Name (P) = Name_Update);

            --  In other cases, the aggregate is not directly on the rhs of
            --  an assignment.

            when others =>
               return False;
         end case;

         Prev := P;
         P := Parent (P);
      end loop;

      raise Program_Error;
   end Aggregate_Is_In_Assignment;

   ---------------------------
   -- Append_Multiple_Index --
   ---------------------------

   function Append_Multiple_Index (S : String) return String is
   begin
      if Opt.Multiple_Unit_Index = 0 then
         return S;
      end if;
      declare
         Int_Str : constant String := Int'Image (Opt.Multiple_Unit_Index);
      begin
         return S & Osint.Multi_Unit_Index_Character &
           Int_Str (Int_Str'First + 1 .. Int_Str'Last);
      end;
   end Append_Multiple_Index;

   ------------
   -- Append --
   ------------

   procedure Append
     (To    : in out Node_Lists.List;
      Elmts : Node_Lists.List) is
   begin
      for E of Elmts loop
         To.Append (E);
      end loop;
   end Append;

   ---------------------------------------
   -- Attr_Constrained_Statically_Known --
   ---------------------------------------

   function Attr_Constrained_Statically_Known (N : Node_Id) return Boolean is
     (Nkind (N) not in N_Expanded_Name | N_Identifier
      or else Ekind (Entity (N)) not in
        E_Variable | E_Out_Parameter | E_In_Out_Parameter);

   -------------
   -- By_Copy --
   -------------

   function By_Copy (Obj : Formal_Kind_Id) return Boolean is
     (not By_Reference (Obj)
      and then Is_By_Copy_Type (Etype (Obj)));

   ------------------
   -- By_Reference --
   ------------------

   function By_Reference (Obj : Formal_Kind_Id) return Boolean is
     (Is_By_Reference_Type (Etype (Obj))
      or else Is_Aliased (Obj)
      or else (Ekind (Obj) = E_In_Parameter
        and then Is_Access_Variable (Etype (Obj))));

   ------------------------------------
   -- Call_Raises_Handled_Exceptions --
   ------------------------------------

   function Call_Raises_Handled_Exceptions (Call : Node_Id) return Boolean is
      All_Handled : Boolean;
      Handled_Exc : Node_Sets.Set;
   begin
      if Might_Raise_Exceptions (Get_Called_Entity (Call)) then
         Collect_Handled_Exceptions (Call, All_Handled, Handled_Exc);
         return All_Handled or else not Handled_Exc.Is_Empty;
      end if;

      return False;
   end Call_Raises_Handled_Exceptions;

   ----------------------
   -- Canonical_Entity --
   ----------------------

   function Canonical_Entity
     (Ref     : Entity_Id;
      Context : Entity_Id)
      return Entity_Id
   is
   begin
      if Is_Single_Concurrent_Object (Ref)
        and then Is_CCT_Instance (Ref_Id => Etype (Ref), Context_Id => Context)
      then
         return Etype (Ref);
      elsif Has_Non_Limited_View (Ref) then
         --  ??? this partly duplicates a similar transformatioin in
         --  Direct_Mapping_Id; maybe it should be done once, in SPARK_Rewrite.
         return Unique_Entity (Non_Limited_View (Ref));
      else
         return Unique_Entity (Ref);
      end if;
   end Canonical_Entity;

   ----------------------------------
   -- Candidate_For_Loop_Unrolling --
   ----------------------------------

   procedure Candidate_For_Loop_Unrolling
     (Loop_Stmt   : N_Loop_Statement_Id;
      Output_Info : Boolean;
      Result      : out Unrolling_Type;
      Low_Val     : out Uint;
      High_Val    : out Uint)
   is
      Reason : Unbounded_String;
      --  Reason to output for not unrolling the loop

      -----------------------
      -- Local Subprograms --
      -----------------------

      function Is_Applicable_Loop_Variant_Or_Invariant
        (N : Node_Id) return Traverse_Result;
      --  Returns Abandon when a loop (in)variant applicable to the loop is
      --  encountered and OK otherwise.

      function Is_Non_Scalar_Object_Declaration
        (N : Node_Id) return Traverse_Result;
      --  Returns Abandon when an object declaration of a non-scalar type is
      --  encountered and OK otherwise. Update [Reason] accordingly.

      ---------------------------------------------
      -- Is_Applicable_Loop_Variant_Or_Invariant --
      ---------------------------------------------

      function Is_Applicable_Loop_Variant_Or_Invariant
        (N : Node_Id) return Traverse_Result
      is
         Par : Node_Id;
      begin
         if Is_Pragma_Check (N, Name_Loop_Invariant)
           or else Is_Pragma (N, Pragma_Loop_Variant)
         then
            Par := N;
            while Nkind (Par) /= N_Loop_Statement loop
               Par := Parent (Par);
            end loop;

            if Par = Loop_Stmt then
               return Abandon;
            end if;
         end if;

         return OK;
      end Is_Applicable_Loop_Variant_Or_Invariant;

      function Find_Applicable_Loop_Variant_Or_Invariant is new
        Traverse_More_Func (Is_Applicable_Loop_Variant_Or_Invariant);

      --------------------------------------
      -- Is_Non_Scalar_Object_Declaration --
      --------------------------------------

      function Is_Non_Scalar_Object_Declaration
        (N : Node_Id) return Traverse_Result
      is
      begin
         case Nkind (N) is
            when N_Object_Declaration =>
               if not Is_Scalar_Type (Etype (Defining_Identifier (N))) then
                  Error_Msg_Sloc := Sloc (N);
                  Reason :=
                    To_Unbounded_String ("local non-scalar declaration #");
                  return Abandon;
               end if;

            when others =>
               null;
         end case;

         return OK;
      end Is_Non_Scalar_Object_Declaration;

      function Find_Non_Scalar_Object_Declaration is new
        Traverse_More_Func (Is_Non_Scalar_Object_Declaration);

      ---------------------
      -- Local Variables --
      ---------------------

      Scheme     : constant Node_Id := Iteration_Scheme (Loop_Stmt);
      Loop_Spec  : constant Node_Id :=
        (if Present (Scheme) and then No (Condition (Scheme)) then
           Loop_Parameter_Specification (Scheme)
         else Empty);
      Over_Range : constant Boolean := Present (Loop_Spec);
      Over_Node  : constant Node_Id :=
        (if Over_Range then Discrete_Subtype_Definition (Loop_Spec)
         else Empty);

      Low, High     : Node_Id;
      Dynamic_Range : Boolean := False;

   --  Start of processing for Candidate_For_Unrolling

   begin
      Low_Val  := No_Uint;
      High_Val := No_Uint;
      Result   := No_Unrolling;

      --  Only simple FOR loops can be unrolled. Simple loops are
      --  defined as having no (in)variant...

      if Over_Range
        and then Find_Applicable_Loop_Variant_Or_Invariant (Loop_Stmt)
                 /= Abandon
      then
         Low  := Low_Bound (Get_Range (Over_Node));
         High := High_Bound (Get_Range (Over_Node));

         --  and the low bound is static, or consider instead the low bound of
         --  its type...

         if not Compile_Time_Known_Value (Low) then
            Low := Type_Low_Bound (Unchecked_Full_Type (Etype (Low)));
            Dynamic_Range := True;
         end if;

         --  and the high bound is static, or consider instead the high bound
         --  of its type...

         if not Compile_Time_Known_Value (High) then
            High := Type_High_Bound (Unchecked_Full_Type (Etype (High)));
            Dynamic_Range := True;
         end if;

         --  and compile-time known bounds, with a small number of
         --  iterations...

         if Compile_Time_Known_Value (Low)
           and then Compile_Time_Known_Value (High)
         then
            Low_Val  := Expr_Value (Low);
            High_Val := Expr_Value (High);

            if Low_Val <= High_Val
              and then High_Val < Low_Val + Gnat2Why_Args.Max_Loop_Unrolling

              --  (also checking that the bounds fit in an Int, so that we can
              --  convert them using UI_To_Int)

              and then Low_Val >= UI_From_Int (Int'First)
              and then High_Val <= UI_From_Int (Int'Last)
            then
               --  and either the loop is from 1 to 1, or more generally from
               --  a value to the same value (a trick to emulate forward gotos,
               --  by exiting from the loop instead) so that there are no
               --  issues with the type of an object declared in the loop
               --  having contradictory constraints across loop iterations

               if Low_Val = High_Val

               --  or there are no non-scalar object declarations, precisely to
               --  avoid that their types have contradictory constraints across
               --  loop iterations.

                 or else Find_Non_Scalar_Object_Declaration (Loop_Stmt)
                   /= Abandon
               then
                  --  Loop can be unrolled. Decide the type of unrolling based
                  --  on whether the range is static or dynamic.

                  Result := (if Dynamic_Range then Unrolling_With_Condition
                             else Simple_Unrolling);
               end if;

            else
               if High_Val >= Low_Val + Gnat2Why_Args.Max_Loop_Unrolling then
                  Reason := To_Unbounded_String ("too many loop iterations");
               else
                  Reason := To_Unbounded_String ("value of loop bounds");
               end if;
            end if;

         else
            Reason := To_Unbounded_String ("dynamic loop bounds");
         end if;

         if Output_Info then
            if Result /= No_Unrolling then
               Error_Msg_N ("info: ?unrolling loop", Loop_Stmt);

            else
               pragma Assert (Reason /= "");
               Error_Msg_N
                 ("info: ?cannot unroll loop (" & To_String (Reason) & ")",
                  Loop_Stmt);
            end if;
         end if;
      end if;
   end Candidate_For_Loop_Unrolling;

   -----------------------------------
   -- Char_To_String_Representation --
   -----------------------------------

   function Char_To_String_Representation (C : Character) return String is
   begin
      pragma Annotate
        (Xcov, Exempt_On,
         "trivial code that would be difficult to fully cover");
      case C is

      --  Graphic characters are printed directly

      when Graphic_Character =>
         return String'(1 => C);

      --  Other characters are printed as their enumeration name in the
      --  Character enumeration in GNAT. Character'Image is not usable to get
      --  the names as it returns the character itself instead of a name for C
      --  greater than 160.

      when NUL                         => return "NUL";
      when SOH                         => return "SOH";
      when STX                         => return "STX";
      when ETX                         => return "ETX";
      when EOT                         => return "EOT";
      when ENQ                         => return "ENQ";
      when ACK                         => return "ACK";
      when BEL                         => return "BEL";
      when BS                          => return "BS";
      when HT                          => return "HT";
      when LF                          => return "LF";
      when VT                          => return "VT";
      when FF                          => return "FF";
      when CR                          => return "CR";
      when SO                          => return "SO";
      when SI                          => return "SI";

      when DLE                         => return "DLE";
      when DC1                         => return "DC1";
      when DC2                         => return "DC2";
      when DC3                         => return "DC3";
      when DC4                         => return "DC4";
      when NAK                         => return "NAK";
      when SYN                         => return "SYN";
      when ETB                         => return "ETB";
      when CAN                         => return "CAN";
      when EM                          => return "EM";
      when SUB                         => return "SUB";
      when ESC                         => return "ESC";
      when FS                          => return "FS";
      when GS                          => return "GS";
      when RS                          => return "RS";
      when US                          => return "US";

      when DEL                         => return "DEL";
      when Reserved_128                => return "Reserved_128";
      when Reserved_129                => return "Reserved_129";
      when BPH                         => return "BPH";
      when NBH                         => return "NBH";
      when Reserved_132                => return "Reserved_132";
      when NEL                         => return "NEL";
      when SSA                         => return "SSA";
      when ESA                         => return "ESA";
      when HTS                         => return "HTS";
      when HTJ                         => return "HTJ";
      when VTS                         => return "VTS";
      when PLD                         => return "PLD";
      when PLU                         => return "PLU";
      when RI                          => return "RI";
      when SS2                         => return "SS2";
      when SS3                         => return "SS3";

      when DCS                         => return "DCS";
      when PU1                         => return "PU1";
      when PU2                         => return "PU2";
      when STS                         => return "STS";
      when CCH                         => return "CCH";
      when MW                          => return "MW";
      when SPA                         => return "SPA";
      when EPA                         => return "EPA";

      when SOS                         => return "SOS";
      when Reserved_153                => return "Reserved_153";
      when SCI                         => return "SCI";
      when CSI                         => return "CSI";
      when ST                          => return "ST";
      when OSC                         => return "OSC";
      when PM                          => return "PM";
      when APC                         => return "APC";

      when No_Break_Space              => return "No_Break_Space";
      when Inverted_Exclamation        => return "Inverted_Exclamation";
      when Cent_Sign                   => return "Cent_Sign";
      when Pound_Sign                  => return "Pound_Sign";
      when Currency_Sign               => return "Currency_Sign";
      when Yen_Sign                    => return "Yen_Sign";
      when Broken_Bar                  => return "Broken_Bar";
      when Section_Sign                => return "Section_Sign";
      when Diaeresis                   => return "Diaeresis";
      when Copyright_Sign              => return "Copyright_Sign";
      when Feminine_Ordinal_Indicator  => return "Feminine_Ordinal_Indicator";
      when Left_Angle_Quotation        => return "Left_Angle_Quotation";
      when Not_Sign                    => return "Not_Sign";
      when Soft_Hyphen                 => return "Soft_Hyphen";
      when Registered_Trade_Mark_Sign  => return "Registered_Trade_Mark_Sign";
      when Macron                      => return "Macron";
      when Degree_Sign                 => return "Degree_Sign";
      when Plus_Minus_Sign             => return "Plus_Minus_Sign";
      when Superscript_Two             => return "Superscript_Two";
      when Superscript_Three           => return "Superscript_Three";
      when Acute                       => return "Acute";
      when Micro_Sign                  => return "Micro_Sign";
      when Pilcrow_Sign                => return "Pilcrow_Sign";
      when Middle_Dot                  => return "Middle_Dot";
      when Cedilla                     => return "Cedilla";
      when Superscript_One             => return "Superscript_One";
      when Masculine_Ordinal_Indicator => return "Masculine_Ordinal_Indicator";
      when Right_Angle_Quotation       => return "Right_Angle_Quotation";
      when Fraction_One_Quarter        => return "Fraction_One_Quarter";
      when Fraction_One_Half           => return "Fraction_One_Half";
      when Fraction_Three_Quarters     => return "Fraction_Three_Quarters";
      when Inverted_Question           => return "Inverted_Question";

      when UC_A_Grave                  => return "UC_A_Grave";
      when UC_A_Acute                  => return "UC_A_Acute";
      when UC_A_Circumflex             => return "UC_A_Circumflex";
      when UC_A_Tilde                  => return "UC_A_Tilde";
      when UC_A_Diaeresis              => return "UC_A_Diaeresis";
      when UC_A_Ring                   => return "UC_A_Ring";
      when UC_AE_Diphthong             => return "UC_AE_Diphthong";
      when UC_C_Cedilla                => return "UC_C_Cedilla";
      when UC_E_Grave                  => return "UC_E_Grave";
      when UC_E_Acute                  => return "UC_E_Acute";
      when UC_E_Circumflex             => return "UC_E_Circumflex";
      when UC_E_Diaeresis              => return "UC_E_Diaeresis";
      when UC_I_Grave                  => return "UC_I_Grave";
      when UC_I_Acute                  => return "UC_I_Acute";
      when UC_I_Circumflex             => return "UC_I_Circumflex";
      when UC_I_Diaeresis              => return "UC_I_Diaeresis";
      when UC_Icelandic_Eth            => return "UC_Icelandic_Eth";
      when UC_N_Tilde                  => return "UC_N_Tilde";
      when UC_O_Grave                  => return "UC_O_Grave";
      when UC_O_Acute                  => return "UC_O_Acute";
      when UC_O_Circumflex             => return "UC_O_Circumflex";
      when UC_O_Tilde                  => return "UC_O_Tilde";
      when UC_O_Diaeresis              => return "UC_O_Diaeresis";

      when Multiplication_Sign         => return "Multiplication_Sign";

      when UC_O_Oblique_Stroke         => return "UC_O_Oblique_Stroke";
      when UC_U_Grave                  => return "UC_U_Grave";
      when UC_U_Acute                  => return "UC_U_Acute";
      when UC_U_Circumflex             => return "UC_U_Circumflex";
      when UC_U_Diaeresis              => return "UC_U_Diaeresis";
      when UC_Y_Acute                  => return "UC_Y_Acute";
      when UC_Icelandic_Thorn          => return "UC_Icelandic_Thorn";

      when LC_German_Sharp_S           => return "LC_German_Sharp_S";
      when LC_A_Grave                  => return "LC_A_Grave";
      when LC_A_Acute                  => return "LC_A_Acute";
      when LC_A_Circumflex             => return "LC_A_Circumflex";
      when LC_A_Tilde                  => return "LC_A_Tilde";
      when LC_A_Diaeresis              => return "LC_A_Diaeresis";
      when LC_A_Ring                   => return "LC_A_Ring";
      when LC_AE_Diphthong             => return "LC_AE_Diphthong";
      when LC_C_Cedilla                => return "LC_C_Cedilla";
      when LC_E_Grave                  => return "LC_E_Grave";
      when LC_E_Acute                  => return "LC_E_Acute";
      when LC_E_Circumflex             => return "LC_E_Circumflex";
      when LC_E_Diaeresis              => return "LC_E_Diaeresis";
      when LC_I_Grave                  => return "LC_I_Grave";
      when LC_I_Acute                  => return "LC_I_Acute";
      when LC_I_Circumflex             => return "LC_I_Circumflex";
      when LC_I_Diaeresis              => return "LC_I_Diaeresis";
      when LC_Icelandic_Eth            => return "LC_Icelandic_Eth";
      when LC_N_Tilde                  => return "LC_N_Tilde";
      when LC_O_Grave                  => return "LC_O_Grave";
      when LC_O_Acute                  => return "LC_O_Acute";
      when LC_O_Circumflex             => return "LC_O_Circumflex";
      when LC_O_Tilde                  => return "LC_O_Tilde";
      when LC_O_Diaeresis              => return "LC_O_Diaeresis";

      when Division_Sign               => return "Division_Sign";

      when LC_O_Oblique_Stroke         => return "LC_O_Oblique_Stroke";
      when LC_U_Grave                  => return "LC_U_Grave";
      when LC_U_Acute                  => return "LC_U_Acute";
      when LC_U_Circumflex             => return "LC_U_Circumflex";
      when LC_U_Diaeresis              => return "LC_U_Diaeresis";
      when LC_Y_Acute                  => return "LC_Y_Acute";
      when LC_Icelandic_Thorn          => return "LC_Icelandic_Thorn";
      when LC_Y_Diaeresis              => return "LC_Y_Diaeresis";
      end case;
      pragma Annotate (Xcov, Exempt_Off);
   end Char_To_String_Representation;

   --------------------------------
   -- Collect_Handled_Exceptions --
   --------------------------------

   procedure Collect_Handled_Exceptions
     (Call    : Node_Id;
      All_Exc : out Boolean;
      Exc_Set : out Node_Sets.Set)
   is
      function Is_Body (N : Node_Id) return Boolean is
        (Nkind (N) in N_Entity_Body);

      function Enclosing_Body is new
        First_Parent_With_Property (Is_Body);

      Scop   : constant Node_Id := Enclosing_Body (Call);
      Caller : constant Entity_Id :=
        (if Nkind (Scop) = N_Subprogram_Body
         then Unique_Defining_Entity (Scop) else Empty);
      Callee : constant Entity_Id := Get_Called_Entity (Call);

   begin
      Exc_Set := Node_Sets.Empty_Set;

      if not Might_Raise_Exceptions (Callee) then
         All_Exc := True;
      elsif No (Caller) or else not Might_Raise_Exceptions (Caller) then
         All_Exc := False;
      else
         declare
            Caller_All_Exc : Boolean;
            Caller_Exc_Set : Node_Sets.Set;
            Callee_All_Exc : Boolean;
            Callee_Exc_Set : Node_Sets.Set;
         begin
            Collect_Raised_Exceptions (Caller, Caller_All_Exc, Caller_Exc_Set);
            Collect_Raised_Exceptions (Callee, Callee_All_Exc, Callee_Exc_Set);

            if Caller_All_Exc then
               All_Exc := True;
            elsif Callee_All_Exc then
               All_Exc := False;
            else
               Exc_Set := Callee_Exc_Set;
               Exc_Set.Intersection (Caller_Exc_Set);
               All_Exc := Exc_Set.Is_Empty;
            end if;
         end;
      end if;
   end Collect_Handled_Exceptions;

   -------------------------------
   -- Collect_Raised_Exceptions --
   -------------------------------

   procedure Collect_Raised_Exceptions
     (Subp    : Entity_Id;
      All_Exc : out Boolean;
      Exc_Set : out Node_Sets.Set)
   is
      Prag : constant Node_Id := Get_Pragma (Subp, Pragma_Exceptional_Cases);
   begin
      All_Exc := False;
      Exc_Set := Node_Sets.Empty_Set;

      if No (Prag) then
         return;
      end if;

      declare
         Aggr     : constant Node_Id :=
           Expression (First (Pragma_Argument_Associations (Prag)));
         Exc_Case : Node_Id := Last (Component_Associations (Aggr));
      begin
         --  Collect exceptions in Prag. Start from the last case to look
         --  for the others case first. Ignore cases with a statically False
         --  postcondition.

         while Present (Exc_Case) loop
            declare
               Exc  : Node_Id := First (Choices (Exc_Case));
               Post : constant Node_Id := Expression (Exc_Case);
            begin
               if not Compile_Time_Known_Value (Post)
                 or else not Is_False (Expr_Value (Post))
               then
                  while Present (Exc) loop
                     case Nkind (Exc) is
                        when N_Others_Choice =>
                           All_Exc := True;
                           return;
                        when N_Identifier
                           | N_Expanded_Name
                           =>
                           Exc_Set.Insert (Entity (Exc));
                        when others =>
                           raise Program_Error;
                     end case;
                     Next (Exc);
                  end loop;
               end if;
            end;

            Prev (Exc_Case);
         end loop;
      end;
   end Collect_Raised_Exceptions;

   -----------------------------
   -- Comes_From_Declare_Expr --
   -----------------------------

   function Comes_From_Declare_Expr (E : Entity_Id) return Boolean is
     (Ekind (E) = E_Constant
      and then Nkind (Parent (Enclosing_Declaration (E))) =
          N_Expression_With_Actions);

   -----------------------------------
   -- Component_Is_Visible_In_SPARK --
   -----------------------------------

   function Component_Is_Visible_In_SPARK (E : Entity_Id) return Boolean is
      Ty      : constant Entity_Id := Scope (E);
      Full_Ty : constant Entity_Id :=
        (if Present (Full_View (Ty)) then Full_View (Ty) else Ty);

   begin
      --  Since we are marking the component, the full type should be marked
      --  already. The type itself may not have been marked yet if it is
      --  private.
      pragma Assert (Entity_Marked (Full_Ty));

      --  Hidden discriminants are only in SPARK if Ty's full view is in SPARK

      if Ekind (E) = E_Discriminant then
         if Has_Discriminants (Ty) then
            return True;
         else
            pragma Assert (Has_Discriminants (Full_Ty));
            return Entity_In_SPARK (Full_Ty);
         end if;

      --  Components of a protected type and untagged types are visible except
      --  if the type full view is not in SPARK.

      elsif Is_Protected_Type (Full_Ty)
        or else not Is_Tagged_Type (Full_Ty)
      then
         return Entity_In_SPARK (Full_Ty)
           and then not Full_View_Not_In_SPARK (Full_Ty);

      --  Find the first record type in the hierarchy in which the field is
      --  present. The component is visible in SPARK if:
      --  * the type we are interested derives from this type by going only
      --    through SPARK derivations
      --  * the full view of this type is in SPARK.

      else
         declare
            Orig_Comp : constant Entity_Id := Original_Record_Component (E);
            Orig_Rec  : constant Entity_Id := Scope (Orig_Comp);
            Full_Orig : constant Entity_Id :=
              (if Present (Full_View (Orig_Rec)) then Full_View (Orig_Rec)
               else Orig_Rec);
            --  First record type in the hierarchy in which the field is
            --  present.

            Rec       : Entity_Id := Ty;
            Full_Rec  : Entity_Id;

         begin
            --  Go over the ancestors of Ty to see if it derives from Full_Orig
            --  by going only through SPARK derivations.

            loop
               Full_Rec :=
                 (if Present (Full_View (Rec)) then Full_View (Rec) else Rec);

               --  We have found Full_Orig, exit the loop

               exit when Full_Rec = Full_Orig;

               --  The next ancestor is the ancestor of the full view if the
               --  full view is in SPARK. Otherwise it is the ancestor of the
               --  partial view.

               pragma Assert (Entity_Marked (Full_Rec));
               Rec := (if Entity_In_SPARK (Full_Rec) then Etype (Full_Rec)
                       else Etype (Rec));

               --  Return False if we have reached the root of the derivation
               --  tree without finding Full_Orig.
               --  ??? We could possibly stop the search earlier using
               --  Is_Ancestor.

               if Unique_Entity (Rec) = Unique_Entity (Full_Rec) then
                  return False;
               end if;
            end loop;

            pragma Assert (Entity_Marked (Full_Orig));
            return Entity_In_SPARK (Full_Orig);
         end;
      end if;
   end Component_Is_Visible_In_SPARK;

   ------------------------
   -- Contains_Allocator --
   ------------------------

   function Contains_Allocator (N : Node_Id) return Boolean is

      function Is_Allocator (N : Node_Id) return Traverse_Result;
      --  Will return Abandon if we encounter an allocator

      ------------------
      -- Is_Allocator --
      ------------------

      function Is_Allocator (N : Node_Id) return Traverse_Result
      is
      begin
         if Nkind (N) = N_Allocator then
            return Abandon;
         else
            return OK;
         end if;
      end Is_Allocator;

      function Check_Allocator is new
        Traverse_More_Func (Is_Allocator);

   begin
      return Check_Allocator (N) = Abandon;
   end Contains_Allocator;

   -----------------------------
   -- Contains_Cut_Operations --
   -----------------------------

   function Contains_Cut_Operations (N : N_Subexpr_Id) return Boolean is
   begin
      case Nkind (N) is
         when N_Op_And
            | N_Op_Or
            | N_And_Then
            | N_Or_Else
            =>
            return Contains_Cut_Operations (Left_Opnd (N))
              or else Contains_Cut_Operations (Right_Opnd (N));
         when N_Quantified_Expression =>
            return Contains_Cut_Operations (Condition (N));
         when N_Expression_With_Actions =>
            return Contains_Cut_Operations (Expression (N));
         when N_If_Expression =>
            declare
               Cond        : constant N_Subexpr_Id :=
                 First (Expressions (N));
               Then_Part   : constant N_Subexpr_Id := Next (Cond);
               Else_Part   : constant Opt_N_Subexpr_Id := Next (Then_Part);
            begin
               return Contains_Cut_Operations (Then_Part)
                 or else (Present (Else_Part)
                          and then Contains_Cut_Operations (Else_Part));
            end;
         when N_Case_Expression =>
            declare
               Alt : Node_Id := First (Alternatives (N));
            begin
               while Present (Alt) loop
                  if Contains_Cut_Operations (Expression (Alt)) then
                     return True;
                  end if;
                  Next (Alt);
               end loop;
               return False;
            end;
         when N_Function_Call =>
            return Present (Get_Called_Entity (N))
              and then Is_From_Hardcoded_Unit
                (Get_Called_Entity (N), Cut_Operations);
         when others =>
            return False;
      end case;
   end Contains_Cut_Operations;

   ----------------------------
   -- Contains_Function_Call --
   ----------------------------

   function Contains_Function_Call (N : Node_Id) return Boolean is

      function Is_Function_Call (N : Node_Id) return Traverse_Result;
      --  Will return Abandon if we encounter an Function_Call

      ----------------------
      -- Is_Function_Call --
      ----------------------

      function Is_Function_Call (N : Node_Id) return Traverse_Result
      is
      begin
         if Nkind (N) = N_Function_Call then
            return Abandon;
         else
            return OK;
         end if;
      end Is_Function_Call;

      function Check_Function_Call is new
        Traverse_More_Func (Is_Function_Call);

   begin
      return Check_Function_Call (N) = Abandon;
   end Contains_Function_Call;

   -------------------------------------
   -- Contains_Volatile_Function_Call --
   -------------------------------------

   function Contains_Volatile_Function_Call (N : Node_Id) return Boolean is

      function Is_Volatile_Function_Call (N : Node_Id) return Traverse_Result;
      --  Will return Abandon if we encounter a call to a function with
      --  Volatile_Function set.

      -------------------------------
      -- Is_Volatile_Function_Call --
      -------------------------------

      function Is_Volatile_Function_Call (N : Node_Id) return Traverse_Result
      is
      begin
         if Nkind (N) = N_Function_Call
           and then Is_Enabled_Pragma
             (Get_Pragma (Get_Called_Entity (N), Pragma_Volatile_Function))
         then
            return Abandon;
         else
            return OK;
         end if;
      end Is_Volatile_Function_Call;

      function Check_Volatile_Function is new
        Traverse_More_Func (Is_Volatile_Function_Call);

   begin
      return Check_Volatile_Function (N) = Abandon;
   end Contains_Volatile_Function_Call;

   ------------------------------------
   -- Conversion_Is_Move_To_Constant --
   ------------------------------------

   function Conversion_Is_Move_To_Constant (Expr : Node_Id) return Boolean is
     (Is_Access_Object_Type (Retysp (Etype (Expr)))
      and then Is_Access_Constant (Retysp (Etype (Expr)))
      and then not Is_Anonymous_Access_Object_Type (Etype (Expr))
      and then not Is_Access_Constant
        (Retysp (Etype (Expression (Expr))))
      and then not Is_Rooted_In_Constant (Expression (Expr))
      and then not In_Assertion_Expression_Pragma (Expr));

   --------------------------------------------
   -- Directly_Enclosing_Subprogram_Or_Entry --
   --------------------------------------------

   function Directly_Enclosing_Subprogram_Or_Entry
     (E : Entity_Id)
      return Opt_Callable_Kind_Id
   is
      S : Entity_Id := Scope (E);
   begin
      loop
         if No (S) then
            return Empty;
         elsif Ekind (S) in Entry_Kind
                          | E_Function
                          | E_Procedure
         then
            return S;
         elsif Ekind (S) = E_Package then
            S := Scope (S);
         else
            return Empty;
         end if;
      end loop;
   end Directly_Enclosing_Subprogram_Or_Entry;

   -------------------------------
   -- Enclosing_Concurrent_Type --
   -------------------------------

   function Enclosing_Concurrent_Type (E : Entity_Id) return Concurrent_Kind_Id
   is
     (if Is_Part_Of_Concurrent_Object (E)
      then Etype (Encapsulating_State (E))
      else Scope (E));

   --------------------------------
   -- Enclosing_Generic_Instance --
   --------------------------------

   function Enclosing_Generic_Instance
     (E : Entity_Id)
      return Opt_E_Package_Id
   is
      S : Entity_Id := Scope (E);
   begin
      loop
         if No (S) then
            return Empty;
         elsif Is_Generic_Instance (S) then
            if Is_Subprogram (S) then
               S := Scope (S);
               pragma Assert (Is_Wrapper_Package (S));
            end if;

            return S;
         else
            S := Scope (S);
         end if;
      end loop;
   end Enclosing_Generic_Instance;

   --------------------
   -- Enclosing_Unit --
   --------------------

   function Enclosing_Unit (E : Entity_Id) return Unit_Kind_Id is
      S : Entity_Id := Scope (E);

   begin
      loop
         if Ekind (S) in Entry_Kind
                       | E_Function
                       | E_Procedure
                       | E_Package
                       | E_Protected_Type
                       | E_Subprogram_Type
                       | E_Task_Type
         then

            --  We have found the enclosing unit, unless it is a wrapper
            --  package.

            if Ekind (S) = E_Package and then Is_Wrapper_Package (S) then
               S := Scope (S);
            else
               return S;
            end if;

         else
            pragma Assert (not Is_Generic_Unit (S));

            --  Go to the enclosing scope

            S := Scope (S);
         end if;
      end loop;
   end Enclosing_Unit;

   -------------------------------
   -- Entity_To_Subp_Assumption --
   -------------------------------

   function Entity_To_Subp_Assumption (E : Entity_Id) return Subp_Type is
      function Loc_To_Assume_Sloc (Loc : Source_Ptr) return My_Sloc
        with Pre => Loc /= No_Location;

      ------------------------
      -- Loc_To_Assume_Sloc --
      ------------------------

      function Loc_To_Assume_Sloc (Loc : Source_Ptr) return My_Sloc is
         Sloc : My_Sloc := Sloc_Lists.Empty_List;
         Slc  : Source_Ptr := Loc;
      begin
         loop
            declare
               File : constant String := File_Name (Slc);
               Line : constant Positive :=
                 Positive (Get_Physical_Line_Number (Slc));
            begin
               Sloc.Append (Mk_Base_Sloc (File => File, Line => Line));
            end;
            Slc := Instantiation_Location (Slc);

            exit when Slc = No_Location;
         end loop;
         return Sloc;
      end Loc_To_Assume_Sloc;
   begin
      return Mk_Subp (Name => Full_Source_Name (E),
                      Sloc => Loc_To_Assume_Sloc (Sloc (E)));
   end Entity_To_Subp_Assumption;

   -----------------------
   -- Exception_Handled --
   -----------------------

   function Exception_Handled
     (E    : E_Exception_Id;
      Stmt : Node_Id)
      return Boolean
   is
      function Is_Body (N : Node_Id) return Boolean is
        (Nkind (N) in N_Entity_Body);

      function Enclosing_Body is new
        First_Parent_With_Property (Is_Body);

      Scop : constant Node_Id := Enclosing_Body (Stmt);
      Prag : Node_Id;
   begin
      if Nkind (Scop) in N_Subprogram_Body then
         Prag := Get_Pragma
           (Unique_Defining_Entity (Scop), Pragma_Exceptional_Cases);

         if No (Prag) then
            return False;
         end if;

         declare
            Aggr     : constant Node_Id :=
              Expression (First (Pragma_Argument_Associations (Prag)));
            Exc_Case : Node_Id := Last (Component_Associations (Aggr));
         begin
            --  Search for E in Prag. Start from the last case to look for
            --  the others case first. Ignore cases with a statically False
            --  postcondition.

            while Present (Exc_Case) loop
               declare
                  Exc  : Node_Id := First (Choices (Exc_Case));
                  Post : constant Node_Id := Expression (Exc_Case);
               begin
                  if not Compile_Time_Known_Value (Post)
                    or else not Is_False (Expr_Value (Post))
                  then
                     while Present (Exc) loop
                        case Nkind (Exc) is
                           when N_Others_Choice =>
                              return True;
                           when N_Identifier
                              | N_Expanded_Name
                              =>
                              if Entity (Exc) = E then
                                 return True;
                              end if;
                           when others =>
                              raise Program_Error;
                        end case;
                        Next (Exc);
                     end loop;
                  end if;
               end;

               Prev (Exc_Case);
            end loop;
         end;
      end if;
      return False;
   end Exception_Handled;

   ---------------------------
   -- Expr_Has_Relaxed_Init --
   ---------------------------

   function Expr_Has_Relaxed_Init
     (Expr    : N_Subexpr_Id;
      No_Eval : Boolean := True) return Boolean
   is

      function Aggr_Has_Relaxed_Init (Aggr : Node_Id) return Boolean
      with Pre => Nkind (Aggr) in N_Aggregate
                                | N_Delta_Aggregate
                                | N_Extension_Aggregate;
      --  Check the expressions of an aggregate for relaxed initialization.
      --  If the component type has relaxed initialization, its value does not
      --  impact the status of the aggregate.

      ---------------------------
      -- Aggr_Has_Relaxed_Init --
      ---------------------------

      function Aggr_Has_Relaxed_Init (Aggr : Node_Id) return Boolean is
         Exprs  : constant List_Id :=
           (if Nkind (Aggr) = N_Delta_Aggregate then No_List
            else Expressions (Aggr));
         Assocs : constant List_Id := Component_Associations (Aggr);
         Expr   : Node_Id := Nlists.First (Exprs);
         Assoc  : Node_Id := Nlists.First (Assocs);
      begin
         while Present (Expr) loop
            pragma Assert (Is_Array_Type (Etype (Aggr)));
            if not Has_Relaxed_Init (Component_Type (Etype (Aggr)))
              and then Expr_Has_Relaxed_Init (Expr, No_Eval => False)
            then
               return True;
            end if;
            Next (Expr);
         end loop;

         while Present (Assoc) loop

            --  If there is a box in the aggregate, the default value of the
            --  type is used. It can only have relaxed initialization if the
            --  component type has relaxed initialization, in which case it
            --  does not impact the status of the aggregate.

            if not Box_Present (Assoc)
              and then not Has_Relaxed_Init
                (if Is_Array_Type (Etype (Aggr))
                 then Component_Type (Etype (Aggr))
                 else Etype
                   (Entity (First (Choice_List (Assoc)))))
              and then Expr_Has_Relaxed_Init
                (Expression (Assoc), No_Eval => False)
            then
               return True;
            end if;
            Next (Assoc);
         end loop;
         return False;
      end Aggr_Has_Relaxed_Init;

   --  Start of processing Expr_Has_Relaxed_Init

   begin
      --  Scalar expressions are necessarily initialized as evaluating such an
      --  expression requires initialization.
      --  The same holds true for types with predicates if the predicate
      --  requires initialization.

      if (Copy_Requires_Init (Etype (Expr)) and then not No_Eval)
        or else (not Has_Relaxed_Init (Etype (Expr))
                 and then not Might_Contain_Relaxed_Init (Etype (Expr)))
      then
         return False;
      end if;

      case Nkind (Expr) is
         when N_Aggregate =>
            return Aggr_Has_Relaxed_Init (Expr);

         when N_Extension_Aggregate =>
            return Expr_Has_Relaxed_Init
              (Ancestor_Part (Expr), No_Eval => False)
              or else Aggr_Has_Relaxed_Init (Expr);

         when N_Delta_Aggregate =>
            return Expr_Has_Relaxed_Init
              (Expression (Expr), No_Eval => False)
              or else Aggr_Has_Relaxed_Init (Expr);

         when N_Slice =>
            return Expr_Has_Relaxed_Init (Prefix (Expr), No_Eval);

         when N_Op_Concat =>
            return Expr_Has_Relaxed_Init (Left_Opnd (Expr), No_Eval => False)
              or else Expr_Has_Relaxed_Init
                (Right_Opnd (Expr), No_Eval => False);

         when N_If_Expression =>
            declare
               Cond      : constant Node_Id := First (Expressions (Expr));
               Then_Part : constant Node_Id := Next (Cond);
               Else_Part : constant Node_Id := Next (Then_Part);
            begin
               return Expr_Has_Relaxed_Init (Then_Part, No_Eval => False)
                 or else
                   (Present (Else_Part)
                    and then Expr_Has_Relaxed_Init
                      (Else_Part, No_Eval => False));
            end;

         when N_Case_Expression =>
            declare
               Cases   : constant List_Id := Alternatives (Expr);
               Current : Node_Id := First (Cases);
            begin
               while Present (Current) loop
                  if Expr_Has_Relaxed_Init
                    (Expression (Current), No_Eval => False)
                  then
                     return True;
                  end if;
                  Next (Current);
               end loop;
               return False;
            end;

         when N_Qualified_Expression =>
            return Expr_Has_Relaxed_Init (Expression (Expr), No_Eval => False);

         when N_Unchecked_Type_Conversion
            | N_Type_Conversion
         =>
            return Expr_Has_Relaxed_Init (Expression (Expr), No_Eval);

         when N_Function_Call =>
            return Fun_Has_Relaxed_Init (Get_Called_Entity (Expr));

         when N_Identifier
            | N_Expanded_Name
         =>
            return Obj_Has_Relaxed_Init (Entity (Expr));

         when N_Indexed_Component
            | N_Selected_Component
            | N_Explicit_Dereference
         =>
            return Has_Relaxed_Init (Etype (Expr))
              or else Expr_Has_Relaxed_Init (Prefix (Expr), No_Eval);

         when N_Attribute_Reference =>
            case Get_Attribute_Id (Attribute_Name (Expr)) is
               when Attribute_Result =>
                  return Fun_Has_Relaxed_Init (Entity (Prefix (Expr)));

               when Attribute_Old
                  | Attribute_Loop_Entry
               =>
                  return Expr_Has_Relaxed_Init (Prefix (Expr), No_Eval);

               when Attribute_Update =>
                  return Expr_Has_Relaxed_Init
                    (Prefix (Expr), No_Eval => False)
                    or else Aggr_Has_Relaxed_Init (First (Expressions (Expr)));

               when others =>
                  return False;
            end case;

         when N_Expression_With_Actions =>
            return Expr_Has_Relaxed_Init (Expression (Expr), No_Eval);

         when N_Allocator =>
            if Nkind (Expression (Expr)) = N_Qualified_Expression then
               return Expr_Has_Relaxed_Init
                 (Expression (Expr), No_Eval => False);
            else
               --  The default value is necessarily entirely initialized

               pragma Assert
                 (Default_Initialization (Entity (Expression (Expr)))
                  in Full_Default_Initialization
                   | No_Possible_Initialization);
               return False;
            end if;

         when N_Character_Literal
            | N_Numeric_Or_String_Literal
            | N_Op_Compare
            | N_Unary_Op
            | N_Op_Add
            | N_Op_Subtract
            | N_Op_Multiply
            | N_Op_Divide
            | N_Op_Rem
            | N_Op_Mod
            | N_Op_Expon
            | N_Op_And
            | N_Op_Or
            | N_Op_Xor
            | N_Short_Circuit
            | N_Membership_Test
            | N_Quantified_Expression
            | N_Null
         =>
            return False;

         when others =>
            raise Program_Error;
      end case;
   end Expr_Has_Relaxed_Init;

   --------------------------------
   -- First_Parent_With_Property --
   --------------------------------

   function First_Parent_With_Property (N : Node_Id) return Node_Id is
      P : Node_Id := N;
   begin
      loop
         P := Parent (P);
         exit when No (P) or else Property (P);
      end loop;
      return P;
   end First_Parent_With_Property;

   ---------------------
   -- Full_Entry_Name --
   ---------------------

   function Full_Entry_Name (N : Node_Id) return String is
   begin
      case Nkind (N) is
         --  Once we get to the root of the prefix, which can be either a
         --  simple identifier (e.g. "PO") or an expanded name (e.g.
         --  Pkg1.Pkg2.PO), return the unique name of the target object.

         when N_Expanded_Name
            | N_Identifier
         =>
            declare
               Obj : constant Entity_Id := Entity (N);
               --  Object that is the target of an entry call; it must be a
               --  variable with protected components.

               pragma Assert (Ekind (Obj) = E_Variable
                                and then Has_Protected (Etype (Obj)));

            begin
               return Unique_Name (Obj);
            end;

         --  Accesses to array components are not known statically (because
         --  flow analysis can't determine exact values of the indices); by
         --  ignoring them we conservatively consider accesses to different
         --  components as potential violations.

         when N_Indexed_Component =>
            return Full_Entry_Name (Prefix (N));

         --  Accesses to record components are known statically and become part
         --  of the returned identifier.

         when N_Selected_Component =>
            return Full_Entry_Name (Prefix (N)) &
              "__" & Get_Name_String (Chars (Entity (Selector_Name (N))));

         when others =>
            raise Program_Error;
      end case;
   end Full_Entry_Name;

   ---------------
   -- Full_Name --
   ---------------

   function Full_Name (E : Entity_Id) return String is
   begin
      --  In a few special cases, return a predefined name. These cases should
      --  match those for which Full_Name_Is_Not_Unique_Name returns True.

      if Full_Name_Is_Not_Unique_Name (E) then
         if Is_Standard_Boolean_Type (E) then
            return "bool";
         else
            raise Program_Error;
         end if;

      --  In the general case, return the same name as Unique_Name

      else
         return Unique_Name (E);
      end if;
   end Full_Name;

   ----------------------------------
   -- Full_Name_Is_Not_Unique_Name --
   ----------------------------------

   function Full_Name_Is_Not_Unique_Name (E : Entity_Id) return Boolean is
     ((Is_Type (E) and then Is_Standard_Boolean_Type (E)));

   ----------------------
   -- Full_Source_Name --
   ----------------------

   function Full_Source_Name (E : Entity_Id) return String is
      Name : constant String := Source_Name (E);

   begin
      if E = Standard_Standard
        or else Has_Fully_Qualified_Name (E)
        or else Scope (E) = Standard_Standard
      then
         return Name;
      else
         return Full_Source_Name (Scope (E)) & "." & Name;
      end if;
   end Full_Source_Name;

   --------------------------
   -- Fun_Has_Relaxed_Init --
   --------------------------

   function Fun_Has_Relaxed_Init (Subp : E_Function_Id) return Boolean is
   begin
      --  It is illegal to return an uninitialized object of a scalar type. The
      --  same holds true for type with predicates if the predicate check
      --  requires initialization.

      if Copy_Requires_Init (Retysp (Etype (Subp))) then
         return False;
      else
         return Has_Relaxed_Initialization (Subp)
           or else Has_Relaxed_Init (Etype (Subp));
      end if;
   end Fun_Has_Relaxed_Init;

   --------------------------------
   -- Generic_Actual_Subprograms --
   --------------------------------

   function Generic_Actual_Subprograms (E : E_Package_Id) return Node_Sets.Set
   is
      Results : Node_Sets.Set;

      Instance : constant Node_Id := Get_Unit_Instantiation_Node (E);

      pragma Assert (Nkind (Instance) in N_Generic_Instantiation);

      Actuals : constant List_Id := Generic_Associations (Instance);

      Actual : Node_Id := First (Actuals);

   begin

      while Present (Actual) loop
         pragma Assert (Nkind (Actual) = N_Generic_Association);

         declare
            Actual_Expl : constant Node_Id :=
              Explicit_Generic_Actual_Parameter (Actual);

         begin
            if Nkind (Actual_Expl) in N_Has_Entity then
               declare
                  E_Actual : constant Entity_Id := Entity (Actual_Expl);

               begin
                  if Present (E_Actual)
                    and then Ekind (E_Actual) in E_Function
                                               | E_Procedure
                  then

                     --  Generic actual subprograms are typically renamings and
                     --  then we want the renamed subprogram, but for generics
                     --  nested in other generics they seem to directly point
                     --  to what we need.

                     declare
                        Renamed : constant Entity_Id :=
                          Renamed_Entity (E_Actual);
                        --  For subprograms Renamed_Entity is set transitively,
                        --  so we just need to call it once.

                     begin
                        Results.Include (if Present (Renamed)
                                         then Renamed
                                         else E_Actual);
                     end;
                  end if;
               end;
            end if;
         end;

         Next (Actual);
      end loop;

      return Results;
   end Generic_Actual_Subprograms;

   ---------------------------------------------
   -- Get_Flat_Statement_And_Declaration_List --
   ---------------------------------------------

   function Get_Flat_Statement_And_Declaration_List
     (Stmts : List_Id) return Node_Lists.List
   is
      Cur_Stmt   : Node_Id := Nlists.First (Stmts);
      Flat_Stmts : Node_Lists.List;

   begin
      while Present (Cur_Stmt) loop
         case Nkind (Cur_Stmt) is
            when N_Block_Statement =>
               if Present (Declarations (Cur_Stmt)) then
                  Append (Flat_Stmts,
                          Get_Flat_Statement_And_Declaration_List
                            (Declarations (Cur_Stmt)));
               end if;

               Append (Flat_Stmts,
                       Get_Flat_Statement_And_Declaration_List
                         (Statements (Handled_Statement_Sequence (Cur_Stmt))));

               --  Append the block statement itself as a marker for the end
               --  of the corresponding scope. These statements should be
               --  handled specially by every caller of this function, as they
               --  duplicate the flattened statements. In the simplest case
               --  they should just be ignored.

               Flat_Stmts.Append (Cur_Stmt);

            when others =>
               Flat_Stmts.Append (Cur_Stmt);
         end case;

         Nlists.Next (Cur_Stmt);
      end loop;

      return Flat_Stmts;
   end Get_Flat_Statement_And_Declaration_List;

   ----------------------------
   -- Get_Formal_From_Actual --
   ----------------------------

   function Get_Formal_From_Actual
     (Actual : N_Subexpr_Id)
      return Formal_Kind_Id
   is
      Formal : Entity_Id;
      Call   : Node_Id;
   begin
      Find_Actual (Actual, Formal, Call);
      return Formal;
   end Get_Formal_From_Actual;

   ----------------------------
   -- Get_Initialized_Object --
   ----------------------------

   function Get_Initialized_Object
     (N : N_Subexpr_Id)
      return Opt_Object_Kind_Id
   is
      Context : constant Node_Id := Unqual_Conv (Parent (N));
      --  Skip qualifications and type conversions between the aggregate and
      --  the object declaration.

   begin
      if Nkind (Context) = N_Object_Declaration then
         return Defining_Identifier (Context);
      else
         return Empty;
      end if;
   end Get_Initialized_Object;

   -----------------------------------
   -- Get_Observed_Or_Borrowed_Expr --
   -----------------------------------

   function Get_Observed_Or_Borrowed_Expr
     (Expr : N_Subexpr_Id)
      return N_Subexpr_Id
   is
      B_Expr : Node_Id;
      B_Ty   : Entity_Id := Empty;
   begin
      Get_Observed_Or_Borrowed_Info (Expr, B_Expr, B_Ty);
      return B_Expr;
   end Get_Observed_Or_Borrowed_Expr;

   -----------------------------------
   -- Get_Observed_Or_Borrowed_Info --
   -----------------------------------

   procedure Get_Observed_Or_Borrowed_Info
     (Expr   : N_Subexpr_Id;
      B_Expr : out N_Subexpr_Id;
      B_Ty   : in out Opt_Type_Kind_Id)
   is
      function Find_Func_Call (Expr : Node_Id) return Node_Id;
      --  Search for function calls in the prefixes of Expr

      --------------------
      -- Find_Func_Call --
      --------------------

      function Find_Func_Call (Expr : Node_Id) return Node_Id is
      begin
         case Nkind (Expr) is
            when N_Expanded_Name
               | N_Identifier
            =>
               return Empty;

            when N_Explicit_Dereference
               | N_Indexed_Component
               | N_Selected_Component
               | N_Slice
               | N_Attribute_Reference
            =>
               return Find_Func_Call (Prefix (Expr));

            when N_Op_Eq
               | N_Op_Ne
            =>
               if Nkind (Left_Opnd (Expr)) = N_Null then
                  return Find_Func_Call (Right_Opnd (Expr));
               else
                  pragma Assert (Nkind (Right_Opnd (Expr)) = N_Null);
                  return Find_Func_Call (Left_Opnd (Expr));
               end if;

            when N_Qualified_Expression
               | N_Type_Conversion
               | N_Unchecked_Type_Conversion
            =>
               return Find_Func_Call (Expression (Expr));

            when N_Function_Call =>
               return Expr;

            when others =>
               raise Program_Error;
         end case;
      end Find_Func_Call;

   --  Start of processing for Get_Observed_Or_Borrowed_Info

   begin
      B_Expr := Expr;

      --  Search for the first call to a traversal function in Expr. If there
      --  is one, its first parameter is the borrowed expression. Otherwise,
      --  it is Expr.

      loop
         declare
            Call : constant Node_Id := Find_Func_Call (B_Expr);
         begin
            exit when No (Call);
            pragma Assert (Is_Traversal_Function_Call (Call));
            B_Ty   := Etype (First_Formal (Get_Called_Entity (Call)));
            B_Expr := First_Actual (Call);
         end;
      end loop;
   end Get_Observed_Or_Borrowed_Info;

   -------------------------
   -- Get_Operator_Symbol --
   -------------------------

   function Get_Operator_Symbol (N : Node_Id) return String is
      Buf : Bounded_String;

   begin
      --  Reuse frontend decoding of operator symbol

      Append_Unqualified_Decoded (Buf, Chars (N));

      --  Strip leading and trailing quotes

      pragma Assert (Buf.Chars (1) = '"');
      pragma Assert (Buf.Chars (Buf.Length) = '"');

      return Buf.Chars (2 .. Buf.Length - 1);
   end Get_Operator_Symbol;

   ---------------
   -- Get_Range --
   ---------------

   function Get_Range (N : Node_Id) return Node_Id is
   begin
      case Nkind (N) is
         when N_Range
            | N_Real_Range_Specification
            | N_Signed_Integer_Type_Definition
            | N_Modular_Type_Definition
            | N_Floating_Point_Definition
            | N_Ordinary_Fixed_Point_Definition
            | N_Decimal_Fixed_Point_Definition
         =>
            return N;

         when N_Subtype_Indication =>
            return Range_Expression (Constraint (N));

         when N_Identifier
            | N_Expanded_Name
         =>
            return Get_Range (Entity (N));

         when N_Defining_Identifier =>
            return
              Get_Range
                (Scalar_Range
                   (case Ekind (N) is
                    when Object_Kind                => Etype (N),
                    when Scalar_Kind                => N,
                    when E_Limited_Private_Subtype
                       | E_Limited_Private_Type
                       | E_Private_Subtype
                       | E_Private_Type             => Full_View (N),
                    when others                     => raise Program_Error));

         when others =>
            raise Program_Error;
      end case;
   end Get_Range;

   ---------------------
   -- Get_Root_Object --
   ---------------------

   function Get_Root_Object
     (Expr              : N_Subexpr_Id;
      Through_Traversal : Boolean := True)
      return Opt_Object_Kind_Id
   is
      function GRO (Expr : Node_Id) return Entity_Id;
      --  Local wrapper on the actual function, to propagate the values of
      --  optional parameters.

      ---------
      -- GRO --
      ---------

      function GRO (Expr : Node_Id) return Entity_Id is
      begin
         return Get_Root_Object (Expr, Through_Traversal);
      end GRO;

      Get_Root_Object : Boolean;
      pragma Unmodified (Get_Root_Object);
      --  Local variable to mask the name of function Get_Root_Object, to
      --  prevent direct call. Instead GRO wrapper should be called.

   --  Start of processing for Get_Root_Object

   begin
      case Nkind (Expr) is
         when N_Expanded_Name
            | N_Identifier
         =>
            --  There is no root object for an enumeration literal or a type,
            --  which may occur as the prefix of an attribute reference.

            if Is_Object (Entity (Expr)) then
               return Entity (Expr);
            else
               return Empty;
            end if;

         when N_Explicit_Dereference
            | N_Indexed_Component
            | N_Selected_Component
            | N_Slice
         =>
            return GRO (Prefix (Expr));

         --  There is no root object for an (extension) aggregate, allocator,
         --  concat, or NULL.

         when N_Aggregate
            | N_Allocator
            | N_Delta_Aggregate
            | N_Extension_Aggregate
            | N_Null
         =>
            return Empty;

         --  In the case of a call to a traversal function, the root object is
         --  the root of the traversed parameter. Otherwise there is no root
         --  object.

         when N_Function_Call =>
            if Through_Traversal
              and then Is_Traversal_Function_Call (Expr)
              and then Is_Path_Expression (First_Actual (Expr))
            then
               return GRO (First_Actual (Expr));
            else
               return Empty;
            end if;

         when N_Qualified_Expression
            | N_Type_Conversion
            | N_Unchecked_Type_Conversion
         =>
            return GRO (Expression (Expr));

         when N_Attribute_Reference =>
            if Attribute_Name (Expr) in Name_First
                                      | Name_Last
                                      | Name_Length
                                      | Name_Access
            then
               return GRO (Prefix (Expr));
            else
               pragma Assert
                 (Attribute_Name (Expr) in Name_Loop_Entry
                                         | Name_Old
                                         | Name_Update);
               return Empty;
            end if;

         when N_Op_Eq
            | N_Op_Ne
         =>
            if Nkind (Left_Opnd (Expr)) = N_Null then
               return GRO (Right_Opnd (Expr));
            else
               pragma Assert (Nkind (Right_Opnd (Expr)) = N_Null);
               return GRO (Left_Opnd (Expr));
            end if;

         when others =>
            raise Program_Error;
      end case;
   end Get_Root_Object;

   --------------------------------
   -- Get_Specialized_Parameters --
   --------------------------------

   function Get_Specialized_Parameters
     (Call                 : Node_Id;
      Specialized_Entities : Node_Maps.Map := Node_Maps.Empty_Map)
      return Node_Maps.Map
   is
      Subp   : constant Entity_Id :=
        (if Nkind (Call) in N_Op then Entity (Call)
         else Sem_Aux.Get_Called_Entity (Call));
      Params : Node_Maps.Map;

      procedure Store_Specialized_Param (Formal : Entity_Id; Actual : Node_Id);
      --  Store in Params an association between the formal parameters
      --  specialized in Call and the prefix of their actuals.

      -----------------------------
      -- Store_Specialized_Param --
      -----------------------------

      procedure Store_Specialized_Param (Formal : Entity_Id; Actual : Node_Id)
      is
      begin
         if Is_Specializable_Formal (Formal) then
            if Is_Access_Attribute_Of_Function (Actual) then
               Params.Insert (Formal, Entity (Prefix (Actual)));
            elsif Nkind (Actual) in N_Identifier | N_Expanded_Name
              and then Specialized_Entities.Contains (Entity (Actual))
            then
               Params.Insert
                 (Formal, Specialized_Entities.Element (Entity (Actual)));
            end if;
         end if;
      end Store_Specialized_Param;

      procedure Collect_Params is new Iterate_Call_Parameters
        (Store_Specialized_Param);

   begin
      if Ekind (Subp) in E_Function | E_Procedure
        and then Has_Higher_Order_Specialization_Annotation (Subp)
      then
         Collect_Params (Call);
      end if;

      return Params;
   end Get_Specialized_Parameters;

   ------------------
   -- Has_Volatile --
   ------------------

   function Has_Volatile (E : N_Entity_Id) return Boolean is
     (case Ekind (E) is
         when E_Abstract_State =>
            Is_External_State (E),
         when Object_Kind | Type_Kind =>
            not Is_Concurrent_Type (E)
              and then Is_Effectively_Volatile (E),
         when others =>
            raise Program_Error);

   ---------------------------
   -- Has_Volatile_Property --
   ---------------------------

   function Has_Volatile_Property
     (E : N_Entity_Id;
      P : Volatile_Pragma_Id)
      return Boolean
   is
   begin
      --  Q: Why restrict the property of volatility for IN and OUT parameters?
      --
      --  A: See SRM 7.1.3. In short when passing a volatile through a
      --  parameter we present a 'worst case but sane' view of the volatile,
      --  which means there should be no information hiding possible and no
      --  silent side effects, so...

      case Ekind (E) is
         when E_Abstract_State
            | E_Constant
            | E_Variable
            | E_Component
            | Type_Kind
            | E_In_Out_Parameter
         =>
            return
              (case P is
               when Pragma_Async_Readers    => Async_Readers_Enabled (E),
               when Pragma_Async_Writers    => Async_Writers_Enabled (E),
               when Pragma_Effective_Reads  => Effective_Reads_Enabled (E),
               when Pragma_Effective_Writes => Effective_Writes_Enabled (E));

         --  All volatile in parameters have only async_writers set. In
         --  particular reads cannot be effective and the absence of AR
         --  is irrelevant since we are not allowed to write to it anyway.

         when E_In_Parameter  =>
            return P = Pragma_Async_Writers
              and then Async_Writers_Enabled (E);

         --  Out parameters we assume that writes are effective (worst case).
         --  We do not assume reads are effective because (a - it may be
         --  illegal to read anyway, b - we ban passing a fully volatile
         --  object as an argument to an out parameter).

         when E_Out_Parameter =>
            return
              (case P is
                  when Pragma_Async_Readers    => Async_Readers_Enabled (E),
                  when Pragma_Effective_Writes => Effective_Writes_Enabled (E),
                  when others                  => False);

         when others =>
            raise Program_Error;
      end case;
   end Has_Volatile_Property;

   ------------------------------------
   -- In_Loop_Entry_Or_Old_Attribute --
   ------------------------------------

   function In_Loop_Entry_Or_Old_Attribute (N : Node_Id) return Boolean is

      function Is_Attribute_Loop_Entry_Or_Old (N : Node_Id) return Boolean is
        (Is_Attribute_Loop_Entry (N) or else Is_Attribute_Old (N));

      function Find_Loop_Entry_Or_Old_Attribute is new
        First_Parent_With_Property (Is_Attribute_Loop_Entry_Or_Old);

   begin
      return Present (Find_Loop_Entry_Or_Old_Attribute (N));
   end In_Loop_Entry_Or_Old_Attribute;

   ---------------------------
   -- In_SPARK_Library_Unit --
   ---------------------------

   function In_SPARK_Library_Unit (N : Node_Or_Entity_Id) return Boolean is
      Unit     : constant Unit_Number_Type := Get_Source_Unit (N);
      U_Name   : constant File_Name_Type := Unit_File_Name (Unit);
      Str_Name : constant String := Get_Name_String (U_Name);
   begin
      return Str_Name'Length >= 11
        and then Str_Name (Str_Name'First .. Str_Name'First + 5) = "spark-"
        and then Str_Name (Str_Name'Last - 3 .. Str_Name'Last - 1) = ".ad"
        and then Str_Name (Str_Name'Last) in 's' | 'b';
   end In_SPARK_Library_Unit;

   ------------------------------------------------
   -- Is_Additional_Param_Of_Access_Subp_Wrapper --
   ------------------------------------------------

   function Is_Additional_Param_Of_Access_Subp_Wrapper
     (E : Formal_Kind_Id)
      return Boolean
   is (Ekind (E) = E_In_Parameter
       and then Is_Access_Subprogram_Type (Etype (E))
       and then Scope (E) = Access_Subprogram_Wrapper
       (Directly_Designated_Type (Etype (E))));

   -------------------------------------
   -- Is_Access_Attribute_Of_Function --
   -------------------------------------

   function Is_Access_Attribute_Of_Function (Expr : Node_Id) return Boolean
   is (Nkind (Expr) = N_Attribute_Reference
       and then Get_Attribute_Id (Attribute_Name (Expr)) = Attribute_Access
       and then Nkind (Prefix (Expr)) in N_Identifier | N_Expanded_Name
       and then Ekind (Entity (Prefix (Expr))) = E_Function);

   ---------------
   -- Is_Action --
   ---------------

   function Is_Action (N : N_Object_Declaration_Id) return Boolean is
      L : constant List_Id := List_Containing (N);
      P : constant Node_Id := Parent (N);
   begin
      if No (L) or else No (P) then
         return False;
      end if;

      return
        (case Nkind (P) is
            when N_Component_Association =>
               L = Loop_Actions (P),
            when N_And_Then | N_Or_Else =>
               L = Actions (P),
            when N_If_Expression =>
               L = Then_Actions (P) or else L = Else_Actions (P),
            when N_Case_Expression_Alternative =>
               L = Actions (P),
            when N_Elsif_Part =>
               L = Condition_Actions (P),
            when N_Iteration_Scheme =>
               L = Condition_Actions (P),
            when N_Block_Statement =>
               L = Cleanup_Actions (P),
            when N_Expression_With_Actions =>
               L = Actions (P),
            when N_Freeze_Entity =>
               L = Actions (P),
            when others =>
               False);
   end Is_Action;

   -----------------------------------
   -- Is_Constant_After_Elaboration --
   -----------------------------------

   function Is_Constant_After_Elaboration (E : E_Variable_Id) return Boolean is
      Prag : constant Node_Id :=
        Get_Pragma (E, Pragma_Constant_After_Elaboration);
   begin
      return Present (Prag) and then Is_Enabled_Pragma (Prag);
   end Is_Constant_After_Elaboration;

   --------------------------
   -- Is_Constant_Borrower --
   --------------------------

   function Is_Constant_Borrower (E : Object_Kind_Id) return Boolean is
      Root : Entity_Id := E;

   begin
      --  Search for the ultimate root of the borrow

      loop
         Root := Get_Root_Object (Expression (Parent (Root)));
         exit when not Is_Local_Borrower (Root);
      end loop;

      --  Return True if it is the first parameter of a borrowing traversal
      --  function.

      return Ekind (Root) = E_In_Parameter
        and then Is_Borrowing_Traversal_Function (Scope (Root))
        and then Root = First_Formal (Scope (Root));
   end Is_Constant_Borrower;

   --------------------------
   -- Is_Constant_In_SPARK --
   --------------------------

   function Is_Constant_In_SPARK (E : Object_Kind_Id) return Boolean is
   begin
      case Ekind (E) is
         when E_In_Parameter =>
            return Ekind (Scope (E)) = E_Function
              or else not Is_Access_Variable (Etype (E));
         when E_Loop_Parameter =>
            return True;
         when E_Constant =>
            return Comes_From_Declare_Expr (E)
              or else not Is_Access_Variable (Etype (E));
         when others =>
            return False;
      end case;
   end Is_Constant_In_SPARK;

   ------------------------------------------
   -- Is_Converted_Actual_Output_Parameter --
   ------------------------------------------

   function Is_Converted_Actual_Output_Parameter
     (N : N_Subexpr_Id)
      return Boolean
   is
      Formal : Entity_Id;
      Call   : Node_Id;
      Conv   : Node_Id;

   begin
      --  Find the most enclosing type conversion node

      Conv := N;
      while Nkind (Parent (Conv)) = N_Type_Conversion loop
         Conv := Parent (Conv);
      end loop;

      --  Check if this node is an out or in out actual parameter

      Find_Actual (Conv, Formal, Call);
      return Present (Formal)
        and then Ekind (Formal) in E_Out_Parameter | E_In_Out_Parameter;
   end Is_Converted_Actual_Output_Parameter;

   ---------------------------------------
   -- Is_Call_Arg_To_Predicate_Function --
   ---------------------------------------

   function Is_Call_Arg_To_Predicate_Function
     (N : Opt_N_Subexpr_Id)
      return Boolean
   is
     (Present (N)
        and then Present (Parent (N))
        and then Nkind (Parent (N)) in N_Type_Conversion
                                     | N_Unchecked_Type_Conversion
        and then Present (Parent (Parent (N)))
        and then Is_Predicate_Function_Call (Parent (Parent (N))));

   --------------------------------------
   -- Is_Concurrent_Component_Or_Discr --
   --------------------------------------

   function Is_Concurrent_Component_Or_Discr (E : Entity_Id) return Boolean is
   begin
      --  Protected discriminants appear either as E_In_Parameter (in spec of
      --  protected types, e.g. in pragma Priority) or as E_Discriminant
      --  (everywhere else).
      return Ekind (E) in E_Component | E_Discriminant | E_In_Parameter
        and then Ekind (Scope (E)) in E_Protected_Type | E_Task_Type;
   end Is_Concurrent_Component_Or_Discr;

   ----------------------------
   -- Is_Declared_In_Private --
   ----------------------------

   function Is_Declared_In_Private (E : Entity_Id) return Boolean is
      Current : Entity_Id := E;
   begin
      loop
         declare
            Decl : constant Node_Id :=
              (if Is_Itype (Current) then Associated_Node_For_Itype (Current)
               else Enclosing_Declaration (Current));
         begin
            if In_Private_Declarations (Decl) then
               return True;
            end if;
            Current := Scope (Current);
            exit when No (Current);
         end;
      end loop;
      return False;
   end Is_Declared_In_Private;

   -------------------------
   -- Is_Declared_In_Unit --
   -------------------------

   --  Parameters of subprograms cannot be local to a unit. Discriminants of
   --  concurrent objects are not local to the object.

   function Is_Declared_In_Unit
     (E     : Entity_Id;
      Scope : Entity_Id) return Boolean
   is
     (Enclosing_Unit (E) = Scope
      and then not Is_Formal (E)
      and then (Ekind (E) /= E_Discriminant
                or else Sinfo.Nodes.Scope (E) /= Scope));

   ----------------------------------------
   -- Is_Declared_In_Main_Unit_Or_Parent --
   ----------------------------------------

   function Is_Declared_In_Main_Unit_Or_Parent (N : Node_Id) return Boolean
   is
      Main_CU : Entity_Id := Main_Unit_Entity;
      N_CU    : constant Entity_Id :=
        Unique_Defining_Entity (Unit (Enclosing_Lib_Unit_Node (N)));

   begin
      --  If the current compilation unit is a child unit, go to its parent

      while Is_Child_Unit (Main_CU) and then Main_CU /= N_CU loop
         Main_CU := Unique_Defining_Entity
           (Unit (Enclosing_Lib_Unit_Node (Scope (Main_CU))));
      end loop;

      return N_CU = Main_CU;
   end Is_Declared_In_Main_Unit_Or_Parent;

   ---------------------
   -- Is_Empty_Others --
   ---------------------

   function Is_Empty_Others
     (N : N_Case_Statement_Alternative_Id)
      return Boolean
   is
      First_Choice : constant Node_Id := First (Discrete_Choices (N));
   begin
      return
        Nkind (First_Choice) = N_Others_Choice
        and then Is_Empty_List (Others_Discrete_Choices (First_Choice));
   end Is_Empty_Others;

   ----------------------------------
   -- Is_Error_Signaling_Statement --
   ----------------------------------

   function Is_Error_Signaling_Statement (N : Node_Id) return Boolean is
   begin
      case Nkind (N) is
         when N_Raise_xxx_Error | N_Raise_Statement | N_Raise_Expression =>
            return True;

         when N_Pragma =>
            if Is_Pragma_Check (N, Name_Assert) then
               declare
                  Arg1 : constant Node_Id :=
                    First (Pragma_Argument_Associations (N));
                  Arg2 : constant Node_Id := Next (Arg1);
                  Expr : constant Node_Id := Expression (Arg2);
               begin
                  return Compile_Time_Known_Value (Expr)
                    and then Expr_Value (Expr) = Uint_0;
               end;
            else
               return False;
            end if;

         when N_Procedure_Call_Statement
            | N_Entry_Call_Statement
         =>
            if Is_Error_Signaling_Procedure (Get_Called_Entity (N)) then
               declare
                  Caller : constant Entity_Id :=
                    Unique_Entity
                      (Lib.Xref.SPARK_Specific.
                         Enclosing_Subprogram_Or_Library_Package (N));
               begin
                  --  A call to an error-signaling procedure is used to signal
                  --  an error, and should be proved unreachable, unless the
                  --  caller is a possibly nonreturning procedure.

                  return not (Ekind (Caller) = E_Procedure
                                and then
                              Is_Possibly_Nonreturning_Procedure (Caller));
               end;
            else
               return False;
            end if;

         --  Recognize calls to functions with a precondition of False

         when N_Function_Call =>
            declare
               Subp     : constant Entity_Id := Get_Called_Entity (N);
               Pre_List : constant Node_Lists.List :=
                 Find_Contracts (Subp, Pragma_Precondition);
               use type Ada.Containers.Count_Type;
            begin
               return Pre_List.Length = 1
                 and then
                   (declare
                      Expr : constant N_Subexpr_Id := Pre_List.First_Element;
                    begin
                      Nkind (Expr) in N_Expanded_Name | N_Identifier
                        and then Entity (Expr) = Standard_False);
            end;

         when N_Call_Marker =>
            return Is_Error_Signaling_Statement (Next (N));

         when others =>
            return False;
      end case;
   end Is_Error_Signaling_Statement;

   ----------------------
   -- Is_External_Call --
   ----------------------

   function Is_External_Call (N : N_Call_Id) return Boolean is
      Nam : constant Node_Id := Name (N);
   begin
      --  External calls are those with the selected_component syntax and whose
      --  prefix is anything except a (protected) type.
      return Nkind (Nam) = N_Selected_Component
        and then
          not (Nkind (Prefix (Nam)) in N_Has_Entity
               and then Ekind (Entity (Prefix (Nam))) = E_Protected_Type);
   end Is_External_Call;

   ----------------------
   -- Is_Global_Entity --
   ----------------------

   pragma Annotate
     (Xcov, Exempt_On, "Only used in the predicate of Flow_Types.Global_Set");
   function Is_Global_Entity (E : Entity_Id) return Boolean is
     (Ekind (E) in E_Loop_Parameter
                 | E_Variable
                 | Formal_Kind
                 | E_Protected_Type
                 | E_Task_Type
        or else

      --  Constants that are visibly of an access type are treated like
      --  variables. Hence using Is_Access_Type instead of Has_Access_Type
      --  here.

      (Ekind (E) = E_Constant and then
         (Is_Access_Variable (Etype (E)) or else Has_Variable_Input (E)))
        or else
      (Ekind (E) = E_Abstract_State and then not Is_Null_State (E)));
   --  ??? this could be further restricted basen on what may appear in
   --  Proof_In, Input, and Output.
   pragma Annotate (Xcov, Exempt_Off);

   -----------------------------
   -- Is_Ignored_Pragma_Check --
   -----------------------------

   function Is_Ignored_Pragma_Check (N : N_Pragma_Id) return Boolean is
   begin
      return Is_Pragma_Check (N, Name_Precondition)
               or else
             Is_Pragma_Check (N, Name_Pre)
               or else
             Is_Pragma_Check (N, Name_Postcondition)
               or else
             Is_Pragma_Check (N, Name_Post)
               or else
             Is_Pragma_Check (N, Name_Refined_Post)
               or else
             Is_Pragma_Check (N, Name_Static_Predicate)
               or else
             Is_Pragma_Check (N, Name_Predicate)
               or else
             Is_Pragma_Check (N, Name_Dynamic_Predicate);
   end Is_Ignored_Pragma_Check;

   --------------------------
   -- Is_In_Analyzed_Files --
   --------------------------

   function Is_In_Analyzed_Files (E : Entity_Id) return Boolean is
      Real_Entity : constant Node_Id :=
        (if Is_Itype (E)
         then Associated_Node_For_Itype (E)
         else E);

      Encl_Unit : constant Node_Id := Enclosing_Lib_Unit_Node (Real_Entity);
      --  The library unit containing E

      Main_Unit_Node : constant Node_Id := Cunit (Main_Unit);

   begin
      --  Check if the entity is either in the spec or in the body of the
      --  current compilation unit. gnat2why is now only called on requested
      --  files, so otherwise just return False.

      return Encl_Unit in Main_Unit_Node | Library_Unit (Main_Unit_Node);
   end Is_In_Analyzed_Files;

   ----------------------------------
   -- Is_In_Statically_Dead_Branch --
   ----------------------------------

   function Is_In_Statically_Dead_Branch (N : Node_Id) return Boolean is
      Anc  : Node_Id := Parent (N);
      Prev : Node_Id := N;

      function Comes_From_Dead_Branch (If_Stmt, Stmt : Node_Id) return Boolean
        with Pre => Nkind (If_Stmt) = N_If_Statement;
      --  @param If_Stmt an if statement node
      --  @param Stmt a statement node
      --  @return True iff the if-statement contains a statically dead branch
      --      and the statement is at the top-level of the corresponding branch

      function Comes_From_This_Dead_Branch
        (If_Stmt, Stmt : Node_Id)
         return Boolean
        with Pre => Nkind (If_Stmt) in N_If_Statement | N_Elsif_Part;
      --  @param If_Stmt an if statement or els_if part
      --  @param Stmt a statement node
      --  @return True iff the "then" condition of the statement or part is
      --      statically dead and contains the Stmt node

      function Has_True_Condition (If_Stmt : Node_Id) return Boolean
        with Pre => Nkind (If_Stmt) = N_If_Statement;
      --  @param If_Stmt an if statement node
      --  @return True iff the main condition or any of the elsif conditions is
      --    statically true

      ----------------------------
      -- Comes_From_Dead_Branch --
      ----------------------------

      function Comes_From_Dead_Branch (If_Stmt, Stmt : Node_Id) return Boolean
      is
      begin
         --  check if then branch is dead and contains our stmt
         if Comes_From_This_Dead_Branch (If_Stmt, Stmt) then
            return True;
         end if;

         --  check if any of the elsif branches is dead and contains our stmt
         if Present (Elsif_Parts (If_Stmt)) then
            declare
               Elt : Node_Id := First (Elsif_Parts (If_Stmt));
            begin
               while Present (Elt) loop
                  if Comes_From_This_Dead_Branch (Elt, Stmt) then
                     return True;
                  end if;
                  Next (Elt);
               end loop;
            end;
         end if;

         --  check if the else branch is dead and contains our stmt
         if List_Containing (Stmt) = Else_Statements (If_Stmt)
           and then Has_True_Condition (If_Stmt)
         then
            return True;
         end if;
         return False;
      end Comes_From_Dead_Branch;

      ---------------------------------
      -- Comes_From_This_Dead_Branch --
      ---------------------------------

      function Comes_From_This_Dead_Branch
        (If_Stmt, Stmt : Node_Id)
         return Boolean
      is (Nkind (Condition (If_Stmt)) in N_Expanded_Name | N_Identifier
           and then Entity (Condition (If_Stmt)) = Standard_False
           and then List_Containing (Stmt) = Then_Statements (If_Stmt));

      ------------------------
      -- Has_True_Condition --
      ------------------------

      function Has_True_Condition (If_Stmt : Node_Id) return Boolean is
      begin
         if Nkind (Condition (If_Stmt)) in N_Expanded_Name | N_Identifier
           and then Entity (Condition (If_Stmt)) = Standard_True
         then
            return True;
         end if;
         if Present (Elsif_Parts (If_Stmt)) then
            declare
               Elt : Node_Id := First (Elsif_Parts (If_Stmt));
            begin
               while Present (Elt) loop
                  if Nkind (Condition (Elt)) in N_Expanded_Name | N_Identifier
                    and then Entity (Condition (Elt)) = Standard_True
                  then
                     return True;
                  end if;
                  Next (Elt);
               end loop;
            end;
         end if;
         return False;
      end Has_True_Condition;

   --  Start of processing for Is_In_Statically_Dead_Branch

   begin
      while Nkind (Anc) not in N_Entity_Body and then Present (Anc) loop
         if Nkind (Anc) = N_If_Statement
           and then Comes_From_Dead_Branch (Anc, Prev)
         then
            return True;
         elsif Nkind (Anc) = N_Elsif_Part then
            Anc := Parent (Anc);
         else
            Prev := Anc;
            Anc := Parent (Anc);
         end if;
      end loop;
      return False;
   end Is_In_Statically_Dead_Branch;

   -----------------------
   -- Is_Local_Borrower --
   -----------------------

   function Is_Local_Borrower (E : Entity_Id) return Boolean is
      T : constant Entity_Id := Retysp (Etype (E));
   begin
      return Ekind (E) in E_Variable | E_Constant
        and then Is_Anonymous_Access_Object_Type (T)
        and then not Is_Access_Constant (T);
   end Is_Local_Borrower;

   ----------------------
   -- Is_Local_Context --
   ----------------------

   function Is_Local_Context (Scop : Entity_Id) return Boolean is
   begin
      return Is_Subprogram_Or_Entry (Scop)
        or else Ekind (Scop) = E_Block;
   end Is_Local_Context;

   ---------------------------------
   -- Is_Not_Hidden_Discriminant  --
   ---------------------------------

   function Is_Not_Hidden_Discriminant (E : E_Discriminant_Id) return Boolean
   is (Present (Root_Discriminant (E)));

   ----------------------
   -- Is_Others_Choice --
   ----------------------

   function Is_Others_Choice (Choices : List_Id) return Boolean is
   begin
      return List_Length (Choices) = 1
        and then Nkind (First (Choices)) = N_Others_Choice;
   end Is_Others_Choice;

   ----------------------
   -- Is_Package_State --
   ----------------------

   function Is_Package_State (E : Entity_Id) return Boolean is
     ((case Ekind (E) is
          when E_Abstract_State => True,
          when E_Constant       => Ekind (Scope (E)) = E_Package
                                   and then not In_Generic_Actual (E)
                                   and then (Is_Access_Variable (Etype (E))
                                               or else
                                             Has_Variable_Input (E)),
          when E_Variable       => Ekind (Scope (E)) = E_Package,
          when others           => False)
      and then
        Comes_From_Source (E));

   ----------------------------------
   -- Is_Part_Of_Concurrent_Object --
   ----------------------------------

   function Is_Part_Of_Concurrent_Object (E : Entity_Id) return Boolean is
   begin
      if Ekind (E) in E_Abstract_State | E_Variable then
         declare
            Encapsulating : constant Entity_Id := Encapsulating_State (E);

         begin
            return Present (Encapsulating)
              and then Is_Single_Concurrent_Object (Encapsulating);
         end;

      else
         return False;
      end if;
   end Is_Part_Of_Concurrent_Object;

   ---------------------------------
   -- Is_Part_Of_Protected_Object --
   ---------------------------------

   function Is_Part_Of_Protected_Object (E : Entity_Id) return Boolean is
   begin
      if Ekind (E) in E_Abstract_State | E_Variable then
         declare
            Encapsulating : constant Entity_Id := Encapsulating_State (E);

         begin
            return Present (Encapsulating)
              and then Ekind (Encapsulating) = E_Variable
              and then Ekind (Etype (Encapsulating)) = E_Protected_Type;
         end;

      else
         return False;
      end if;
   end Is_Part_Of_Protected_Object;

   ------------------------
   -- Is_Path_Expression --
   ------------------------

   function Is_Path_Expression (Expr : N_Subexpr_Id) return Boolean is

      function Is_Path_Expression_Ann (Expr : Node_Id) return Boolean;
      --  Check whether Expr is the prefix of a path

      ----------------------------
      -- Is_Path_Expression_Ann --
      ----------------------------

      function Is_Path_Expression_Ann (Expr : Node_Id) return Boolean is
      begin
         case Nkind (Expr) is
         when N_Expanded_Name
            | N_Identifier
         =>
            return True;

         when N_Explicit_Dereference
            | N_Indexed_Component
            | N_Selected_Component
            | N_Slice
         =>
            return Is_Path_Expression_Ann (Prefix (Expr));

         --  Special value NULL corresponds to an empty path

         when N_Null =>
            return True;

         --  Object returned by an (extension) aggregate, an allocator, or
         --  a function call corresponds to a path.

         when N_Aggregate
            | N_Allocator
            | N_Delta_Aggregate
            | N_Extension_Aggregate
            | N_Function_Call
         =>
            return True;

         when N_Attribute_Reference =>

            --  Old and Loop_Entry attributes can only be called on new
            --  objects. Update attribute is similar to delta aggregates.

            return Attribute_Name (Expr) in Name_Loop_Entry
                                          | Name_Old
                                          | Name_Update;

         when N_Qualified_Expression
            | N_Type_Conversion
            | N_Unchecked_Type_Conversion
         =>
            return Is_Path_Expression_Ann (Expression (Expr));

         when others =>
            return False;
         end case;
      end Is_Path_Expression_Ann;

   --  Start of processing for Is_Path_Expression

   begin
      case Nkind (Expr) is
         when N_Attribute_Reference =>
            if Attribute_Name (Expr) in Name_Access
                                      | Name_First
                                      | Name_Last
                                      | Name_Length
            then
               return Is_Path_Expression_Ann (Prefix (Expr));
            else
               return Is_Path_Expression_Ann (Expr);
            end if;

         --  Path op null or null op Path is a path

         when N_Op_Eq | N_Op_Ne =>
            return (Nkind (Left_Opnd (Expr)) = N_Null
                    and then Is_Path_Expression_Ann (Right_Opnd (Expr)))
              or else (Nkind (Right_Opnd (Expr)) = N_Null
                       and then Is_Path_Expression_Ann (Left_Opnd (Expr)));

         when others =>
            return Is_Path_Expression_Ann (Expr);
      end case;
   end Is_Path_Expression;

   ---------------
   -- Is_Pragma --
   ---------------

   function Is_Pragma (N : Node_Id; Name : Pragma_Id) return Boolean is
     (Nkind (N) = N_Pragma
        and then Get_Pragma_Id (Pragma_Name (N)) = Name);

   ----------------------------------
   -- Is_Pragma_Annotate_GNATprove --
   ----------------------------------

   function Is_Pragma_Annotate_GNATprove (N : Node_Id) return Boolean is
     (Is_Pragma (N, Pragma_Annotate)
        and then
      Get_Name_String
        (Chars (Get_Pragma_Arg (First (Pragma_Argument_Associations (N)))))
      = "gnatprove");

   ------------------------------
   -- Is_Pragma_Assert_And_Cut --
   ------------------------------

   function Is_Pragma_Assert_And_Cut (N : N_Pragma_Id) return Boolean is
      Orig : constant Node_Id := Original_Node (N);
   begin
      return Present (Orig)
        and then Is_Pragma (Orig, Pragma_Assert_And_Cut);
   end Is_Pragma_Assert_And_Cut;

   ---------------------
   -- Is_Pragma_Check --
   ---------------------

   function Is_Pragma_Check (N : Node_Id; Name : Name_Id) return Boolean is
     (Is_Pragma (N, Pragma_Check)
        and then
      Chars (Get_Pragma_Arg (First (Pragma_Argument_Associations (N))))
      = Name);

   --------------------------------
   -- Is_Predicate_Function_Call --
   --------------------------------

   function Is_Predicate_Function_Call (N : Node_Id) return Boolean is
     (Nkind (N) = N_Function_Call
        and then Nkind (Name (N)) in N_Has_Entity
        and then Is_Predicate_Function (Entity (Name (N))));

   --------------------------------------
   -- Is_Predefined_Initialized_Entity --
   --------------------------------------

   function Is_Predefined_Initialized_Entity (E : Entity_Id) return Boolean is
   begin
      --  In general E might not be in SPARK (e.g. if it came from the front
      --  end globals), so we prefer not to risk a precise check and crash
      --  by an accident. Instead, we do a simple and robust check that is
      --  known to be potentially incomplete (e.g. it will not recognize
      --  variables with default initialization).
      if In_Predefined_Unit (E) then
         case Ekind (E) is
            when E_Variable =>
               declare
                  Full_Type : constant Entity_Id :=
                    (if Is_Private_Type (Etype (E))
                     then Full_View (Etype (E))
                     else Etype (E));
               begin
                  return (Is_Scalar_Type (Full_Type)
                          or else Is_Access_Type (Full_Type))
                    and then Present (Expression (Parent (E)));
               end;
            when E_Abstract_State =>
               declare
                  Initializes : constant Dependency_Maps.Map :=
                    Parse_Initializes (Scope (E), Get_Flow_Scope (Scope (E)));
               begin
                  return Initializes.Contains (Direct_Mapping_Id (E));
               end;
            when others =>
               return False;
         end case;
      else
         return False;
      end if;
   end Is_Predefined_Initialized_Entity;

   -------------------------------------
   -- Is_Protected_Component_Or_Discr --
   -------------------------------------

   function Is_Protected_Component_Or_Discr (E : Entity_Id) return Boolean is
   begin
      --  Protected discriminants appear either as E_In_Parameter (in spec of
      --  protected types, e.g. in pragma Priority) or as E_Discriminant
      --  (everywhere else).
      return Ekind (E) in E_Component | E_Discriminant | E_In_Parameter
        and then Ekind (Scope (E)) = E_Protected_Type;
   end Is_Protected_Component_Or_Discr;

   --------------------------------
   -- Is_Reborrowed_On_All_Paths --
   --------------------------------

   function Is_Reborrowed_On_All_Paths
     (Stmts       : List_Id;
      Brower      : Entity_Id;
      Explanation : out Unbounded_String;
      Decls       : List_Id := No_List;
      End_Stmt    : Node_Id := Empty) return Boolean
   is
      N             : Node_Id := First (Decls);
      In_Decls      : Boolean := True;
      End_Reached   : Boolean := False with Ghost;
      --  Flag to check that if provided, the End_Stmt has been encountered

   begin
      loop
         if No (N) and then In_Decls then
            N := First (Stmts);
            In_Decls := False;
         end if;

         exit when No (N);

         if N = End_Stmt then
            End_Reached := True;
            exit;
         end if;

         case Nkind (N) is

            --  If the borrower is assigned, check that the path contains
            --  a dereference.

            when N_Assignment_Statement =>
               declare
                  Lvalue : constant Node_Id := Name (N);
               begin
                  if Nkind (Lvalue) in N_Identifier | N_Expanded_Name
                    and then Entity (Lvalue) = Brower
                    and then Is_Strict_Subpath (Expression (N))
                  then
                     return True;
                  end if;
               end;

            --  Early exits, we do not consider the path

            when N_Extended_Return_Statement
               | N_Simple_Return_Statement
               | N_Exit_Statement
               | N_Raise_xxx_Error
               | N_Raise_Statement
            =>
               return True;

            --  A Goto statement could make us skip later updates on
            --  this path, return False.

            when N_Goto_Statement =>
               raise Goto_Found;

            when N_Case_Statement =>
               declare
                  OK_On_All   : Boolean := True;
                  Alternative : Opt_N_Case_Statement_Alternative_Id :=
                    First_Non_Pragma (Alternatives (N));
               begin
                  loop
                     if not Is_Reborrowed_On_All_Paths
                       (Statements (Alternative), Brower, Explanation)
                     then
                        OK_On_All := False;
                        exit;
                     end if;
                     Next_Non_Pragma (Alternative);
                     exit when No (Alternative);
                  end loop;

                  if OK_On_All then
                     return True;
                  end if;
               end;

            when N_If_Statement =>
               declare
                  OK_On_All  : Boolean :=
                    Is_Reborrowed_On_All_Paths
                      (Then_Statements (N), Brower, Explanation)
                      and then Is_Reborrowed_On_All_Paths
                        (Else_Statements (N), Brower, Explanation);
                  Elsif_Part : Opt_N_Elsif_Part_Id :=
                    First (Elsif_Parts (N));
               begin
                  if OK_On_All then
                     while Present (Elsif_Part) loop
                        if not Is_Reborrowed_On_All_Paths
                          (Then_Statements (Elsif_Part), Brower, Explanation)
                        then
                           OK_On_All := False;
                           exit;
                        end if;
                        Next (Elsif_Part);
                     end loop;

                     if OK_On_All then
                        return True;
                     end if;
                  end if;
               end;

            when N_Handled_Sequence_Of_Statements =>
               if Is_Reborrowed_On_All_Paths
                 (Statements (N), Brower, Explanation)
               then
                  return True;
               end if;

            --  Do not consider nested loop as we do not know if their
            --  body will be executed at least once. Still check them
            --  for absence of Gotos.

            when N_Loop_Statement =>
               declare
                  Unused : constant Boolean :=
                    Is_Reborrowed_On_All_Paths
                      (Statements (N), Brower, Explanation);
               begin
                  null;
               end;

            when N_Block_Statement =>
               if Is_Reborrowed_On_All_Paths
                 (Statements (Handled_Statement_Sequence (N)),
                  Brower, Explanation,
                  Decls => Declarations (N))
               then
                  return True;
               end if;

            --  Calls could update the borrower, but we cannot be sure.
            --  Ignore them.

            when N_Entry_Call_Statement
               | N_Procedure_Call_Statement
            =>
               null;

            when N_Ignored_In_SPARK
               | N_Itype_Reference
               | N_Object_Renaming_Declaration
               | N_Subtype_Declaration
               | N_Full_Type_Declaration
               | N_Object_Declaration
               | N_Package_Body
               | N_Package_Declaration
               | N_Pragma
               | N_Subprogram_Body
               | N_Subprogram_Declaration
               | N_Delay_Statement
            =>
               null;

            when others =>
               pragma Annotate (Xcov, Exempt_On, "Debugging code");
               Ada.Text_IO.Put_Line
                 ("[SPARK_Util.Is_Reborrowed_On_All_Paths] kind ="
                  & Node_Kind'Image (Nkind (N)));
               raise Program_Error;
               pragma Annotate (Xcov, Exempt_Off);
         end case;
         Next (N);
      end loop;

      pragma Assert (No (End_Stmt) or else End_Reached);
      Explanation := To_Unbounded_String
        ('"' & Source_Name (Brower))
        & """ might not be updated on all paths";
      return False;
   end Is_Reborrowed_On_All_Paths;

   ---------------------------
   -- Is_Rooted_In_Constant --
   ---------------------------

   function Is_Rooted_In_Constant (Expr : N_Subexpr_Id) return Boolean is
      Root : constant Entity_Id :=
        (if Is_Path_Expression (Expr) then Get_Root_Object (Expr)
         else Empty);
   begin
      return Present (Root)
        and then
          (not Is_Deep (Etype (Root))
           or else (Is_Constant_In_SPARK (Root)
                    and then Ekind (Root) /= E_In_Parameter)
           or else Traverse_Access_To_Constant (Expr));
   end Is_Rooted_In_Constant;

   ------------------------------
   -- Is_Quantified_Loop_Param --
   ------------------------------

   function Is_Quantified_Loop_Param (E : Entity_Id) return Boolean is
   begin
      --  Parent of the scope might be rewritten by inlining for proof, so we
      --  look at the original node.
      return
        Present (Scope (E))
        and then Present (Parent (Scope (E)))
        and then Nkind (Original_Node (Parent (Scope (E)))) in
            N_Quantified_Expression
          | N_Aggregate
          | N_Delta_Aggregate
          | N_Iterated_Component_Association;
   end Is_Quantified_Loop_Param;

   ------------------------------------
   -- Is_Selected_For_Loop_Unrolling --
   ------------------------------------

   function Is_Selected_For_Loop_Unrolling
     (Loop_Stmt : N_Loop_Statement_Id)
      return Boolean
   is
      --  Variables used in loop unrolling
      Low_Val  : Uint;
      High_Val : Uint;
      Unroll   : Unrolling_Type;
   begin
      Candidate_For_Loop_Unrolling (Loop_Stmt   => Loop_Stmt,
                                    Output_Info => False,
                                    Result      => Unroll,
                                    Low_Val     => Low_Val,
                                    High_Val    => High_Val);

      return not Gnat2Why_Args.No_Loop_Unrolling
        and then Unroll /= No_Unrolling;
   end Is_Selected_For_Loop_Unrolling;

   -------------------------
   -- Is_Singleton_Choice --
   -------------------------

   function Is_Singleton_Choice (Choices : List_Id) return Boolean is
      Choice : constant Node_Id := First (Choices);
   begin
      return List_Length (Choices) = 1
        and then
          Nkind (Choice)
            not in N_Others_Choice | N_Subtype_Indication | N_Range
        and then not
          (Nkind (Choice) in N_Identifier | N_Expanded_Name
           and then Is_Type (Entity (Choice)));
   end Is_Singleton_Choice;

   -----------------------------
   -- Is_Specializable_Formal --
   -----------------------------

   function Is_Specializable_Formal (Formal : Formal_Kind_Id) return Boolean is
     (Ekind (Formal) = E_In_Parameter
      and then Is_Anonymous_Access_Type (Etype (Formal))
      and then Is_Access_Subprogram_Type (Etype (Formal))
      and then Is_Function_Type
        (Directly_Designated_Type (Etype (Formal))));

   ---------------------------
   -- Is_Specialized_Actual --
   ---------------------------

   function Is_Specialized_Actual
     (Expr                 : Node_Id;
      Specialized_Entities : Node_Maps.Map := Node_Maps.Empty_Map)
      return Boolean
   is
   begin
      --  If Expr is an identifier, it shall be in the Specialized_Entities map

      if Nkind (Expr) in N_Identifier | N_Expanded_Name then
         return Specialized_Entities.Contains (Entity (Expr));
      end if;

      --  Otherwise, Expr shall be an access attribute to a function

      if not Is_Access_Attribute_Of_Function (Expr) then
         return False;
      end if;

      --  Its parent shall be a function call annotated with higher order
      --  specialization.

      declare
         Call : constant Node_Id := Parent (Expr);
         Subp : constant Entity_Id :=
           (if Nkind (Call) in N_Function_Call | N_Procedure_Call_Statement
            then Get_Called_Entity (Call)
            else Empty);
      begin
         if No (Subp)
           or else Ekind (Subp) not in E_Function | E_Procedure
           or else not Has_Higher_Order_Specialization_Annotation (Subp)
         then
            return False;
         end if;

         --  Expr shall be the actual parameter associated to an anonymous
         --  access-to-function formal parameter.

         declare
            Formal : constant Entity_Id := Get_Formal_From_Actual (Expr);
         begin
            return Present (Formal)
              and then Ekind (Formal) = E_In_Parameter
              and then Is_Anonymous_Access_Type (Etype (Formal));
         end;
      end;
   end Is_Specialized_Actual;

   -------------------------
   -- Is_Specialized_Call --
   -------------------------

   function Is_Specialized_Call
     (Call                 : Node_Id;
      Specialized_Entities : Node_Maps.Map := Node_Maps.Empty_Map)
      return Boolean
   is
      Subp : constant Entity_Id :=
        (if Nkind (Call) in N_Op then Entity (Call)
         else Sem_Aux.Get_Called_Entity (Call));
   begin
      return Ekind (Subp) in E_Function | E_Procedure
        and then Has_Higher_Order_Specialization_Annotation (Subp)
        and then not
          Get_Specialized_Parameters (Call, Specialized_Entities).Is_Empty;
   end Is_Specialized_Call;

   -----------------------
   -- Is_Strict_Subpath --
   -----------------------

   function Is_Strict_Subpath (Expr : N_Subexpr_Id) return Boolean is
      Path : N_Subexpr_Id := Expr;

   begin
      loop
         case Nkind (Path) is

            --  We have reached the root of the path, return False

            when N_Expanded_Name
               | N_Identifier
            =>
               return False;

            --  The traversal function call might create a strict subpath, but
            --  we cannot be sure. Search the first parameter.

            when N_Function_Call =>
               pragma Assert (Is_Traversal_Function_Call (Path));
               Path := First_Actual (Path);

            --  Access attribute references and explicit derefences are
            --  ignored. Only actual component accesses are considered to be
            --  strict subpathes.

            when N_Attribute_Reference =>
               pragma Assert (Attribute_Name (Path) = Name_Access);
               Path := Prefix (Path);

            when N_Explicit_Dereference
               | N_Slice
            =>
               Path := Prefix (Path);

            when N_Indexed_Component
               | N_Selected_Component
            =>
               return True;

            when N_Qualified_Expression
               | N_Type_Conversion
               | N_Unchecked_Type_Conversion
            =>
               Path := Expression (Path);

            when others =>
               raise Program_Error;
         end case;
      end loop;
   end Is_Strict_Subpath;

   ---------------------
   -- Is_Synchronized --
   ---------------------

   function Is_Synchronized (E : Entity_Id) return Boolean is
   begin
      return
        Is_Synchronized_Object (E)
          or else Is_Synchronized_State (E)
          or else Is_Part_Of_Concurrent_Object (E)
          or else Ekind (E) in E_Protected_Type | E_Task_Type;
          --  We get protected/task types here when they act as globals for
          --  subprograms nested in the type itself.
   end Is_Synchronized;

   ------------------------
   -- Is_Supported_Alias --
   ------------------------

   function Supported_Alias (Expr : Node_Id) return Entity_Id is
      Simple_Address : constant Boolean :=
        Present (Expr)
        and then Nkind (Expr) = N_Attribute_Reference
        and then Attribute_Name (Expr) = Name_Address;
      Prefix_Expr     : constant Node_Id :=
        (if Simple_Address then Prefix (Expr)
         else Empty);
      Aliased_Object  : constant Entity_Id :=
        (if Simple_Address
         then Get_Root_Object (Prefix_Expr, Through_Traversal => False)
         else Empty);
   begin
      if Present (Aliased_Object)
        and then
          Ekind (Aliased_Object) in E_Constant
                                  | E_Loop_Parameter
                                  | E_Variable
                                  | Formal_Kind
      then
         return Aliased_Object;
      else
         return Empty;
      end if;
   end Supported_Alias;

   ---------------------------
   -- Is_Writable_Parameter --
   ---------------------------

   function Is_Writable_Parameter (E : Entity_Id) return Boolean is
   begin
      return Is_Access_Variable (Base_Type (Etype (E)));
   end Is_Writable_Parameter;

   --------------------------------
   -- Is_Traversal_Function_Call --
   --------------------------------

   function Is_Traversal_Function_Call (Expr : Node_Id) return Boolean is
   begin
      return Nkind (Expr) = N_Function_Call
        and then Present (Get_Called_Entity (Expr))
        and then Is_Traversal_Function (Get_Called_Entity (Expr));
   end Is_Traversal_Function_Call;

   ---------------------
   -- Location_String --
   ---------------------

   function Location_String (Input         : Source_Ptr;
                             Columns       : Boolean := True;
                             Chain_Markers : Boolean := True;
                             Natural_Order : Boolean := False) return String
   is
      Slc : Source_Ptr := Input;
      Buf : Unbounded_String;

      procedure Combine (A : in out Unbounded_String; B : String);

      -------------
      -- Combine --
      -------------

      procedure Combine (A : in out Unbounded_String; B : String) is
      begin
         if Natural_Order then
            A := B & A;
         else
            Append (A, B);
         end if;
      end Combine;

   --  Start of processing for Location_String

   begin
      loop
         declare
            File   : constant String := File_Name (Slc);
            Line   : constant Physical_Line_Number :=
              Get_Physical_Line_Number (Slc);
            Column : constant Column_Number := Get_Column_Number (Slc);
         begin
            Combine (Buf,
                     File & ':' & Image (Positive (Line), 1)
                     & (if Columns then
                          ':' & Image (Positive (Column), 1)
                        else ""));
            exit when Instantiation_Location (Slc) = No_Location;
            Combine (Buf,
                     (if Chain_Markers then
                        (if Comes_From_Inlined_Body (Slc)
                         then ":inlined:"
                         else ":instantiated:")
                      else ":"));
            Slc := Instantiation_Location (Slc);
         end;
      end loop;
      return To_String (Buf);
   end Location_String;

   -----------------------------------
   -- Loop_Entity_Of_Exit_Statement --
   -----------------------------------

   function Loop_Entity_Of_Exit_Statement
     (N : N_Exit_Statement_Id)
      return Entity_Id
   is
      function Is_Loop_Statement (N : Node_Id) return Boolean is
        (Nkind (N) = N_Loop_Statement);
      --  Returns True if N is a loop statement

      function Innermost_Loop_Stmt is new
        First_Parent_With_Property (Is_Loop_Statement);
   begin
      --  If the name is directly in the given node, return that name

      if Present (Name (N)) then
         return Entity (Name (N));

      --  Otherwise the exit statement belongs to the innermost loop, so
      --  simply go upwards (follow parent nodes) until we encounter the
      --  loop.

      else
         return Entity (Identifier (Innermost_Loop_Stmt (N)));
      end if;
   end Loop_Entity_Of_Exit_Statement;

   -------------------------------
   -- May_Issue_Warning_On_Node --
   -------------------------------

   function May_Issue_Warning_On_Node (N : Node_Id) return Boolean is
   begin
      if Instantiation_Location (Sloc (N)) = No_Location then
         declare
            Subp : constant Entity_Id :=
              Unique_Entity
                (Lib.Xref.SPARK_Specific.
                   Enclosing_Subprogram_Or_Library_Package (N));
         begin
            return Present (Subp)
              and then Analysis_Requested (Subp, With_Inlined => False);
         end;
      else
         return False;
      end if;
   end May_Issue_Warning_On_Node;

   ---------------------------
   -- Value_Is_Never_Leaked --
   ---------------------------

   function Value_Is_Never_Leaked (Expr : N_Subexpr_Id) return Boolean is
      Context : Node_Id := Parent (Expr);
      Nested  : Boolean := False;

   begin
      --  Check that Expr is a part of the definition of a library level
      --  constant.

      loop
         case Nkind (Context) is

            --  The allocating expression appears on the rhs of a library level
            --  constant declaration.

            when N_Object_Declaration =>
               declare
                  Obj : constant Entity_Id := Defining_Identifier (Context);
               begin
                  return ((not Nested and then Ekind (Obj) = E_Constant)
                          or else Is_Constant_In_SPARK (Obj))
                    and then Is_Library_Level_Entity (Obj);
               end;

            --  The allocating expression is the expression of a type
            --  conversion or a qualified expression.

            when N_Qualified_Expression
               | N_Type_Conversion
               | N_Unchecked_Type_Conversion
            =>
               null;

            --  The allocating expression occurs as the expression in another
            --  initialized allocator.

            when N_Allocator =>
               Nested := True;

            --  The allocating expression corresponds to a component value in
            --  an aggregate.

            when N_Aggregate
               | N_Component_Association
            =>
               Nested := True;

            when others =>
               return False;
         end case;

         Context := Parent (Context);
      end loop;
   end Value_Is_Never_Leaked;

   ---------------------
   -- No_Deep_Updates --
   ---------------------

   function No_Deep_Updates
     (Stmts       : List_Id;
      Variable    : Entity_Id;
      Explanation : out Unbounded_String;
      Decls       : List_Id := No_List;
      End_Stmt    : Node_Id := Empty) return Boolean
   is
      function Call_Update_Variables
        (Call      : N_Subprogram_Call_Id;
         Variables : Entity_Sets.Set) return Boolean;
      --  Return True if Call might modify a deep part of an element of
      --  Variables.

      function No_Deep_Updates
        (Stmts     : List_Id;
         Variables : Entity_Sets.Set;
         Decls     : List_Id := No_List;
         End_Stmt  : Node_Id := Empty) return Boolean;
      --  Return True if Decls & Stmts contains no updates to a deep part of an
      --  element of Variables. Stop before the statement End_Stmt is any.

      ---------------------------
      -- Call_Update_Variables --
      ---------------------------

      function Call_Update_Variables
        (Call      : N_Subprogram_Call_Id;
         Variables : Entity_Sets.Set) return Boolean
      is
         Update_Found : exception;

         procedure Check_Param
           (Formal : Formal_Kind_Id; Actual : N_Subexpr_Id);
         --  Raise Update_Found if a mutable parameter has as an actual a
         --  deep part of an element of Variables.

         -----------------
         -- Check_Param --
         -----------------

         procedure Check_Param
           (Formal : Formal_Kind_Id; Actual : N_Subexpr_Id)
         is
         begin
            if Ekind (Formal) in E_Out_Parameter | E_In_Out_Parameter
              or else (Has_Access_Type (Etype (Formal))
                       and then not Is_Access_Constant
                         (Retysp (Etype (Formal))))
            then
               if Is_Deep (Etype (Actual))
                 and then Variables.Contains (Get_Root_Object (Actual))
               then
                  raise Update_Found;
               end if;
            end if;
         end Check_Param;

         procedure Check_Parameters is new
           Iterate_Call_Parameters (Check_Param);

         Subp : constant Callable_Kind_Id := Get_Called_Entity (Call);

      --  Start of processing for Call_Update_Variables

      begin
         --  Search parameters for updates to a deep part of an element of
         --  Browers.

         Check_Parameters (Call);

         --  Check the global OUT and IN OUT of Subp

         declare
            Unused_Ids : Flow_Types.Flow_Id_Sets.Set;
            Write_Ids  : Flow_Types.Flow_Id_Sets.Set;

         begin
            Flow_Utility.Get_Proof_Globals (Subprogram      => Subp,
                                            Reads           => Unused_Ids,
                                            Writes          => Write_Ids,
                                            Erase_Constants => True,
                                            Scop            =>
                                              Get_Flow_Scope (Call));

            for F of Write_Ids loop
               if F.Kind = Direct_Mapping
                 and then Variables.Contains (Get_Direct_Mapping_Id (F))
               then
                  return True;
               end if;
            end loop;
         end;

         return False;

      exception
         when Update_Found =>
            return True;
      end Call_Update_Variables;

      ---------------------
      -- No_Deep_Updates --
      ---------------------

      function No_Deep_Updates
        (Stmts     : List_Id;
         Variables : Entity_Sets.Set;
         Decls     : List_Id := No_List;
         End_Stmt  : Node_Id := Empty) return Boolean
      is
         N             : Node_Id := First (Decls);
         In_Decls      : Boolean := True;
         Cur_Variables : Entity_Sets.Set := Variables;
         End_Reached   : Boolean := False with Ghost;
         --  Flag to check that if provided, the End_Stmt has been encountered

      begin
         loop
            if No (N) and then In_Decls then
               N := First (Stmts);
               In_Decls := False;
            end if;

            exit when No (N);

            if N = End_Stmt then
               End_Reached := True;
               exit;
            end if;

            case Nkind (N) is

               --  Check that the value referenced by an element of
               --  Variables is never assigned a value of a deep type
               --  outside of reborrows.

               when N_Assignment_Statement =>
                  declare
                     Lvalue : constant Node_Id := Name (N);
                     Root   : constant Entity_Id :=
                       Get_Root_Object (Lvalue);
                  begin
                     if (Nkind (Lvalue) not in N_Identifier
                                             | N_Expanded_Name
                         or else
                           not Is_Anonymous_Access_Type (Etype (Lvalue)))
                       and then Cur_Variables.Contains (Root)
                       and then Is_Deep (Etype (Lvalue))
                     then

                        --  Search for return statements in the sequence of
                        --  statements following N. If one is found, we do
                        --  not care about the update.
                        --  We could consider doing this optimization for
                        --  exit statements of the corresponding loop when
                        --  checking loop variants, and for statements
                        --  following the current block, if statement, or
                        --  case statement too.

                        declare
                           Following : Node_Id := N;
                        begin
                           loop
                              Next (Following);
                              if No (Following) then
                                 declare
                                    Through_Borrow : constant String :=
                                      (if Get_Root_Object (Lvalue) = Variable
                                       then ""
                                       else " through local borrower """
                                       & Source_Name (Root) & '"');
                                 begin
                                    Explanation := To_Unbounded_String
                                      ("the value designated by """)
                                      & Source_Name (Variable)
                                      & """ might be updated" & Through_Borrow;
                                    return False;
                                 end;
                              end if;
                              exit when Nkind (Following) in
                                    N_Simple_Return_Statement
                                  | N_Extended_Return_Statement
                                  | N_Raise_Statement;
                           end loop;
                        end;
                     end if;
                  end;

               --  If an element of Variables is borrowed, the borrower
               --  should not be updated. Add it to Cur_Variables.

               when N_Object_Declaration =>
                  declare
                     Def_Id : constant Entity_Id := Defining_Identifier (N);
                  begin
                     if Is_Local_Borrower (Def_Id)
                       and then Is_Deep
                         (Directly_Designated_Type (Etype (Def_Id)))
                       and then Cur_Variables.Contains
                         (Get_Root_Object (Expression (N)))
                     then
                        Cur_Variables.Insert (Def_Id);
                     end if;
                  end;

               when N_Case_Statement =>
                  declare
                     Alternative : Opt_N_Case_Statement_Alternative_Id :=
                       First_Non_Pragma (Alternatives (N));
                  begin
                     loop
                        if not No_Deep_Updates
                          (Statements (Alternative), Cur_Variables)
                        then
                           return False;
                        end if;
                        Next_Non_Pragma (Alternative);
                        exit when No (Alternative);
                     end loop;
                  end;

               when N_If_Statement =>
                  if No_Deep_Updates (Then_Statements (N), Cur_Variables)
                    and then
                      No_Deep_Updates (Else_Statements (N), Cur_Variables)
                  then
                     declare
                        Elsif_Part : Opt_N_Elsif_Part_Id :=
                          First (Elsif_Parts (N));
                     begin
                        while Present (Elsif_Part) loop
                           if not No_Deep_Updates
                             (Then_Statements (Elsif_Part), Cur_Variables)
                           then
                              return False;
                           end if;
                           Next (Elsif_Part);
                        end loop;
                     end;
                  else
                     return False;
                  end if;

               when N_Handled_Sequence_Of_Statements
                  | N_Loop_Statement
               =>
                  if not No_Deep_Updates (Statements (N), Cur_Variables)
                  then
                     return False;
                  end if;

               when N_Block_Statement =>
                  if not No_Deep_Updates
                    (Statements (Handled_Statement_Sequence (N)),
                     Cur_Variables, Decls => Declarations (N))
                  then
                     return False;
                  end if;

               --  Check that procedure/entry calls do not update elements
               --  of Cur_Variables.

               when N_Entry_Call_Statement
                  | N_Procedure_Call_Statement
               =>
                  if Call_Update_Variables (N, Cur_Variables) then
                     Explanation := To_Unbounded_String
                       ("the call to """)
                       & Source_Name (Get_Called_Entity (N))
                       & """ might update the value designated by """
                       & Source_Name (Variable) & '"';
                     return False;
                  end if;

               when N_Ignored_In_SPARK
                  | N_Itype_Reference
                  | N_Object_Renaming_Declaration
                  | N_Subtype_Declaration
                  | N_Full_Type_Declaration
                  | N_Package_Body
                  | N_Package_Declaration
                  | N_Pragma
                  | N_Subprogram_Body
                  | N_Subprogram_Declaration
                  | N_Delay_Statement
                  | N_Simple_Return_Statement
                  | N_Extended_Return_Statement
               =>
                  null;

               when others =>
                  pragma Annotate (Xcov, Exempt_On, "Debugging code");
                  Ada.Text_IO.Put_Line
                    ("[SPARK_Util.No_Deep_Updates] kind ="
                     & Node_Kind'Image (Nkind (N)));
                  raise Program_Error;
                  pragma Annotate (Xcov, Exempt_Off);
            end case;
            Next (N);
         end loop;

         pragma Assert (No (End_Stmt) or End_Reached);
         return True;
      end No_Deep_Updates;

   --  Start of processing for No_Deep_Updates

   begin
      if Is_Constant_In_SPARK (Variable)
        or else not Is_Deep (Etype (Variable))
        or else
          (Is_Anonymous_Access_Type (Etype (Variable))
           and then
             (Is_Access_Constant (Etype (Variable))
              or else not
                Is_Deep (Directly_Designated_Type (Etype (Variable)))))
      then
         return True;
      else
         declare
            Variables : Entity_Sets.Set;
         begin
            Variables.Insert (Variable);
            return No_Deep_Updates (Stmts, Variables, Decls, End_Stmt);
         end;
      end if;
   end No_Deep_Updates;

   ------------------------------------
   -- Number_Of_Assocs_In_Expression --
   ------------------------------------

   function Number_Of_Assocs_In_Expression (N : Node_Id) return Natural is
      Count : Natural := 0;

      function Find_Assoc (N : Node_Id) return Traverse_Result;
      --  Increments Count if N is a N_Component_Association

      ----------------
      -- Find_Assoc --
      ----------------

      function Find_Assoc (N : Node_Id) return Traverse_Result is
      begin
         case Nkind (N) is
            when N_Component_Association =>
               Count := Count + 1;
            when others => null;
         end case;
         return OK;
      end Find_Assoc;

      procedure Count_Assoc is new Traverse_More_Proc (Find_Assoc);

   --  Start of processing for Number_Of_Assocs_In_Expression

   begin
      Count_Assoc (N);
      return Count;
   end Number_Of_Assocs_In_Expression;

   --------------------------
   -- Obj_Has_Relaxed_Init --
   --------------------------

   function Obj_Has_Relaxed_Init (Obj : Object_Kind_Id) return Boolean is
   begin
      --  Discriminants are always initialized

      if Ekind (Obj) in E_Discriminant then
         return False;

      --  Parameters of loops which cannot be copied when not initialized are
      --  always initialized.

      elsif Ekind (Obj) = E_Loop_Parameter
        or else
         (Ekind (Obj) = E_Variable
          and then Is_Quantified_Loop_Param (Obj))
      then
         if Copy_Requires_Init (Etype (Obj)) then
            return False;
         end if;

         declare
            Q_Expr : constant Node_Id :=
              (if Ekind (Obj) = E_Variable
               then Original_Node (Parent (Scope (Obj)))
               else Parent (Parent (Obj)));
            I_Spec : constant Node_Id := Iterator_Specification (Q_Expr);

         begin
            --  On for of quantification over arrays, the quantified variable
            --  ranges over array elements.

            if Present (I_Spec) and then Is_Iterator_Over_Array (I_Spec) then
               declare
                  Arr_Expr : constant Node_Id := Name (I_Spec);
               begin
                  return Expr_Has_Relaxed_Init (Arr_Expr, No_Eval => False)
                    or else Has_Relaxed_Init
                      (Component_Type (Etype (Arr_Expr)));
               end;

            --  On for of quantification over containers, the quantified
            --  variable is assigned the result of Element.

            elsif Present (I_Spec) and then Of_Present (I_Spec) then
               declare
                  Element : constant Entity_Id :=
                    Get_Iterable_Type_Primitive
                      (Etype (Name (I_Spec)), Name_Element);
               begin
                  return Fun_Has_Relaxed_Init (Element);
               end;

            --  On for in quantification over containers, the quantified
            --  variable is assigned the result of First and Next.

            elsif Present (I_Spec) then
               declare
                  First : constant Entity_Id :=
                    Get_Iterable_Type_Primitive
                      (Etype (Name (I_Spec)), Name_First);
                  Next  : constant Entity_Id :=
                    Get_Iterable_Type_Primitive
                      (Etype (Name (I_Spec)), Name_Next);
               begin
                  return Fun_Has_Relaxed_Init (First)
                    or else Fun_Has_Relaxed_Init (Next);
               end;
            else
               return False;
            end if;
         end;

      --  An object which cannot be copied when not initialized can
      --  only be uninitialized if it is either an out parameter or a variable.

      elsif Ekind (Obj) in E_In_Parameter | E_In_Out_Parameter | E_Constant
        and then Copy_Requires_Init (Etype (Obj))
      then
         return False;

      --  Check whether the object is subjected to a Relaxed_Initialization
      --  aspect.

      elsif Ekind (Obj) in E_Variable | E_Constant | Formal_Kind
        and then Has_Relaxed_Initialization (Obj)
      then
         return True;

      --  Otherwise, the object has relaxed initialization if its type does

      else
         return Has_Relaxed_Init (Etype (Obj));
      end if;
   end Obj_Has_Relaxed_Init;

   ----------------------------------------
   -- Objects_Have_Compatible_Alignments --
   ----------------------------------------

   procedure Objects_Have_Compatible_Alignments
     (X           : Constant_Or_Variable_Kind_Id;
      Y           : Object_Kind_Id;
      Result      : out Boolean;
      Explanation : out Unbounded_String)
   is
      AX : Uint;
      AY : Uint;
      --  Alignment, which is coming either from the aspect or representation
      --  clause (when specified explicitly for stand-alone object) or from the
      --  type (when possible).

   begin
      --  Stand-alone objects can have alignment specified explicitly

      if Known_Alignment (X) then
         AX := Alignment (X);
      else
         Result := False;
         Explanation :=
           To_Unbounded_String
             (Source_Name (X) & " doesn't have an "
              & "Alignment representation clause or aspect");
         return;
      end if;

      --  Similar for the second object, but also recognize implicit alignment
      --  for formal parameters.

      if Known_Alignment (Y) then
         AY := Alignment (Y);

      elsif Is_Formal (Y)
        and then Known_Alignment (Etype (Y))
      then
         if Is_Aliased (Y) then
            AY := Alignment (Etype (Y));
         else
            Result := False;
            Explanation :=
              To_Unbounded_String
                (Source_Name (X) &
                 " must be aliased for its alignment to be known");
            return;
         end if;
      else
         Result := False;
         Explanation :=
           To_Unbounded_String
             (Source_Name (Y) & " doesn't have an "
              & "Alignment representation clause or aspect");
         return;
      end if;

      if AY mod AX /= Uint_0 then
         Result := False;
         Explanation :=
           To_Unbounded_String
             ("alignment of " & Source_Name (Y) &
              " (which is " & UI_Image (AY) & ")" &
              " must be a multiple of the " &
              "alignment of " & Source_Name (X) &
              " (which is " & UI_Image (AX) & ")");

         return;
      end if;
      Result := True;
      Explanation := Null_Unbounded_String;
   end Objects_Have_Compatible_Alignments;

   -----------------------------------
   -- Path_Contains_Traversal_Calls --
   -----------------------------------

   function Path_Contains_Traversal_Calls (Expr : N_Subexpr_Id) return Boolean
   is
   begin
      case Nkind (Expr) is
         when N_Expanded_Name
            | N_Identifier
            | N_Aggregate
            | N_Allocator
            | N_Delta_Aggregate
            | N_Extension_Aggregate
            | N_Null
         =>
            return False;

         when N_Explicit_Dereference
            | N_Indexed_Component
            | N_Selected_Component
            | N_Slice
         =>
            return Path_Contains_Traversal_Calls (Prefix (Expr));

         when N_Function_Call =>
            return Is_Traversal_Function_Call (Expr);

         when N_Qualified_Expression
            | N_Type_Conversion
            | N_Unchecked_Type_Conversion
         =>
            return Path_Contains_Traversal_Calls (Expression (Expr));

         when N_Attribute_Reference =>
            if Attribute_Name (Expr) in Name_Old
                                      | Name_Loop_Entry
                                      | Name_Update
            then
               return False;
            else
               pragma Assert (Attribute_Name (Expr) = Name_Access);
               return Path_Contains_Traversal_Calls (Prefix (Expr));
            end if;

         when others =>
            raise Program_Error;
      end case;
   end Path_Contains_Traversal_Calls;

   ----------------
   -- Real_Image --
   ----------------

   function Real_Image (U : Ureal; Max_Length : Integer) return String is
      Result : String (1 .. Max_Length);
      Last   : Natural := 0;

      procedure Output_Result (S : String);
      --  Callback to print value of U in string Result

      -------------------
      -- Output_Result --
      -------------------

      procedure Output_Result (S : String) is
      begin
         --  Last character is always ASCII.LF which should be ignored
         pragma Assert (S (S'Last) = ASCII.LF);
         Last := Integer'Min (Max_Length, S'Length - 1);
         Result (1 .. Last) := S (S'First .. Last - S'First + 1);
      end Output_Result;

   --  Start of processing for Real_Image

   begin
      Output.Set_Special_Output (Output_Result'Unrestricted_Access);
      UR_Write (U);
      Output.Write_Eol;
      Output.Cancel_Special_Output;
      return Result (1 .. Last);
   end Real_Image;

   -----------------------
   -- Root_Discriminant --
   -----------------------

   function Root_Discriminant (E : E_Discriminant_Id) return Entity_Id is
      Rec_Type : constant Entity_Id := Retysp (Scope (E));
      Root     : constant Entity_Id := Root_Retysp (Rec_Type);

   begin
      --  If Root does not have any discriminants, no match for E can be found
      --  here.

      if not Has_Discriminants (Root) then
         return Empty;

      --  Otherwise, the discriminant cannot have been renamed since it is not
      --  allowed in SPARK. Search for it in Root by name.

      else
         return Search_Component_By_Name (Root, E);
      end if;
   end Root_Discriminant;

   ---------------------
   -- Safe_First_Sloc --
   ---------------------

   function Safe_First_Sloc (N : Node_Id) return Source_Ptr is
     (if Instantiation_Location (Sloc (N)) = No_Location
      then First_Sloc (N)
      else Sloc (First_Node (N)));

   function Safe_Last_Sloc (N : Node_Id) return Source_Ptr is
     (if Instantiation_Location (Sloc (N)) = No_Location
      then Last_Sloc (N)
      else Sloc (Last_Node (N)));

   ------------------------------
   -- Search_Component_By_Name --
   ------------------------------

   function Search_Component_By_Name
     (Rec  : Record_Like_Kind_Id;
      Comp : Record_Field_Kind_Id)
      return Opt_Record_Field_Kind_Id
   is
      Specific_Rec : constant Entity_Id :=
        (if Is_Class_Wide_Type (Rec)
         then Retysp (Get_Specific_Type_From_Classwide (Rec))
         else Rec);

      --  Check that it is safe to call First_Component_Or_Discriminant on
      --  Specific_Rec.

      pragma Assert
        (Is_Concurrent_Type (Specific_Rec)
         or else Is_Incomplete_Or_Private_Type (Specific_Rec)
         or else Is_Record_Type (Specific_Rec)
         or else Has_Discriminants (Specific_Rec));

      Cur_Comp     : Entity_Id :=
        First_Component_Or_Discriminant (Specific_Rec);
   begin
      while Present (Cur_Comp) loop
         if Chars (Cur_Comp) = Chars (Comp) then

            --  We have found a field with the same name. If the type is not
            --  tagged, we have found the correct component. Otherwise, either
            --  it has the same Original_Record_Component and it is the field
            --  we were looking for or it does not and Comp is not in Rec.

            if not Is_Tagged_Type (Rec)
               or else Original_Record_Component (Cur_Comp) =
                 Original_Record_Component (Comp)
            then
               return Cur_Comp;
            else
               return Empty;
            end if;
         end if;

         Next_Component_Or_Discriminant (Cur_Comp);
      end loop;

      return Empty;
   end Search_Component_By_Name;

   -------------------
   -- Shape_Of_Node --
   -------------------

   function Shape_Of_Node (Node : Node_Id) return String is

      function Label_Append
        (Buf : Unbounded_String)
         return Unbounded_String
      is
        (if Buf = Null_Unbounded_String
         then Null_Unbounded_String
         else "__" & Buf);

      Buf     : Unbounded_String := Null_Unbounded_String;
      Node_It : Node_Id := Node;

   --  Start of processing for Shape_Of_Node

   begin
      while Present (Node_It) loop
         case Nkind (Node_It) is

         when N_Subprogram_Body
            | N_Subprogram_Specification
            | N_Expression_Function
            | N_Package_Body
            | N_Package_Specification
            | N_Generic_Subprogram_Declaration
         =>
            exit;

         when N_Loop_Statement =>
            declare
               It_Scheme : constant Node_Id := Iteration_Scheme (Node_It);
            begin
               if Present (It_Scheme) then
                  case Nkind (It_Scheme) is
                  when N_Loop_Parameter_Specification |
                       N_Iterator_Specification       =>
                     --  for
                     Buf := "for" & Label_Append (Buf);
                  when others =>
                     --  while
                     Buf := "while" & Label_Append (Buf);
                  end case;
               else
                  --  loop
                  Buf := "loop" & Label_Append (Buf);
               end if;
            end;

            if Identifier (Node_It) /= Empty then
               Buf := Get_Name_String (Chars (Identifier (Node_It)))
                 & "_" & Buf;
            end if;

         when N_Case_Statement
            | N_Case_Expression
         =>
            Buf := "case" & Label_Append (Buf);

         when N_If_Statement
            | N_If_Expression
         =>
            Buf := "if" & Label_Append (Buf);

         when N_Enumeration_Representation_Clause =>
            Buf := Get_Name_String (Chars (Identifier (Node_It)))
              & "_rep" & Label_Append (Buf);

         when N_At_Clause =>
            Buf := Get_Name_String (Chars (Identifier (Node_It)))
              & "_at" & Label_Append (Buf);

         when N_Record_Representation_Clause =>
            Buf := Get_Name_String (Chars (Identifier (Node_It)))
              & "_" & Buf;

         when N_Component_Clause =>
            Buf := Get_Name_String (Chars (Component_Name (Node_It)))
              & "_rep" & Label_Append (Buf);

         when N_Mod_Clause =>
            Buf := "modrep" & Label_Append (Buf);

         when N_Attribute_Definition_Clause =>
            Buf := Get_Name_String (Chars (Name (Node_It))) & "_"
              & Get_Name_String (Chars (Node_It))
              & "_def" & Label_Append (Buf);

         when N_Pragma_Argument_Association =>
            Buf := "pragargs" & Label_Append (Buf);

         when N_Op_Add =>
            Buf := "add" & Label_Append (Buf);

         when N_Op_Concat =>
            Buf := "concat" & Label_Append (Buf);

         when N_Op_Expon =>
            Buf := "exp" & Label_Append (Buf);

         when N_Op_Subtract =>
            Buf := "sub" & Label_Append (Buf);

         when N_Op_Divide =>
            Buf := "div" & Label_Append (Buf);

         when N_Op_Mod =>
            Buf := "mod" & Label_Append (Buf);

         when N_Op_Multiply =>
            Buf := "mult" & Label_Append (Buf);

         when N_Op_Rem =>
            Buf := "rem" & Label_Append (Buf);

         when N_Op_And =>
            Buf := "and" & Label_Append (Buf);

         when N_Op_Compare =>
            Buf := "cmp" & Label_Append (Buf);

         when N_Op_Or =>
            Buf := "or" & Label_Append (Buf);

         when N_Op_Xor =>
            Buf := "xor" & Label_Append (Buf);

         when N_Op_Rotate_Left =>
            Buf := "rol" & Label_Append (Buf);

         when N_Op_Rotate_Right =>
            Buf := "ror" & Label_Append (Buf);

         when N_Op_Shift_Left =>
            Buf := "lsl" & Label_Append (Buf);

         when N_Op_Shift_Right =>
            Buf := "lsr" & Label_Append (Buf);

         when N_Op_Shift_Right_Arithmetic =>
            Buf := "asr" & Label_Append (Buf);

         when N_Op_Abs =>
            Buf := "abs" & Label_Append (Buf);

         when N_Op_Minus =>
            Buf := "minus" & Label_Append (Buf);

         when N_Op_Not =>
            Buf := "not" & Label_Append (Buf);

         when N_Op_Plus =>
            Buf := "plus" & Label_Append (Buf);

         when N_Attribute_Reference =>
            Buf := Get_Name_String (Attribute_Name (Node_It))
              & "_ref" & Label_Append (Buf);

         when N_Membership_Test =>
            Buf := "in" & Label_Append (Buf);

         when N_And_Then =>
            Buf := "andthen" & Label_Append (Buf);

         when N_Or_Else =>
            Buf := "orelse" & Label_Append (Buf);

         when N_Subprogram_Call =>
            Buf := "call_" &
              Get_Name_String (Chars (Get_Called_Entity (Node_It)))
              & Label_Append (Buf);

         when N_Indexed_Component =>
            Buf := "ixdcomp" & Label_Append (Buf);

         when N_Null =>
            Buf := "null" & Label_Append (Buf);

         when N_Qualified_Expression =>
            Buf := Get_Name_String (Chars (Subtype_Mark (Node_It)))
                                    & "_qual" & Label_Append (Buf);

         when N_Quantified_Expression =>
            Buf := (if All_Present (Node_It) then "forall" else "forsome")
              & Label_Append (Buf);

         when N_Aggregate =>
            Buf := "aggr" & Label_Append (Buf);

         when N_Allocator =>
            Buf := "new_" & Buf;

         when N_Raise_Expression =>
            Buf := "raise" & Label_Append (Buf);

         when N_Range =>
            Buf := "range" & Label_Append (Buf);

         when N_Selected_Component =>
            Buf := "selectcomp" & Label_Append (Buf);

         when N_Slice =>
            Buf := "slice" & Label_Append (Buf);

         when N_Type_Conversion | N_Unchecked_Type_Conversion =>
            Buf := "typeconv" & Label_Append (Buf);

         when N_Subtype_Indication =>
            Buf := Get_Name_String (Chars (Subtype_Mark (Node_It)))
              & "_ind" & Label_Append (Buf);

         when N_Formal_Type_Declaration
            | N_Implicit_Label_Declaration
            | N_Object_Declaration
            | N_Formal_Object_Declaration
         =>
            declare
               I_Name : constant Name_Id := Chars (Defining_Identifier
                                                   (Node_It));
               Name_Str : constant String :=
                 (if I_Name /= No_Name and then I_Name /= Error_Name then
                     Get_Name_String (I_Name) & "_"
                  else "");
            begin
               Buf := Name_Str & "decl" & Label_Append (Buf);
            end;

         when N_Full_Type_Declaration
            | N_Incomplete_Type_Declaration
            | N_Protected_Type_Declaration
            | N_Private_Type_Declaration
            | N_Subtype_Declaration
         =>
            Buf := Get_Name_String (Chars (Defining_Identifier (Node_It)))
              & "_def" & Label_Append (Buf);

         when N_Private_Extension_Declaration =>
            Buf := Get_Name_String (Chars (Defining_Identifier (Node_It)))
              & "_priv" & Label_Append (Buf);

         when N_Body_Stub =>
            Buf := Get_Name_String (Chars (Defining_Identifier (Node_It)))
              & "_stub" & Label_Append (Buf);

         when N_Generic_Instantiation =>
            Buf := Get_Name_String (Chars (Defining_Identifier (Node_It)))
              & "_inst" & Label_Append (Buf);

         when N_Array_Type_Definition =>
            Buf := "arrayof_" & Buf;

         when N_Assignment_Statement =>
            declare
               Obj : constant Entity_Id :=
                 Get_Enclosing_Object (Name (Node_It));
               Obj_Name : Name_Id;

            begin
               Buf := "assign" & Label_Append (Buf);

               if Present (Obj) then
                  Obj_Name := Chars (Obj);

                  if Obj_Name /= No_Name and then Obj_Name /= Error_Name then
                     Buf := Get_Name_String (Obj_Name) & "_" & Buf;
                  end if;
               end if;
            end;

         when N_Block_Statement =>
            declare
               Tmp : constant String := (if Identifier (Node_It) /= Empty
                                         then
                                            Get_Name_String
                                           (Chars (Identifier (Node_It))) & "_"
                                         else "");
            begin
               Buf := Tmp & "declblk" & Label_Append (Buf);
            end;

         when N_Goto_Statement =>
            Buf := "goto_" & Get_Name_String (Chars (Name (Node_It)))
              & Label_Append (Buf);

         when N_Raise_Statement =>
            Buf := "raise" & (if Name (Node_It) /= Empty then
                                 "_" & Get_Name_String
                                (Chars (Name (Node_It)))
                              else "") & Label_Append (Buf);

         when N_Simple_Return_Statement
            | N_Extended_Return_Statement
         =>
            Buf := "return" & Label_Append (Buf);

         when N_Exit_Statement =>
            Buf := "exit" & (if Name (Node_It) /= Empty then
                                "_" & Get_Name_String (Chars (Name (Node_It)))
                             else "")
              & Label_Append (Buf);

         when others =>
            null;

         end case;

         Node_It := Parent (Node_It);
      end loop;

      return To_String (Buf);
   end Shape_Of_Node;

   -----------------
   -- Source_Name --
   -----------------

   function Source_Name (N : Node_Id) return String is
      Buf : Bounded_String;

   begin
      if Nkind (N) in N_Entity and then Is_Single_Concurrent_Type (N) then
         return Source_Name (Anonymous_Object (N));
      else
         Append_Unqualified_Decoded (Buf, Chars (N));
         Adjust_Name_Case (Buf, Sloc (N));

         return To_String (Buf);
      end if;
   end Source_Name;

   -------------------------------
   -- Statement_Enclosing_Label --
   -------------------------------

   function Statement_Enclosing_Label (E : E_Label_Id) return Node_Id is
      Label : constant Node_Id := Label_Construct (Parent (E));
      pragma Assert (Nkind (Label) = N_Label);

   begin
      return Parent (Label);
   end Statement_Enclosing_Label;

   --------------------
   -- String_Of_Node --
   --------------------

   function String_Of_Node (N : N_Subexpr_Id) return String is

      -----------------------
      -- Local Subprograms --
      -----------------------

      function Ident_Image (Expr        : Node_Id;
                            Orig_Expr   : Node_Id;
                            Expand_Type : Boolean)
                            return String
      with Pre => Present (Expr);

      function Real_Image_10 (U : Ureal) return String is
        (Real_Image (U, 10));

      function String_Image (S : String_Id) return String is
        ('"' & Get_Name_String (String_To_Name (S)) & '"');

      function Node_To_String is new
        Expression_Image (Real_Image_10, String_Image, Ident_Image);
      --  The actual printing function

      -----------------
      -- Ident_Image --
      -----------------

      function Ident_Image (Expr        : Node_Id;
                            Orig_Expr   : Node_Id;
                            Expand_Type : Boolean)
                            return String
      is
         pragma Unreferenced (Orig_Expr, Expand_Type);

      begin
         --  For compiler generated identifiers, try to print the original node
         --  instead.

         if not Comes_From_Source (Expr)
           and then Is_Rewrite_Substitution (Expr)
         then
            return Node_To_String (Original_Node (Expr), "");
         end if;

         if Nkind (Expr) = N_Defining_Identifier then
            return Source_Name (Expr);
         elsif Present (Entity (Expr)) then
            return Source_Name (Entity (Expr));
         else
            return Source_Name (Expr);
         end if;
      end Ident_Image;

   --  Start of processing for String_Of_Node

   begin
      return Node_To_String (N, "");
   end String_Of_Node;

   ------------------
   -- String_Value --
   ------------------

   function String_Value (Str_Id : String_Id) return String is
   begin
      String_To_Name_Buffer (Str_Id);

      return Name_Buffer (1 .. Name_Len);
   end String_Value;

   ------------------------------------
   -- Structurally_Decreases_In_Call --
   ------------------------------------

   procedure Structurally_Decreases_In_Call
     (Param       : Formal_Kind_Id;
      Call        : N_Call_Id;
      Result      : out Boolean;
      Explanation : out Unbounded_String)
   is
      Subp        : constant Subprogram_Kind_Id := Get_Called_Entity (Call);
      Variants    : constant Node_Id :=
        Get_Pragma (Subp, Pragma_Subprogram_Variant);
      Aggr        : constant Node_Id :=
        Expression (First (Pragma_Argument_Associations (Variants)));
      Variant     : constant Node_Id :=
        First (Component_Associations (Aggr));
      Call_Formal : constant Formal_Kind_Id := Entity (Expression (Variant));
      Call_Actual : Node_Id := Empty;
      Decreases   : Boolean := False;

      procedure Go_To_Enclosing_Statement
        (Variable  : in out Entity_Id;
         Statement : in out Node_Id;
         Stmt_List : out List_Id;
         Decl_List : out List_Id);
      --  Variable shall be either Param or a local observer/borrower
      --  ultimately borrowing Param which is defined in a scope enclosing
      --  Statement.
      --  Set Statement to the control statement or block enclosing the
      --  initial value of Statement, Stmt_List to the corresponding list of
      --  statements and Decl_List to the list of declarations if any. Set
      --  Variable to the last local observer/borrower ultimately borrowing
      --  Param defined in a scope enclosing Statement if any, and Param
      --  otherwise.

      function Is_Reborrowed_On_All_Path_To_Stmt
        (Variable  : Entity_Id;
         Statement : Node_Id) return Boolean
        with Pre => Is_List_Member (Statement);
      --  Go up the path leading to Statement and check if one of the
      --  borrowers/observers involved in the path to Variable is reborrowed
      --  on all paths leading to Statement.

      function No_Deep_Updates_Up_To_Stmt
        (Variable  : Entity_Id;
         Statement : Node_Id) return Boolean
        with Pre => Is_List_Member (Statement);
      --  Go up the path leading to Statement and check if none of the
      --  borrowers/observers involved in the path to Variable is updated
      --  on any path leading to Statement.

      procedure Search_Param (Formal : Entity_Id; Actual : Node_Id);
      --  If Formal is Call_Formal set Call_Actual to Actual

      -------------------------------
      -- Go_To_Enclosing_Statement --
      -------------------------------

      procedure Go_To_Enclosing_Statement
        (Variable  : in out Entity_Id;
         Statement : in out Node_Id;
         Stmt_List : out List_Id;
         Decl_List : out List_Id)
      is
      begin
         Stmt_List := List_Containing (Statement);
         Decl_List := No_List;

         Statement := Parent (Stmt_List);
         if Nkind (Statement) in N_Handled_Sequence_Of_Statements
                               | N_Case_Statement_Alternative
                               | N_Elsif_Part
         then
            Statement := Parent (Statement);
         end if;
         pragma Assert
           (Is_List_Member (Statement)
            or else Nkind (Statement) in N_Subprogram_Body
                                       | N_Entry_Body);

         --  If Statement is a body or a block, set Decl_List appropriately.
         --  Because of inlining, it can also occur that the input value
         --  of Statement was in fact in the declarations. Also reset
         --  Stmt_List.

         if Nkind (Statement) in N_Block_Statement
                               | N_Subprogram_Body
                               | N_Entry_Body
         then
            Stmt_List := Statements (Handled_Statement_Sequence (Statement));
            Decl_List := Declarations (Statement);
         end if;

         --  If we are in the block statement where Variable is defined, go up
         --  the chain of borrowers to find one which is not defined in the
         --  current block.

         if Nkind (Statement) = N_Block_Statement
           and then Defining_Entity (Statement) = Scope (Variable)
         then
            loop
               Variable := Get_Root_Object
                 (Expression (Parent (Variable)));
               exit when Variable = Param
                 or else Defining_Entity (Statement) /= Scope (Variable);
            end loop;

         --  If we have reached the enclosing body, Variable is set to Param

         elsif Nkind (Statement) in N_Subprogram_Body | N_Entry_Body then
            Variable := Param;
         end if;
      end Go_To_Enclosing_Statement;

      ---------------------------------------
      -- Is_Reborrowed_On_All_Path_To_Stmt --
      ---------------------------------------

      function Is_Reborrowed_On_All_Path_To_Stmt
        (Variable  : Entity_Id;
         Statement : Node_Id) return Boolean
      is
         Var  : Entity_Id := Variable;
         Stmt : Node_Id := Statement;
      begin
         loop

            --  If we have reached Param without decreasing, stop the
            --  search. We do not search for assignments to substructures
            --  for Param. It is unlikely to occur in practice as it
            --  would result in a resource leak.

            if Var = Param then
               Explanation := To_Unbounded_String
                 ("structural variant of """ & Source_Name (Subp)
                  & """ might not be a strict subcomponent of """
                  & Source_Name (Param) & '"');
               return False;
            end if;

            pragma Assert (Is_Anonymous_Access_Type (Etype (Var)));

            --  Go to the enclosing control statement if any

            declare
               Brower    : constant Entity_Id := Var;
               End_Stmt  : constant Node_Id := Stmt;
               Stmt_List : List_Id;
               Decl_List : List_Id;
               Dummy     : Unbounded_String;
            begin
               Go_To_Enclosing_Statement
                 (Variable  => Var,
                  Statement => Stmt,
                  Stmt_List => Stmt_List,
                  Decl_List => Decl_List);

               --  If the borrower or observer Brower is reborrowed on all
               --  paths in this statement, the search is over.

               exit when Is_Reborrowed_On_All_Paths
                 (Stmts       => Stmt_List,
                  Decls       => Decl_List,
                  Brower      => Brower,
                  Explanation => Dummy,
                  End_Stmt    => End_Stmt);
            end;
         end loop;

         return True;
      end Is_Reborrowed_On_All_Path_To_Stmt;

      --------------------------------
      -- No_Deep_Updates_Up_To_Stmt --
      --------------------------------

      function No_Deep_Updates_Up_To_Stmt
        (Variable  : Entity_Id;
         Statement : Node_Id) return Boolean
      is
         Search_Is_Over : exception;
         Search_Result  : Boolean;

         procedure No_Deep_Updates_Up_To_Stmt_Rec
           (Variable  : Entity_Id;
            Statement : Node_Id);
         --  Set Search_Result to true if no deep updates of Variable and what
         --  it ultimately borrows/observes were found on the path up to
         --  Statement, otherwise set it to False.
         --  Raise Search_Is_Over if either a deep update was found or
         --  Statement occurs inside a loop so every nested statement in
         --  Statement has already been checked for updates.

         ------------------------------------
         -- No_Deep_Updates_Up_To_Stmt_Rec --
         ------------------------------------

         procedure No_Deep_Updates_Up_To_Stmt_Rec
           (Variable  : Entity_Id;
            Statement : Node_Id)
         is
            Next_Stmt : Node_Id := Statement;
            Next_Var  : Entity_Id := Variable;
            Stmt_List : List_Id;
            Decl_List : List_Id;

         begin
            --  Search for the enclosing control statement or body

            Go_To_Enclosing_Statement
              (Variable  => Next_Var,
               Statement => Next_Stmt,
               Stmt_List => Stmt_List,
               Decl_List => Decl_List);

            --  Check first the enclosing statements up to the enclosing
            --  control statement if any, so that the current statements will
            --  be skipped if they are part of a loop.

            if Nkind (Next_Stmt) not in N_Subprogram_Body | N_Entry_Body then
               No_Deep_Updates_Up_To_Stmt_Rec (Next_Var, Next_Stmt);
            end if;

            --  Search for updates to Next_Var in Stmt_List. If Next_Stmt is a
            --  loop, the recursive call could be encountered several times. As
            --  Param is not constant, it is a deep update.

            if Nkind (Next_Stmt) = N_Loop_Statement then
               pragma Assert (not Is_Constant_In_SPARK (Param));

               Explanation := To_Unbounded_String
                 ('"' & Source_Name (Param) & """ might be updated in previous"
                  & " iterations of the loop");

               Search_Result := False;
               raise Search_Is_Over;

            --  Otherwise, stop the search before Statement

            else
               Search_Result := No_Deep_Updates
                 (Stmts       => Stmt_List,
                  Decls       => Decl_List,
                  Variable    => Next_Var,
                  Explanation => Explanation,
                  End_Stmt    => Statement);

               if not Search_Result then
                  raise Search_Is_Over;
               end if;
            end if;
         end No_Deep_Updates_Up_To_Stmt_Rec;
      begin
         No_Deep_Updates_Up_To_Stmt_Rec (Variable, Statement);
         raise Search_Is_Over;
      exception
         when Search_Is_Over =>
            return Search_Result;
            pragma Annotate
              (CodePeer, False_Positive, "validity check",
               "Search_Result is initialized before raising Search_Is_Over");
      end No_Deep_Updates_Up_To_Stmt;

      ------------------
      -- Search_Param --
      ------------------

      procedure Search_Param (Formal : Entity_Id; Actual : Node_Id) is
      begin
         if Formal = Call_Formal then
            Call_Actual := Actual;
         end if;
      end Search_Param;

      procedure Search_Call_Actual is new
        Iterate_Call_Parameters (Search_Param);

   --  Start of processing for Structurally_Decreases_In_Call

   begin
      --  Search for the actual of Call corresponding to the variant of Subp

      Search_Call_Actual (Call);
      pragma Assert (Present (Call_Actual));

      --  Check that Call_Actual is rooted at Param. Set Decreases to True
      --  if the fact that Call_Actual is a strict subpath of Param can be
      --  deduced from the encountered declarations only.

      declare
         Root : Entity_Id;
         Expr : Node_Id := Call_Actual;
      begin
         loop
            --  If Expr is not a Path or does not have a root object, it is
            --  not a part of Param.

            if not Is_Path_Expression (Expr) then
               Result := False;
               exit;
            end if;

            Root := Get_Root_Object (Expr);

            if No (Root) then
               Result := False;
               exit;
            end if;

            --  If Expr is a strict subpath, we know that the variant
            --  decreases.

            if not Decreases then
               Decreases := Is_Strict_Subpath (Expr);
            end if;

            --  We have reached Param, stop the search

            if Root = Param then
               Result := True;
               exit;

            --  The root is a local observer or borrower, continue the searched
            --  in the borrowed expression.

            elsif Ekind (Root) in E_Variable | E_Constant
              and then Is_Anonymous_Access_Object_Type (Etype (Root))
            then
               Expr := Expression (Parent (Root));

            --  Otherwise, Expr is not a part of Param

            else
               Result := False;
               exit;
            end if;
         end loop;
      end;

      if not Result then
         Explanation := To_Unbounded_String
           ("structural variant of """ & Source_Name (Subp)
            & """ might not be a part of """ & Source_Name (Param) & '"');
         return;
      end if;

      declare
         function Is_In_Statement_List_Or_Post (N : Node_Id) return Boolean;
         --  Return True if N occurs in a list of statements or in a pragma
         --  postcondition.

         --------------------------
         -- Is_In_Statement_List --
         --------------------------

         function Is_In_Statement_List_Or_Post (N : Node_Id) return Boolean is
         begin
            return
              (Nkind (N) = N_Pragma
               and then
                 Get_Pragma_Id (Pragma_Name (N)) in Pragma_Postcondition
                                                  | Pragma_Post_Class
                                                  | Pragma_Contract_Cases
                                                  | Pragma_Refined_Post)
              or else
                (Is_List_Member (N)
                 and then Nkind (Parent (N))
                    in N_Case_Statement_Alternative
                     | N_Elsif_Part
                     | N_If_Statement
                     | N_Handled_Sequence_Of_Statements
                     | N_Block_Statement
                     | N_Subprogram_Body
                     | N_Entry_Body
                     | N_Loop_Statement
                     | N_Extended_Return_Statement);
         end Is_In_Statement_List_Or_Post;

         function First_Parent_In_Statement_List_Or_Post is new
           First_Parent_With_Property (Is_In_Statement_List_Or_Post);

         Variable  : constant Entity_Id := Get_Root_Object (Call_Actual);
         Statement : constant Node_Id :=
           (if Nkind (Call) = N_Function_Call
            then First_Parent_In_Statement_List_Or_Post (Call)
            else Call);

      begin
         --  Result is set to True if the variant at call site is a strict
         --  subcomponent of the caller's variant and the caller's variant
         --  is not modified in a deep way along the way.

         --  If we are in a post condition, we must consider the whole body of
         --  the caller.

         if Nkind (Statement) = N_Pragma
           and then Get_Pragma_Id (Pragma_Name (Statement)) in
                Pragma_Postcondition
              | Pragma_Post_Class
              | Pragma_Contract_Cases
              | Pragma_Refined_Post
         then
            pragma Assert (Variable = Param);

            --  Expr is necessarily rooted at Param itself. We do not
            --  consider the case of reborrowed parameters as they are unlikely
            --  (as is done in Is_Reborrowed_On_All_Path_To_Stmt).

            if not Decreases then
               Explanation := To_Unbounded_String
                 ("structural variant of """ & Source_Name (Subp)
                  & """ might not be a strict subcomponent of """
                  & Source_Name (Param) & '"');
               Result := False;

            elsif Is_Constant_In_SPARK (Param)
              or else not Is_Deep (Etype (Param))
            then
               Result := True;

            --  We check that the parameter is not updated in a deep way by
            --  the subprogram.

            else
               declare
                  Caller : constant Entity_Id := Scope (Param);
                  pragma Assert
                    (not Is_Expression_Function_Or_Completion (Caller)
                     and then Entity_Body_In_SPARK (Caller));

                  Body_N : constant Node_Id := Get_Body (Caller);
                  Stmts  : constant List_Id :=
                    Statements (Handled_Statement_Sequence (Body_N));
                  Decls  : constant List_Id := Declarations (Body_N);
               begin
                  Result := No_Deep_Updates
                      (Stmts       => Stmts,
                       Variable    => Variable,
                       Explanation => Explanation,
                       Decls       => Decls);
               end;
            end if;

         --  Otherwise, we only consider the paths leading to the statement
         --  enclosing the call.

         else
            Result :=
              (Decreases
               or else Is_Reborrowed_On_All_Path_To_Stmt (Variable, Statement))
              and then
                (Is_Constant_In_SPARK (Param)
                 or else not Is_Deep (Etype (Param))
                 or else No_Deep_Updates_Up_To_Stmt (Variable, Statement));
         end if;
      end;
   end Structurally_Decreases_In_Call;

   ------------------------------------
   -- Structurally_Decreases_In_Loop --
   ------------------------------------

   procedure Structurally_Decreases_In_Loop
     (Brower      : Entity_Id;
      Loop_Stmt   : N_Loop_Statement_Id;
      Result      : out Boolean;
      Explanation : out Unbounded_String)
   is

   --  Start of processing for Structurally_Decreases

   begin
      Result := Is_Reborrowed_On_All_Paths
        (Statements (Loop_Stmt), Brower, Explanation)
        and then No_Deep_Updates (Statements (Loop_Stmt), Brower, Explanation);
   exception
      when Goto_Found =>
         Explanation := To_Unbounded_String
           ("a goto statement was found in the loop");
         Result := False;
   end Structurally_Decreases_In_Loop;

   ---------------------------------
   -- Traverse_Access_To_Constant --
   ---------------------------------

   function Traverse_Access_To_Constant (Expr : N_Subexpr_Id) return Boolean is
   begin
      case Nkind (Expr) is

         --  We have reached the root of the path, return False

         when N_Expanded_Name
            | N_Identifier
            | N_Aggregate
            | N_Allocator
            | N_Delta_Aggregate
            | N_Extension_Aggregate
            | N_Null
         =>
            return False;

         --  In the case of a call to a traversal function, the root object is
         --  the root of the traversed parameter. Otherwise there is no root
         --  object.

         when N_Function_Call =>
            if Is_Traversal_Function_Call (Expr)
              and then Is_Path_Expression (First_Actual (Expr))
            then
               return Traverse_Access_To_Constant (First_Actual (Expr));
            else
               return False;
            end if;

         when N_Attribute_Reference =>
            if Attribute_Name (Expr) in Name_First
                                      | Name_Last
                                      | Name_Length
                                      | Name_Access
            then
               return Traverse_Access_To_Constant (Prefix (Expr));

            --  We have reached the root of the path, return False

            else
               pragma Assert
                 (Attribute_Name (Expr) in Name_Loop_Entry
                                         | Name_Old
                                         | Name_Update);
               return False;
            end if;

         when N_Explicit_Dereference =>
            return Is_Access_Type (Retysp (Etype (Prefix (Expr))))
              and then ((Is_Access_Constant (Retysp (Etype (Prefix (Expr))))
                         and then not Is_Anonymous_Access_Type
                           (Etype (Prefix (Expr))))
                        or else Traverse_Access_To_Constant (Prefix (Expr)));

         when N_Indexed_Component
            | N_Selected_Component
            | N_Slice
         =>
            return Traverse_Access_To_Constant (Prefix (Expr));

         when N_Qualified_Expression
            | N_Type_Conversion
            | N_Unchecked_Type_Conversion
         =>
            return Traverse_Access_To_Constant (Expression (Expr));

         when N_Op_Eq
            | N_Op_Ne
         =>
            pragma Annotate
              (Xcov, Exempt_On,
               "The routine is only called on deep paths or objects");
            if Nkind (Left_Opnd (Expr)) = N_Null then
               return Traverse_Access_To_Constant (Right_Opnd (Expr));
            else
               pragma Assert (Nkind (Right_Opnd (Expr)) = N_Null);
               return Traverse_Access_To_Constant (Left_Opnd (Expr));
            end if;
            pragma Annotate (Xcov, Exempt_Off);

         when others =>
            raise Program_Error;
      end case;
   end Traverse_Access_To_Constant;

   -----------------------------
   -- Unique_Main_Unit_Entity --
   -----------------------------

   function Unique_Main_Unit_Entity return Entity_Id is
   begin
      --  Main_Unit_Entity is not reliable, e.g. for instance-as-a-unit its
      --  Ekind is E_Void; Cunit_Entity (Main_Unit) is more reliable, but
      --  might point to the body entity, so Unique_Entity is required.

      return Unique_Entity (Cunit_Entity (Main_Unit));
   end Unique_Main_Unit_Entity;

   ----------------------
   -- Unique_Component --
   ----------------------

   function Unique_Component
     (E : Record_Field_Kind_Id)
      return Record_Field_Kind_Id
   is
   begin
      if Ekind (E) = E_Discriminant
        and then Present (Corresponding_Discriminant (E))
      then
         return Unique_Component (Corresponding_Discriminant (E));
      elsif Present (Corresponding_Record_Component (E)) then
         return Unique_Component (Corresponding_Record_Component (E));
      else
         return Original_Record_Component (E);
      end if;
   end Unique_Component;

   ------------------------
   -- States_And_Objects --
   ------------------------

   function States_And_Objects (E : E_Package_Id) return Node_Sets.Set is
      procedure Register_Object (Obj : Entity_Id)
        with Pre => Ekind (Obj) in E_Constant | E_Variable;
      --  Register Obj as either a ghost or an ordinary variable

      procedure Traverse_Declarations (L : List_Id);

      Results : Node_Sets.Set;

      ---------------------
      -- Register_Object --
      ---------------------

      procedure Register_Object (Obj : Entity_Id) is
      begin
         if Comes_From_Source (Obj)
           and then No (Ultimate_Overlaid_Entity (Obj))
         then
            Results.Insert (Obj);
         end if;
      end Register_Object;

      ---------------------------
      -- Traverse_Declarations --
      ---------------------------

      procedure Traverse_Declarations (L : List_Id) is
         N : Node_Id := First (L);
      begin
         while Present (N) loop
            case Nkind (N) is
               when N_Object_Declaration =>
                  declare
                     Obj : constant Entity_Id := Defining_Entity (N);

                  begin
                     if Ekind (Obj) = E_Variable then
                        Register_Object (Obj);

                     else pragma Assert (Ekind (Obj) = E_Constant);

                        if In_Generic_Actual (Obj) then
                           null;

                        elsif Is_Access_Variable (Etype (Obj))
                          or else Has_Variable_Input (Obj)
                        then
                           if Present (Expression (N)) then
                              --  Completion of a deferred constant

                              if Is_Full_View (Obj) then
                                 null;

                              --  Ordinary constant with an initialization
                              --  expression.

                              else
                                 Register_Object (Obj);
                              end if;

                           else
                              --  Declaration of a deferred constant

                              if Present (Full_View (Obj)) then
                                 Register_Object (Full_View (Obj));

                              --  Imported constant

                              else
                                 pragma Assert (Is_Imported (Obj));
                                 Register_Object (Obj);
                              end if;
                           end if;
                        end if;
                     end if;
                  end;
               when N_Package_Declaration =>
                  declare
                     Nested : constant Entity_Id := Defining_Entity (N);
                  begin
                     if not Is_Wrapper_Package (Nested) then
                        Results.Union (States_And_Objects (Nested));
                     end if;
                  end;

               when others =>
                  null;
            end case;

            Next (N);
         end loop;
      end Traverse_Declarations;

      --  Local variables

      Pkg_Spec : constant Node_Id := Package_Specification (E);

   --  Start of processing for States_And_Objects

   begin
      --  Pick objects from visible declarations (always), then abstract
      --  states (if given explicitly) or objects in private/body parts,
      --  which are lifted to implicit abstract states (if no abstract
      --  states are given); however, respect the SPARK_Mode barrier.
      --
      --  Note: objects declared behind a SPARK_Mode => Off barrier might
      --  still leak into flow analysis if they come from the frontend-cross
      --  references, but then users should properly annotate their package.

      Traverse_Declarations (Visible_Declarations (Pkg_Spec));

      if Present (Get_Pragma (E, Pragma_Abstract_State)) then
         if Has_Non_Null_Abstract_State (E) then
            for State of Iter (Abstract_States (E)) loop
               Results.Insert (State);
            end loop;
         end if;
      elsif Private_Spec_In_SPARK (E) then
         Traverse_Declarations (Private_Declarations (Pkg_Spec));

         if Entity_Body_In_SPARK (E) then
            Traverse_Declarations (Declarations (Package_Body (E)));
         end if;
      end if;

      return Results;
   end States_And_Objects;

end SPARK_Util;
