------------------------------------------------------------------------------
--                                                                          --
--                            GNAT2WHY COMPONENTS                           --
--                                                                          --
--                   G N A T 2 W H Y - G E N - T E R M S                    --
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

with Why.Sinfo;           use Why.Sinfo;
with Why.Atree.Accessors; use Why.Atree.Accessors;
with Why.Atree.Builders;  use Why.Atree.Builders;
with Why.Atree.Traversal; use Why.Atree.Traversal;
with Why.Conversions;     use Why.Conversions;
with Why.Gen.Names;       use Why.Gen.Names;

package body Why.Gen.Terms is

   function Get_All_Dereferences (W : Why_Node_Id) return Why_Node_Sets.Set is
      type Collect_State is new Traversal_State with record
         Found : Why_Node_Sets.Set;
      end record;

      procedure Deref_Pre_Op
        (State : in out Collect_State;
         Node  : W_Deref_Id);

      procedure Deref_Pre_Op
        (State : in out Collect_State;
         Node  : W_Deref_Id) is
      begin
         State.Found.Include (+Get_Right (Node));
      end Deref_Pre_Op;

      SS : Collect_State :=
             (Control => Continue, Found => Why_Node_Sets.Empty_Set);
   begin
      Traverse (SS, W);
      return SS.Found;
   end Get_All_Dereferences;

   ---------------------
   -- Has_Dereference --
   ---------------------

   function Has_Dereference_Or_Any (T : W_Term_Id) return Boolean is
      type Search_State is new Traversal_State with record
         Found : Boolean;
      end record;

      procedure Deref_Pre_Op
        (State : in out Search_State;
         Node  : W_Deref_Id);

      procedure Any_Expr_Pre_Op
        (State : in out Search_State;
         Node  : W_Any_Expr_Id);

      procedure Deref_Pre_Op
        (State : in out Search_State;
         Node  : W_Deref_Id)
      is
         pragma Unreferenced (Node);
      begin
         State.Found   := True;
         State.Control := Terminate_Immediately;
      end Deref_Pre_Op;

      procedure Any_Expr_Pre_Op
        (State : in out Search_State;
         Node  : W_Any_Expr_Id)
      is
         pragma Unreferenced (Node);
      begin
         State.Found   := True;
         State.Control := Terminate_Immediately;
      end Any_Expr_Pre_Op;

      SS : Search_State := (Control => Continue, Found => False);
   begin
      Traverse (SS, +T);
      return SS.Found;
   end Has_Dereference_Or_Any;

   -------------
   -- New_Ifb --
   -------------

   function New_Ifb (Condition, Left, Right : W_Term_Id) return W_Term_Id
   is
   begin
      case Get_Kind (+Condition) is
         when W_Literal =>
            if Get_Value (+Condition) = EW_True then
               return Left;
            else
               return Right;
            end if;

         when others =>
            return
              New_Call
                (Name => New_Identifier (Name => "ite"),
                 Args => (1 => +Condition, 2 => +Left, 3 => +Right));
      end case;
   end New_Ifb;

end Why.Gen.Terms;
