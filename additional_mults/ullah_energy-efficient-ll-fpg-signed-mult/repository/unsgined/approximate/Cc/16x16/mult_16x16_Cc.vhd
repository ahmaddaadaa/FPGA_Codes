----------------------------------------------------------------------------------
-- Email: salim.ullah@tu-dresden.de
-- This code is free and distributed without any kind of warranty
-- Copyright (C) Salim Ullah and Akash Kumar, TU Dresden, Germany
---------------------------------------------------------------------------------
-- Approximate 16x16 multiplier Cc
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
library UNISIM;
use UNISIM.VComponents.all;
entity mult_16x16 is
generic (mult_size: integer:= 16);
Port (
a : in  STD_LOGIC_VECTOR (mult_size-1 downto 0);
b : in  STD_LOGIC_VECTOR (mult_size-1 downto 0);
prod: out STD_LOGIC_VECTOR (mult_size * 2 - 1 downto 0));
end mult_16x16;

architecture Behavioral of mult_16x16 is

component mult_8x8 is
--generic(word_size : integer);
 Port (a: in STD_LOGIC_VECTOR(7 downto 0);
		b: in STD_LOGIC_VECTOR(7 downto 0);
		prod: out STD_LOGIC_VECTOR(15 downto 0));
end component;
type pps is array(3 downto 0) of std_logic_vector(mult_size - 1 downto 0);
signal prod_sig: pps;
signal gen, prop: std_logic_vector(23 downto 0);
signal output, carries: std_logic_vector(23 downto 0);
signal input_carry: std_logic_vector(6 downto 0);
signal last_carries: std_logic_vector(3 downto 0);
signal sum, carr: std_logic_vector(mult_size downto 0);
begin
pp_gen:
for i in 0 to 1 generate
second:
for j in 0 to 1 generate
inst0_mult: mult_8x8
--generic map(word_size => mult_size/2)
port map (
a => a(8*i+7 downto 8*i),
b => b(8*j+7 downto 8*j),
prod => prod_sig(i * (mult_size/8) + j)
);
end generate second;
end generate pp_gen;

pp_add:
for k in 0 to (mult_size/2 - 1) generate
lut_inst0: lut6_2
generic map(INIT => X"9696969696969696")
port map(
I0 => prod_sig(0)(k + 8),
I1 => prod_sig(1)(k),
I2 => prod_sig(2)(k),
I3 => '1',
I4 => '1',
I5 => '1',
O6 => sum(k)
 );
end generate pp_add;

pp_add1:
for l in 0 to (mult_size/2 - 1) generate
lut_inst1: lut6_2
generic map(INIT => X"9696969696969696")
port map(
I0 => prod_sig(1)(l + 8),
I1 => prod_sig(2)(l + 8),
I2 => prod_sig(3)(l),
I3 => '1',
I4 => '1',
I5 => '1',
O6 => sum(l + 8)
);
end generate pp_add1;

assign_values0:
for r in 0 to mult_size/2 - 1 generate
prod(r) <= prod_sig(0)(r);
end generate assign_values0;

assign_values1:
for s in 0 to mult_size - 1 generate
prod(s + (mult_size/2)) <= sum(s);
end generate assign_values1;

assign_values3:
for t in mult_size/2 to mult_size - 1 generate
prod(t + mult_size) <= prod_sig(3)(t);
end generate assign_values3;

end Behavioral;
