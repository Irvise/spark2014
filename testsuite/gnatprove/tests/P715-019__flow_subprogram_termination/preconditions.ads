package Preconditions with Annotate => (GNATprove, Always_Return) is
   function Returning_Precondition (A, B : Integer)
                                    return Boolean
   is (A = B);

   function Nonreturning_Precondition (A, B : Integer) return Boolean;

end;
