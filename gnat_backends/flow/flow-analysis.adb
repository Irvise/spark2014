------------------------------------------------------------------------------
--                                                                          --
--                           GNAT2WHY COMPONENTS                            --
--                                                                          --
--                        F L O W . A N A L Y S I S                         --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--                  Copyright (C) 2013, Altran UK Limited                   --
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
------------------------------------------------------------------------------

with Errout; use Errout;
with Why;

--  with Flow.Debug; use Flow.Debug;
--  with Treepr;     use Treepr;

package body Flow.Analysis is

   procedure Error_Msg_Flow (Msg : String;
                             G   : Flow_Graphs.T'Class;
                             Loc : Flow_Graphs.Vertex_Id);
   --  Output an error message attaced to the given vertex.

   procedure Error_Msg_Flow (Msg : String;
                             G   : Flow_Graphs.T'Class;
                             Loc : Flow_Graphs.Vertex_Id;
                             F   : Flow_Id);
   --  Output an error message attaced to the given vertex
   --  with a substitution using F.

   --------------------
   -- Error_Msg_Flow --
   --------------------

   procedure Error_Msg_Flow (Msg : String;
                             G   : Flow_Graphs.T'Class;
                             Loc : Flow_Graphs.Vertex_Id) is
      K : constant Flow_Id      := G.Get_Key (Loc);
      A : constant V_Attributes := G.Get_Attributes (Loc);
   begin
      if A.Error_Location /= Empty then
         --  Try the helpful location first.
         Error_Msg_N (Msg, A.Error_Location);

      else
         --  Do our best with the key
         case K.Kind is
            when Direct_Mapping =>
               Error_Msg_N (Msg, Get_Direct_Mapping_Id (K));
            when others =>
               raise Why.Not_Implemented;
         end case;
      end if;
   end Error_Msg_Flow;

   procedure Error_Msg_Flow (Msg : String;
                             G   : Flow_Graphs.T'Class;
                             Loc : Flow_Graphs.Vertex_Id;
                             F   : Flow_Id) is
      K : constant Flow_Id      := G.Get_Key (Loc);
      A : constant V_Attributes := G.Get_Attributes (Loc);
   begin
      pragma Assert (F.Kind = Direct_Mapping);

      if A.Error_Location /= Empty then
         --  Try the helpful location first.
         Error_Msg_NE (Msg, A.Error_Location, Get_Direct_Mapping_Id (F));

      else
         --  Do our best with the key
         case K.Kind is
            when Direct_Mapping =>
               Error_Msg_NE (Msg,
                             Get_Direct_Mapping_Id (K),
                             Get_Direct_Mapping_Id (F));
            when others =>
               Print_Flow_Id (K);
               raise Why.Not_Implemented;
         end case;
      end if;
   end Error_Msg_Flow;

   ------------------
   -- Sanity_Check --
   ------------------

   procedure Sanity_Check (FA : Flow_Analysis_Graphs) is
      use type Flow_Id_Sets.Set;
   begin
      --  Sanity check all vertices if they mention a flow id that we
      --  do not know about.
      for V of FA.CFG.Get_Collection (Flow_Graphs.All_Vertices) loop
         declare
            A : constant V_Attributes := FA.CFG.Get_Attributes (V);

            All_Vars : constant Flow_Id_Sets.Set :=
              A.Variables_Used or A.Variables_Defined;
         begin
            for Var of All_Vars loop
               declare
                  Neutral : constant Flow_Id :=
                    Change_Variant (Var, Normal_Use);
               begin
                  if not FA.All_Vars.Contains (Neutral) then
                     Error_Msg_Flow ("& not visible!", FA.CFG,
                                     V, Var);
                  end if;
               end;
            end loop;
         end;
      end loop;
   end Sanity_Check;

   ------------------------------
   -- Find_Ineffective_Imports --
   ------------------------------

   procedure Find_Ineffective_Imports (FA : Flow_Analysis_Graphs) is
      function Is_Final_Use (V : Flow_Graphs.Vertex_Id) return Boolean;
      --  Checks if the given vertex V is a final-use vertex.

      function Is_Final_Use (V : Flow_Graphs.Vertex_Id) return Boolean is
      begin
         return FA.PDG.Get_Key (V).Variant = Final_Value and then
           FA.PDG.Get_Attributes (V).Is_Export;
      end Is_Final_Use;
   begin
      for V of FA.PDG.Get_Collection (Flow_Graphs.All_Vertices) loop
         declare
            Key : constant Flow_Id      := FA.PDG.Get_Key (V);
            Atr : constant V_Attributes := FA.PDG.Get_Attributes (V);
         begin
            if Key.Variant = Initial_Value
              and then Atr.Is_Initialised
              and then (not Atr.Is_Loop_Parameter) then
               if not FA.PDG.Non_Trivial_Path_Exists
                 (V, Is_Final_Use'Access) then
                  Error_Msg_Flow ("ineffective import!", FA.PDG, V);
               end if;
            end if;
         end;
      end loop;
   end Find_Ineffective_Imports;

   ---------------------------------
   -- Find_Ineffective_Statements --
   ---------------------------------

   procedure Find_Ineffective_Statements (FA : Flow_Analysis_Graphs) is
      function Is_Final_Use (V : Flow_Graphs.Vertex_Id) return Boolean;
      --  Checks if the given vertex V is a final-use vertex.

      function Is_Final_Use (V : Flow_Graphs.Vertex_Id) return Boolean is
      begin
         return FA.PDG.Get_Key (V).Variant = Final_Value and then
           FA.PDG.Get_Attributes (V).Is_Export;
      end Is_Final_Use;
   begin
      for V of FA.PDG.Get_Collection (Flow_Graphs.All_Vertices) loop
         declare
            Atr : constant V_Attributes := FA.PDG.Get_Attributes (V);
         begin
            if Atr.Is_Program_Node then
               if not FA.PDG.Non_Trivial_Path_Exists
                 (V, Is_Final_Use'Access) then
                  Error_Msg_Flow ("ineffective statement!", FA.PDG, V);
               end if;
            end if;
         end;
      end loop;
   end Find_Ineffective_Statements;

   -----------------------------------------
   -- Find_Use_Of_Uninitialised_Variables --
   -----------------------------------------

   procedure Find_Use_Of_Uninitialised_Variables (FA : Flow_Analysis_Graphs) is
   begin
      for V_Initial of FA.PDG.Get_Collection (Flow_Graphs.All_Vertices) loop
         declare
            Key_I : constant Flow_Id      := FA.PDG.Get_Key (V_Initial);
            Atr_I : constant V_Attributes := FA.PDG.Get_Attributes (V_Initial);
         begin
            if Key_I.Variant = Initial_Value and then
              not Atr_I.Is_Initialised then
               for V_Use of FA.PDG.Get_Collection
                 (V_Initial, Flow_Graphs.Out_Neighbours) loop
                  declare
                     Key_U : constant Flow_Id := FA.PDG.Get_Key (V_Use);
                  begin
                     if Key_U.Variant = Final_Value then
                        Error_Msg_Flow ("may never be initialized!",
                                        FA.PDG, V_Use);
                     else
                        Error_Msg_Flow ("use of uninitialized variable &!",
                                        FA.PDG, V_Use, Key_I);
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;
   end Find_Use_Of_Uninitialised_Variables;

   --------------------------
   -- Find_Stable_Elements --
   --------------------------

   procedure Find_Stable_Elements (FA : Flow_Analysis_Graphs) is
      Done      : Boolean       := False;
      Tmp       : Flow_Graphs.T := FA.DDG.Create;
      Is_Stable : Boolean;
   begin
      for Loop_Id of FA.Loops loop
         Done := False;
         while not Done loop
            Done := True;
            for N_Loop of FA.PDG.Get_Collection (Flow_Graphs.All_Vertices) loop
               declare
                  Atr : V_Attributes := Tmp.Get_Attributes (N_Loop);
               begin
                  if Atr.Loops.Contains (Loop_Id) then
                     --  For all nodes in the loop, do:

                     --  We start by checking if the used variables
                     --  contain the loop parameter for our loop.
                     Is_Stable := not Atr.Variables_Used.Contains
                       (Direct_Mapping_Id
                          (Loop_Parameter_From_Loop (Loop_Id)));

                     --  We then check if we have at least one
                     --  in-neighbour from "outside" the loop.
                     if Is_Stable then
                        for V of FA.PDG.Get_Collection
                          (N_Loop, Flow_Graphs.In_Neighbours) loop
                           if Tmp.Get_Attributes (V).Loops.Contains
                             (Loop_Id) then
                              Is_Stable := False;
                              exit;
                           end if;
                        end loop;
                     end if;

                     if Is_Stable then
                        --  Remove from the loop
                        Atr.Loops.Delete (Loop_Id);
                        Tmp.Set_Attributes (N_Loop, Atr);

                        --  Complain
                        Error_Msg_Flow ("stable!", FA.PDG, N_Loop);

                        --  There might be other stable elements now.
                        Done := False;
                     end if;
                  end if;
               end;
            end loop;
         end loop;
      end loop;
   end Find_Stable_Elements;

end Flow.Analysis;
