----------------------------------------------------------------------------------
-- Email: salim.ullah@tu-dresden.de
-- This code is free and distributed without any kind of warranty
-- Copyright (C) Salim Ullah and Akash Kumar, TU Dresden, Germany
---------------------------------------------------------------------------------
-- Approximate 8x8 multiplier Cc
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
library UNISIM;
use UNISIM.VComponents.all;

entity mult_8x8 is
Port (
A : in STD_LOGIC_VECTOR (7 downto 0);
B : in STD_LOGIC_VECTOR (7 downto 0);
PROD : out STD_LOGIC_VECTOR (15 downto 0));
end mult_8x8;

architecture Behavioral of mult_8x8 is

component mult_accurate is
		Port ( a : in  STD_LOGIC_VECTOR (3 downto 0);
			   b : in  STD_LOGIC_VECTOR (3 downto 0);
			   prod : out  STD_LOGIC_VECTOR (7 downto 0));
end component;

component mult_approx is
		Port ( a : in  STD_LOGIC_VECTOR (3 downto 0);
			   b : in  STD_LOGIC_VECTOR (3 downto 0);
			   prod : out  STD_LOGIC_VECTOR (7 downto 0));
end component;

signal prod1 : STD_LOGIC_VECTOR (7 downto 0);
signal prod2 : STD_LOGIC_VECTOR (7 downto 0);
signal prod3 : STD_LOGIC_VECTOR (7 downto 0);
signal prod4 : STD_LOGIC_VECTOR (7 downto 0);
signal sum: std_logic_vector(8 downto 0);


begin
inst1_mult: mult_approx port map(
a => A(3 downto 0),
b => B(3 downto 0),
prod => prod1
);

inst2_mult: mult_approx port map(
a => A(7 downto 4),
b => B(3 downto 0),
prod => prod2
);

inst3_mult: mult_approx port map(
a => A(3 downto 0),
b => B(7 downto 4),
prod => prod3
);

inst4_mult: mult_approx port map(
a => A(7 downto 4),
b => B(7 downto 4),
prod => prod4
);

pp_add:
for k in 0 to 3 generate
lut_inst0: lut6_2
generic map(INIT => X"9696969696969696")
port map (
I0 => prod1(k+4),
I1 => prod2(k),
I2 => prod3(k),
I3 => '1',
I4 => '1',
I5 => '1',
O6 => sum(k)
);
end generate pp_add;
pp_add1:
for l in 0 to 3 generate
lut_inst1: lut6_2
generic map(INIT => X"9696969696969696")
port map(
I0 => prod2(l+4),
I1 => prod3(l+4),
I2 => prod4(l),
I3 => '1',
I4 => '1',
I5 => '1',
O6 => sum(l+4)
);
end generate pp_add1;
assign_values0:
for r in 0 to 3 generate
prod(r) <= prod1(r) ;
end generate assign_values0;
assign_values1:
for s in 0 to 7 generate
prod(s + 4) <= sum(s);
end generate assign_values1;
assign_values3:
for t in 4 to 7 generate
prod(t + 8) <= prod4(t);
end generate assign_values3;
end Behavioral;
