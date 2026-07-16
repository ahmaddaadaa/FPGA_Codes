library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
library UNISIM;
use UNISIM.VComponents.all;

entity mult_32x32 is
generic (word_size: natural:= 32);
Port (
a : in  STD_LOGIC_VECTOR (word_size-1 downto 0);
b : in  STD_LOGIC_VECTOR (word_size-1 downto 0);
prod: out STD_LOGIC_VECTOR (word_size * 2 - 1 downto 0));
end mult_32x32;
architecture Behavioral of mult_32x32 is

component goal_16x16 is

Port (
a : in  STD_LOGIC_VECTOR (word_size/2-1 downto 0);
b : in  STD_LOGIC_VECTOR (word_size/2-1 downto 0);

prod: out STD_LOGIC_VECTOR (word_size - 1 downto 0));
end component;

component adder_32 is
  Port ( prod1      : in std_logic_vector(word_size-1 downto 0);
         prod2      : in std_logic_vector(word_size-1 downto 0);
         prod3      : in std_logic_vector(word_size-1 downto 0);
         prod4      : in std_logic_vector(word_size-1 downto 0);

         PROD      : out std_logic_vector(word_size*2-1 downto 0));
end component;
type pps is array(3 downto 0) of std_logic_vector(word_size-1 downto 0);
signal prod_sig: pps;
begin
  pp_gen:
    for i in 0 to 1 generate
    second:
      for j in 0 to 1 generate
        inst0_mult: goal_16x16
        port map (
          a => a((word_size/2)*i+(word_size/2-1) downto (word_size/2)*i),
          b => b((word_size/2)*j+(word_size/2-1) downto (word_size/2)*j),
          prod => prod_sig(i*2 + j)
          );
    end generate second;
  end generate pp_gen;

  inst_add1: adder_32
   port map(
      prod1 => prod_sig(0),
      prod2 => prod_sig(1),
      prod3 => prod_sig(2),
      prod4 => prod_sig(3),
      PROD => PROD
    );


end Behavioral;
