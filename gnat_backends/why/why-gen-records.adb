------------------------------------------------------------------------------
--                                                                          --
--                            GNAT2WHY COMPONENTS                           --
--                                                                          --
--                      W H Y - G E N - R E C O R D S                       --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--                       Copyright (C) 2010-2012, AdaCore                   --
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

with Ada.Containers.Hashed_Maps;

with Atree;              use Atree;
with Einfo;              use Einfo;
with Elists;             use Elists;
with Nlists;             use Nlists;
with Sem_Aux;            use Sem_Aux;
with Sem_Eval;           use Sem_Eval;
with Sem_Util;           use Sem_Util;
with Sinfo;              use Sinfo;

with Alfa.Util;          use Alfa.Util;
with VC_Kinds;           use VC_Kinds;

with Gnat2Why.Expr;      use Gnat2Why.Expr;
with Gnat2Why.Nodes;     use Gnat2Why.Nodes;
with Gnat2Why.Types;     use Gnat2Why.Types;
with Gnat2Why.Util;      use Gnat2Why.Util;

with Why.Atree.Builders; use Why.Atree.Builders;
with Why.Conversions;    use Why.Conversions;
with Why.Gen.Binders;    use Why.Gen.Binders;
with Why.Gen.Decl;       use Why.Gen.Decl;
with Why.Gen.Expr;       use Why.Gen.Expr;
with Why.Gen.Names;      use Why.Gen.Names;
with Why.Gen.Preds;      use Why.Gen.Preds;
with Why.Gen.Progs;      use Why.Gen.Progs;
with Why.Gen.Terms;      use Why.Gen.Terms;
with Why.Types;          use Why.Types;

package body Why.Gen.Records is

   --  For all Ada record types, we define a Why3 record type which contains
   --  all components of the Ada type, including discriminants, and including
   --  components in variant parts.

   --  For all such components, we then declare access program functions, where
   --  the precondition represents the discriminant check, and the
   --  postcondition states that the value of this function is just the value
   --  of the record component.

   --  For all record types which are not root types, we also define conversion
   --  functions to the root type (in logic space) and from the root type (in
   --  logic and program space). The 'from' function in program space has a
   --  precondition which expresses the discriminant check.

   --  For the implementation details: This is one place where we have to look
   --  at the declaration node to find which discriminant values imply the
   --  presence of which components. We traverse the N_Component_List of the
   --  type declaration, and for each component, and for each N_Variant_Part,
   --  we store a record of type [Component_Info] which contains the N_Variant
   --  node to which the component/variant part belongs, and the N_Variant_Part
   --  to which this N_Variant node belongs. In this way, we can easily access
   --  the discriminant (the Name of the N_Variant_Part) and the discrete
   --  choice (the Discrete_Choices of the N_Variant) of that component or
   --  variant part. For variant parts, the field [Ident] is empty, for
   --  components it contains the corresponding Why identifier.

   --  The map [Comp_Info] maps the component entities and N_Variant_Part nodes
   --  to their information record. This map is populated at the beginning of
   --  [Declare_Ada_Record].

   --  We ignore "completely hidden" components of derived record types (see
   --  also the discussion in einfo.ads and sem_ch3.adb)

   type Component_Info is record
      Parent_Variant  : Node_Id;
      Parent_Var_Part : Node_Id;
      Ident           : W_Identifier_Id;
   end record;

   package Info_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => Node_Id,
      Element_Type    => Component_Info,
      Hash            => Node_Hash,
      Equivalent_Keys => "=",
      "="             => "=");

   function Needs_Discriminant_Check_For_Access (E : Entity_Id) return Boolean;
   --  Decide whether the an access to the given Component entity needs a
   --  check; this is always false for discriminants and components of
   --  E_Record_Subtypes. For the rest, it depends on whether the component is
   --  in a variant part or not.

   function Is_Not_Hidden_Discriminant (E : Entity_Id) return Boolean is
     (not (Ekind (E) = E_Discriminant and then Is_Completely_Hidden (E)));
   --  Opposite of Einfo.Is_Completely_Hidden, which also returns True if E is
   --  not a discriminant.

   -----------------------
   -- Define_Ada_Record --
   -----------------------

   procedure Declare_Ada_Record
     (P       : in out Why_File;
      Theory  : W_Theory_Declaration_Id;
      E       : Entity_Id)
   is

      function Count_Why_Record_Fields (E : Entity_Id) return Natural;
      --  count the number of fields

      procedure Declare_Record_Type;
      --  declare the record type

      procedure Declare_Protected_Access_Functions;
      --  for each record field, declare an access program function, whose
      --  result is the same as the record field access, but there is a
      --  precondition (when needed)

      function Compute_Discriminant_Check (Field : Entity_Id)
                                           return W_Pred_Id;
      --  compute the discriminant check for an access to the given field, as a
      --  predicate which can be used as a precondition

      function Compute_Down_Cast_Check (E : Entity_Id; Pred : out W_Pred_Id)
                                        return Binder_Array;
      --  compute the precondition for the cast from the base type to the
      --  current entity. The values of the discriminants may depend on dynamic
      --  expressions that cannot be used at the place where

      function Compute_Others_Choice (Info  : Component_Info;
                                      Discr : W_Term_Id) return W_Pred_Id;
      --  compute (part of) the discriminant check for one discriminant in the
      --  special case where the N_Discrete_Choice is actually an
      --  N_Others_Choice

      function Is_Others_Choice (N : Node_Id) return Boolean;
      --  Check whether the N_Variant is actually an N_Others_Choice

      procedure Declare_Conversion_Functions;
      --  Generate conversion functions from this type to the root type, and
      --  back.

      procedure Declare_Equality_Function;
      --  Generate the boolean equality function for the record type

      function Transform_Discrete_Choices (Case_N : Node_Id;
                                           Expr   : W_Term_Id)
                                           return W_Pred_Id;
      --  Wrapper for the function in Gnat2Why.Expr;

      procedure Init_Component_Info;
      --  Initialize the map which maps each component to its information
      --  record

      Ty_Ident   : constant W_Identifier_Id := To_Ident (WNE_Type);
      Abstr_Ty   : constant W_Primitive_Type_Id :=
        New_Abstract_Type (Name => Ty_Ident);
      Comp_Info  : Info_Maps.Map := Info_Maps.Empty_Map;
      --  This map maps each component and each N_Variant node to a
      --  Component_Info record. This map is initialized by a call to
      --  Init_Component_Info;

      A_Ident    : constant W_Identifier_Id := New_Identifier (Name => "a");
      R_Binder   : constant Binder_Array :=
        (1 => (B_Name => A_Ident,
               B_Type => Abstr_Ty,
               others => <>));

      --------------------------------
      -- Compute_Discriminant_Check --
      --------------------------------

      function Compute_Discriminant_Check (Field : Entity_Id)
                                           return W_Pred_Id
      is
         Info : Component_Info := Comp_Info.Element (Field);
         Cond : W_Pred_Id := True_Pred;
      begin
         while Present (Info.Parent_Variant) loop
            declare
               Ada_Discr : constant Node_Id :=
                 Entity (Name (Info.Parent_Var_Part));
               Discr : constant W_Term_Id :=
                 +Insert_Conversion
                   (Domain => EW_Term,
                    Expr =>
                      New_Record_Access
                        (Name  => +A_Ident,
                         Field => To_Why_Id (Ada_Discr, Local => True)),
                    To   => EW_Int_Type,
                    From => EW_Abstract (Etype (Ada_Discr)));
               New_Cond : constant W_Pred_Id :=
                 (if Is_Others_Choice (Info.Parent_Variant) then
                  Compute_Others_Choice (Info, Discr)
                  else
                  +Transform_Discrete_Choices
                    (Info.Parent_Variant, Discr));
            begin
               Cond :=
                 +New_And_Then_Expr
                 (Domain => EW_Pred,
                  Left   => +Cond,
                  Right  => +New_Cond);
               Info := Comp_Info.Element (Info.Parent_Var_Part);
            end;
         end loop;
         return Cond;
      end Compute_Discriminant_Check;

      -----------------------------
      -- Compute_Down_Cast_Check --
      -----------------------------

      function Compute_Down_Cast_Check (E : Entity_Id; Pred : out W_Pred_Id)
                                        return Binder_Array
      is
         Discr       : Entity_Id;
         Constr_Elmt : Elmt_Id;
      begin
         Pred := True_Pred;
         if not Has_Discriminants (E) then
            return (1 .. 0 => <>);
         end if;
         declare
            Discr_Binders   : Binder_Array
              (1 .. Natural (Number_Discriminants (E)));
            Dyn_Discr_Count : Natural := 0;
         begin
            Discr := First_Discriminant (E);
            Constr_Elmt := First_Elmt (Stored_Constraint (E));
            while Present (Discr) loop
               if Is_Not_Hidden_Discriminant (Discr) then
                  declare
                     Discr_Val : W_Expr_Id;
                     Discr_Exp : W_Expr_Id;
                  begin
                     Discr_Exp :=
                       New_Record_Access
                         (Name  => +A_Ident,
                          Field =>
                            To_Why_Id
                              (Root_Record_Component (Discr)));
                     if Is_Static_Expression (Node (Constr_Elmt)) then
                        Discr_Val :=
                          New_Integer_Constant
                            (Value => Expr_Value (Node (Constr_Elmt)));
                        Discr_Exp :=
                          +Insert_Conversion
                          (Domain => EW_Term,
                           Expr   => Discr_Exp,
                           To     => EW_Int_Type,
                           From   => EW_Abstract (Etype (Discr)));
                     else
                        declare
                           Discr_Ident : constant W_Identifier_Id :=
                             New_Temp_Identifier;
                        begin
                           Dyn_Discr_Count := Dyn_Discr_Count + 1;
                           Discr_Binders (Dyn_Discr_Count) :=
                             (B_Name => Discr_Ident,
                              B_Type =>
                                Why_Logic_Type_Of_Ada_Type (Etype (Discr)),
                              others => <>);
                           Discr_Val := +Discr_Ident;
                        end;
                     end if;
                     Pred :=
                       +New_And_Then_Expr
                       (Domain => EW_Pred,
                        Left   => +Pred,
                        Right  =>
                          New_Relation
                            (Domain  => EW_Pred,
                             Op_Type => EW_Abstract,
                             Op      => EW_Eq,
                             Left    => +Discr_Exp,
                             Right   => +Discr_Val));
                  end;
               end if;
               Next_Discriminant (Discr);
               Next_Elmt (Constr_Elmt);
            end loop;
            return Discr_Binders (1 .. Dyn_Discr_Count);
         end;
      end Compute_Down_Cast_Check;

      ---------------------------
      -- Compute_Others_Choice --
      ---------------------------

      function Compute_Others_Choice (Info  : Component_Info;
                                      Discr : W_Term_Id) return W_Pred_Id
      is
         Var_Part : constant Node_Id := Info.Parent_Var_Part;
         Var      : Node_Id := First (Variants (Var_Part));
         Cond     : W_Pred_Id := True_Pred;
      begin
         while Present (Var) loop
            if not Is_Others_Choice (Var) then
               Cond :=
                 +New_And_Then_Expr
                   (Domain => EW_Pred,
                    Left   => +Cond,
                    Right  =>
                      New_Not
                        (Domain => EW_Pred,
                         Right  =>
                           +Transform_Discrete_Choices (Var, Discr)));
            end if;
            Next (Var);
         end loop;
         return Cond;
      end Compute_Others_Choice;

      -----------------------------
      -- Count_Why_Record_Fields --
      -----------------------------

      function Count_Why_Record_Fields (E : Entity_Id) return Natural
      is
         Cnt : Natural := 0;
         Field : Node_Id := First_Component_Or_Discriminant (E);
      begin
         while Present (Field) loop
            if Is_Not_Hidden_Discriminant (Field) then
               Cnt := Cnt + 1;
            end if;
            Next_Component_Or_Discriminant (Field);
         end loop;
         return Cnt;
      end Count_Why_Record_Fields;

      ----------------------------------
      -- Declare_Conversion_Functions --
      ----------------------------------

      procedure Declare_Conversion_Functions
      is
         Root            : constant Entity_Id :=
           Unique_Entity (Root_Record_Type (E));
         Num_E_Fields    : constant Natural := Count_Why_Record_Fields (E);
         Num_Root_Fields : constant Natural := Count_Why_Record_Fields (Root);
         To_Root_Aggr    : W_Field_Association_Array (1 .. Num_Root_Fields);
         From_Root_Aggr  : W_Field_Association_Array (1 .. Num_E_Fields);
         Field           : Entity_Id;
         Seen            : Node_Sets.Set := Node_Sets.Empty_Set;
         Index           : Natural := 1;
         From_Binder     : constant Binder_Array :=
           (1 => (B_Name => A_Ident,
                  B_Type => Why_Logic_Type_Of_Ada_Type (Root),
                  others => <>));
         From_Ident     : constant W_Identifier_Id := To_Ident (WNE_Of_Base);

      begin
         pragma Assert (Num_E_Fields <= Num_Root_Fields);

         --  First iterate over the the components of the subtype; this allows
         --  to fill in the 'from' aggregate and part of the 'to' aggregate. We
         --  store in 'Seen' the components of the base type which are already
         --  filled in.

         Field := First_Component_Or_Discriminant (E);
         while Present (Field) loop
            if Is_Not_Hidden_Discriminant (Field) then
               declare
                  Orig     : constant Entity_Id :=
                    Root_Record_Component (Field);
                  Orig_Id  : constant W_Identifier_Id := To_Why_Id (Orig);
                  Field_Id : constant W_Identifier_Id :=
                    To_Why_Id (Field, Local => True);
               begin
                  From_Root_Aggr (Index) :=
                    New_Field_Association
                      (Domain => EW_Term,
                       Field  => Field_Id,
                       Value  =>
                         Insert_Conversion
                           (Domain => EW_Term,
                            To     => EW_Abstract (Etype (Field)),
                            From   => EW_Abstract (Etype (Orig)),
                            Expr   =>
                              New_Record_Access
                                (Name => +A_Ident,
                                 Field => Orig_Id)));
                  To_Root_Aggr (Index) :=
                    New_Field_Association
                      (Domain => EW_Term,
                       Field  => Orig_Id,
                       Value  =>
                         Insert_Conversion
                           (Domain => EW_Term,
                            To     => EW_Abstract (Etype (Orig)),
                            From   => EW_Abstract (Etype (Field)),
                            Expr   =>
                              New_Record_Access
                                (Name  => +A_Ident,
                                 Field => Field_Id)));
                  Seen.Include (Orig);
                  Index := Index + 1;
               end;
            end if;
            Next_Component_Or_Discriminant (Field);
         end loop;

         --  We now iterate over the components of the root type, to fill in
         --  the missing part of the 'to' aggregate. As the subtype cannot
         --  provide a value for these fields, we use the dummy value of the
         --  corresponding type. We use the 'Seen' set to filter the components
         --  that have been added already.

         --  ??? For renamed discriminants, we should reuse the value of the
         --  renaming

         Field := First_Component_Or_Discriminant (Root);
         while Present (Field) loop
            if not (Seen.Contains (Field)) then
               To_Root_Aggr (Index) :=
                 New_Field_Association
                   (Domain => EW_Term,
                    Field  => To_Why_Id (Field),
                    Value  =>
                      Why_Default_Value (Domain => EW_Term,
                                         E      => Etype (Field)));
               Index := Index + 1;
            end if;
            Next_Component_Or_Discriminant (Field);
         end loop;

         Emit
           (Theory,
            New_Function_Def
              (Domain      => EW_Term,
               Name        => To_Ident (WNE_To_Base),
               Binders     => R_Binder,
               Return_Type =>
                 Why_Logic_Type_Of_Ada_Type (Root),
               Def         =>
                 New_Record_Aggregate
                   (Associations => To_Root_Aggr)));
         Emit
           (Theory,
            New_Function_Def
              (Domain      => EW_Term,
               Name        => From_Ident,
               Binders     => From_Binder,
               Return_Type => Abstr_Ty,
               Def         =>
                 New_Record_Aggregate
                   (Associations => From_Root_Aggr)));
         declare
            Down_Cast : W_Pred_Id;
            Add_Args  : constant Binder_Array :=
              Compute_Down_Cast_Check (E, Down_Cast);
         begin
            Emit
              (Theory,
               New_Function_Decl
                 (Domain      => EW_Prog,
                  Name        => To_Program_Space (From_Ident),
                  Binders     => From_Binder & Add_Args,
                  Return_Type => Abstr_Ty,
                  Post        =>
                    New_Relation
                      (Op_Type => EW_Abstract,
                       Left    => +To_Ident (WNE_Result),
                       Op      => EW_Eq,
                       Right   =>
                         New_Call
                           (Domain => EW_Term,
                            Name   => From_Ident,
                            Args   => (1 => +A_Ident))),
                  Pre         => Down_Cast));
         end;

      end Declare_Conversion_Functions;

      -------------------------------
      -- Declare_Equality_Function --
      -------------------------------

      procedure Declare_Equality_Function
      is
         B_Ident   : constant W_Identifier_Id := New_Identifier (Name => "b");
         Condition : W_Pred_Id := True_Pred;
         Comp      : Entity_Id := First_Component_Or_Discriminant (E);
      begin
         while Present (Comp) loop
            if Is_Not_Hidden_Discriminant (Comp) then
               declare
                  Comparison : constant W_Pred_Id :=
                    New_Relation
                      (Op_Type => EW_Abstract,
                       Left    =>
                         New_Record_Access
                           (Name  => +A_Ident,
                            Field => To_Why_Id (Comp, Local => True)),
                       Right    =>
                         New_Record_Access
                           (Name  => +A_Ident,
                            Field => To_Why_Id (Comp, Local => True)),
                       Op      => EW_Eq);
                  Always_Present : constant Boolean :=
                    Ekind (E) = E_Record_Subtype or else
                    not (Has_Discriminants (E)) or else
                    Ekind (Comp) = E_Discriminant;
               begin
                  Condition :=
                    +New_And_Then_Expr
                    (Domain => EW_Pred,
                     Left   => +Condition,
                     Right  =>
                       (if Always_Present then +Comparison
                        else
                        New_Connection
                          (Domain => EW_Pred,
                           Op     => EW_Imply,
                           Left   => +Compute_Discriminant_Check (Comp),
                           Right  => +Comparison)));
               end;
            end if;
            Next_Component_Or_Discriminant (Comp);
         end loop;
         Emit
           (Theory,
            New_Function_Def
              (Domain      => EW_Term,
               Name        => To_Ident (WNE_Bool_Eq),
               Binders     =>
                 R_Binder &
               Binder_Array'(1 =>
                  Binder_Type'(B_Name => B_Ident,
                                 B_Type => Abstr_Ty,
                                 others => <>)),
               Return_Type => New_Base_Type (Base_Type => EW_Bool),
               Def         =>
                 New_Conditional
                   (Domain    => EW_Term,
                    Condition => +Condition,
                    Then_Part => +True_Term,
                    Else_Part => +False_Term)));
      end Declare_Equality_Function;

      ----------------------------------------
      -- Declare_Protected_Access_Functions --
      ----------------------------------------

      procedure Declare_Protected_Access_Functions
      is
         Field : Entity_Id := First_Component_Or_Discriminant (E);
      begin

         --  ??? enrich the postcondition of access to discriminant, whenever
         --  we statically know its value (in case of E_Record_Subtype)

         while Present (Field) loop
            if Is_Not_Hidden_Discriminant (Field) then
               declare
                  Why_Name  : constant W_Identifier_Id :=
                    To_Why_Id (Field, Local => True);
                  Prog_Name : constant W_Identifier_Id :=
                    To_Program_Space (Why_Name);
                  Pre_Cond  : constant W_Pred_Id :=
                    (if Ekind (E) = E_Record_Subtype  or else
                     Ekind (Field) = E_Discriminant then True_Pred
                     else Compute_Discriminant_Check (Field));
               begin
                  Emit (Theory,
                    New_Function_Decl
                      (Domain      => EW_Prog,
                       Name        => Prog_Name,
                       Binders     => R_Binder,
                       Return_Type =>
                         Why_Logic_Type_Of_Ada_Type (Etype (Field)),
                       Pre         => Pre_Cond,
                       Post        =>
                         New_Relation
                           (Left    => +To_Ident (WNE_Result),
                            Op_Type => EW_Abstract,
                            Op      => EW_Eq,
                            Right   =>
                              New_Record_Access
                                (Name => +A_Ident,
                                 Field => Why_Name))));
               end;
            end if;
            Next_Component_Or_Discriminant (Field);
         end loop;
      end Declare_Protected_Access_Functions;

      -------------------------
      -- Declare_Record_Type --
      -------------------------

      procedure Declare_Record_Type
      is
         Num_Fields : constant Natural := Count_Why_Record_Fields (E);
         Binders    : Binder_Array (1 .. Num_Fields);
         Field      : Entity_Id := First_Component_Or_Discriminant (E);
      begin
         for Index in 1 .. Num_Fields loop
            Binders (Index) :=
              (B_Name => To_Why_Id (Field, Local => True),
               B_Type =>
                 Why_Logic_Type_Of_Ada_Type (Etype (Field)),
               others => <>);
            loop
               Next_Component_Or_Discriminant (Field);
               exit when not (Present (Field)) or else
                 Is_Not_Hidden_Discriminant (Field);
            end loop;
         end loop;
         Emit (Theory,
           New_Record_Definition (Name    => Ty_Ident,
                                  Binders => Binders));
      end Declare_Record_Type;

      -------------------------
      -- Init_Component_Info --
      -------------------------

      procedure Init_Component_Info is
         procedure Mark_Component_List (N : Node_Id;
                                        Parent_Var_Part : Node_Id;
                                        Parent_Variant  : Node_Id);

         procedure Mark_Variant_Part (N : Node_Id;
                                      Parent_Var_Part : Node_Id;
                                      Parent_Variant  : Node_Id);

         --------------------------
         -- Mark_Component_Items --
         --------------------------

         procedure Mark_Component_List (N               : Node_Id;
                                        Parent_Var_Part : Node_Id;
                                        Parent_Variant  : Node_Id) is
            Field : Node_Id := First (Component_Items (N));
         begin
            while Present (Field) loop
               if Nkind (Field) /= N_Pragma then
                  Comp_Info.Insert
                    (Defining_Identifier (Field),
                     Component_Info'(
                       Parent_Variant  => Parent_Variant,
                       Parent_Var_Part => Parent_Var_Part,
                       Ident           =>
                         To_Why_Id
                           (Defining_Identifier (Field),
                            Local => True)));
               end if;
               Next (Field);
            end loop;
            if Present (Variant_Part (N)) then
               Mark_Variant_Part (Variant_Part (N),
                                  Parent_Var_Part,
                                  Parent_Variant);
            end if;
         end Mark_Component_List;

         -----------------------
         -- Mark_Variant_Part --
         -----------------------

         procedure Mark_Variant_Part (N               : Node_Id;
                                      Parent_Var_Part : Node_Id;
                                      Parent_Variant  : Node_Id) is
            Var : Node_Id := First (Variants (N));
         begin
            Comp_Info.Insert (N, Component_Info'(
              Parent_Variant  => Parent_Variant,
              Parent_Var_Part => Parent_Var_Part,
              Ident           => Why_Empty));
            while Present (Var) loop
               Mark_Component_List (Component_List (Var), N, Var);
               Next (Var);
            end loop;
         end Mark_Variant_Part;

         Decl_Node  : constant Node_Id := Parent (E);
         Field : Node_Id := First (Discriminant_Specifications (Decl_Node));
         Components : constant Node_Id :=
           Component_List (Type_Definition (Decl_Node));
      begin
         while Present (Field) loop
            Comp_Info.Insert
              (Defining_Identifier (Field),
               Component_Info'
                 (Parent_Variant  => Empty,
                  Parent_Var_Part => Empty,
                  Ident           =>
                    To_Why_Id (Defining_Identifier (Field),
                      Local => True)));
            Next (Field);
         end loop;
         if Present (Components) then
            Mark_Component_List (Components, Empty, Empty);
         end if;
      end Init_Component_Info;

      ----------------------
      -- Is_Others_Choice --
      ----------------------

      function Is_Others_Choice (N : Node_Id) return Boolean
      is
         Choices : constant List_Id := Discrete_Choices (N);
      begin
         return List_Length (Choices) = 1 and then
                 Nkind (First (Choices)) = N_Others_Choice;
      end Is_Others_Choice;

      --------------------------------
      -- Transform_Discrete_Choices --
      --------------------------------

      function Transform_Discrete_Choices (Case_N : Node_Id;
                                           Expr   : W_Term_Id)
                                           return W_Pred_Id
      is
      begin
         return +Gnat2Why.Expr.Transform_Discrete_Choices
           (Case_N       => Case_N,
            Matched_Expr => +Expr,
            Cond_Domain  => EW_Pred,
            Params       => Logic_Params);
      end Transform_Discrete_Choices;

   begin

      --  Get the empty record case out of the way

      if Count_Why_Record_Fields (E) = 0 then
         Emit
           (Theory,
            New_Type (To_String (WNE_Type)));
         return;
      end if;

      --  ??? We probably still need a way to tell that the right conversion
      --  function from this records subtype should go through the clone.

      if Ekind (E) = E_Record_Subtype and then
        Present (Cloned_Subtype (E)) then

         --  This type is simply a copy of an existing type, we re-export the
         --  corresponding module and generate trivial conversion functions,
         --  then return

         declare
            Clone : constant Entity_Id := Cloned_Subtype (E);
         begin
            Add_Use_For_Entity (P, Clone, EW_Export);
            if Clone = Base_Type (E) then
               Emit
                 (Theory,
                  New_Function_Def
                    (Domain      => EW_Term,
                     Name        => To_Ident (WNE_To_Base),
                     Binders     => R_Binder,
                     Return_Type => Abstr_Ty,
                     Def         => +A_Ident));
               Emit
                 (Theory,
                  New_Function_Def
                    (Domain      => EW_Term,
                     Name        => To_Ident (WNE_Of_Base),
                     Binders     => R_Binder,
                     Return_Type => Abstr_Ty,
                     Def         => +A_Ident));
            end if;
         end;
         return;
      end if;
      if Ekind (E) /= E_Record_Subtype then
         Init_Component_Info;
      end if;
      Declare_Record_Type;
      Declare_Protected_Access_Functions;
      if Root_Record_Type (E) /= E then
         Declare_Conversion_Functions;
      end if;
      Declare_Equality_Function;
   end Declare_Ada_Record;

   -----------------------------------------
   -- Needs_Discriminant_Check_For_Access --
   -----------------------------------------

   function Needs_Discriminant_Check_For_Access (E : Entity_Id) return Boolean
   is
   begin
      if Ekind (E) = E_Discriminant then
         return False;
      elsif Ekind (Scope (E)) = E_Record_Subtype then
         return False;
      end if;
      return
        Nkind (Parent (Parent (List_Containing (Parent (E))))) = N_Variant;
   end Needs_Discriminant_Check_For_Access;

   ---------------------------
   -- New_Ada_Record_Access --
   ---------------------------

   function New_Ada_Record_Access
     (Ada_Node : Node_Id;
      Domain   : EW_Domain;
      Name     : W_Expr_Id;
      Field    : Entity_Id) return W_Expr_Id
   is
      Call_Id : constant W_Identifier_Id :=
        (if Domain = EW_Prog then
         To_Program_Space (To_Why_Id (Field))
         else To_Why_Id (Field));
   begin
      if Needs_Discriminant_Check_For_Access (Field) then
         return
           New_VC_Call
             (Ada_Node => Ada_Node,
              Name     => Call_Id,
              Progs    => (1 => Name),
              Domain   => Domain,
              Reason   => VC_Discriminant_Check);
      else
         return
           New_Call
             (Ada_Node => Ada_Node,
              Name     => Call_Id,
              Args    => (1 => Name),
              Domain   => Domain);

      end if;
   end New_Ada_Record_Access;

   ---------------------------
   -- New_Ada_Record_Update --
   ---------------------------

   function New_Ada_Record_Update
     (Ada_Node : Node_Id;
      Domain : EW_Domain;
      Name   : W_Expr_Id;
      Field  : Entity_Id;
      Value  : W_Expr_Id) return W_Expr_Id
   is
      Update_Expr : constant W_Expr_Id :=
        New_Record_Update
          (Ada_Node => Ada_Node,
           Name     => Name,
           Updates  =>
             (1 =>
                New_Field_Association
                  (Domain => Domain,
                   Field  => To_Why_Id (Field, Domain),
                   Value  => Value)));

   begin
      if Domain = EW_Prog then
         return
           +Sequence
             (+New_Ignore
                  (Ada_Node => Ada_Node,
                   Prog     =>
                     +New_Ada_Record_Access (Ada_Node, Domain, Name, Field)),
              +Update_Expr);
      else
         return Update_Expr;
      end if;
   end New_Ada_Record_Update;

end Why.Gen.Records;
