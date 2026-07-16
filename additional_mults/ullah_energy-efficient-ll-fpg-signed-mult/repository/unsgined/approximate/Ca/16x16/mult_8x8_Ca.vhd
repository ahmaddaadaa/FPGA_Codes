----------------------------------------------------------------------------------
-- Email: salim.ullah@tu-dresden.de
-- This code is free and distributed without any kind of warranty
-- Copyright (C) Salim Ullah and Akash Kumar, TU Dresden, Germany
---------------------------------------------------------------------------------
-- Approximate 8x8 multiplier Ca
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
library UNISIM;
use UNISIM.VComponents.all;

entity mult_8x8_Ca is
Port (
A : in STD_LOGIC_VECTOR (7 downto 0);
B : in STD_LOGIC_VECTOR (7 downto 0);
PROD : out STD_LOGIC_VECTOR (15 downto 0));
end mult_8x8_Ca;

architecture Behavioral of mult_8x8_Ca is

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

component adder is
		Port ( prod1 : in  STD_LOGIC_VECTOR (7 downto 0);
			   prod2 : in  STD_LOGIC_VECTOR (7 downto 0);
			   prod3 : in  STD_LOGIC_VECTOR (7 downto 0);
			   prod4 : in  STD_LOGIC_VECTOR (7 downto 0);
			   PROD : out  STD_LOGIC_VECTOR (15 downto 0));
end component;

signal prod1 : STD_LOGIC_VECTOR (7 downto 0);
signal prod2 : STD_LOGIC_VECTOR (7 downto 0);
signal prod3 : STD_LOGIC_VECTOR (7 downto 0);
signal prod4 : STD_LOGIC_VECTOR (7 downto 0);


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

inst_add: adder port map(
prod1 => prod1,
prod2 => prod2,
prod3 => prod3,
prod4 => prod4,
PROD => PROD
);


end Behavioral;