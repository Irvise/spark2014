package F
  with SPARK_Mode => On,
       Initializes => A
is
   A : Integer := 1;

   function Dyn return Integer
     with Global   => A,
          Annotate => (GNATprove, Always_Return);

end F;
