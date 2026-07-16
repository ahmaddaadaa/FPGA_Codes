----------------------------------------------------------------------------------
-- Email: salim.ullah@tu-dresden.de
-- This code is free and distributed without any kind of warranty
-- Copyright (C) Salim Ullah and Akash Kumar, TU Dresden, Germany
---------------------------------------------------------------------------------
-- Approximate 16x16 multiplier Ca
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
library UNISIM;
use UNISIM.VComponents.all;

entity mult_16x16 is
generic (word_size: natural:= 16);
Port (
a : in  STD_LOGIC_VECTOR (word_size-1 downto 0);
b : in  STD_LOGIC_VECTOR (word_size-1 downto 0);
prod: out STD_LOGIC_VECTOR (word_size * 2 - 1 downto 0));
end mult_16x16;
architecture Behavioral of mult_16x16 is

component goal is

  Port (
  a : in  STD_LOGIC_VECTOR (7 downto 0);
  b : in  STD_LOGIC_VECTOR (7 downto 0);
  prod: out STD_LOGIC_VECTOR (15 downto 0));
end component;

component adder_16 is
		Port ( prod1 : in  STD_LOGIC_VECTOR (15 downto 0);
			   prod2 : in  STD_LOGIC_VECTOR (15 downto 0);
			   prod3 : in  STD_LOGIC_VECTOR (15 downto 0);
			   prod4 : in  STD_LOGIC_VECTOR (15 downto 0);
			   PROD : out  STD_LOGIC_VECTOR (31 downto 0));
end component;

type pps is array(3 downto 0) of std_logic_vector(15 downto 0);
signal prod_sig: pps;
signal gen, prop: std_logic_vector(23 downto 0);
signal output, carries: std_logic_vector(23 downto 0);
signal input_carry: std_logic_vector(6 downto 0);
signal last_carries: std_logic_vector(3 downto 0);
signal sum, carr: std_logic_vector(16 downto 0);
begin
pp_gen:
for i in 0 to 1 generate
second:
for j in 0 to 1 generate
inst0_mult: goal
port map (
a => a(8*i+7 downto 8*i),
b => b(8*j+7 downto 8*j),
prod => prod_sig(i * (word_size/8) + j)
);
end generate second;
end generate pp_gen;

inst_add1: adder_16 port map(
prod1 => prod_sig(0),
prod2 => prod_sig(1),
prod3 => prod_sig(2),
prod4 => prod_sig(3),
PROD => PROD
);


end Behavioral;
