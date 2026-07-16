library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
library UNISIM;
use UNISIM.VComponents.all;

entity wrapper is
    generic (word_size: natural := 32);

    Port ( a : in STD_LOGIC_VECTOR (word_size -1 downto 0);
           b : in STD_LOGIC_VECTOR (word_size -1 downto 0);
		 --  prod_sign_mag : out std_logic_vector(2*word_size-1 downto 0);
           prod : out STD_LOGIC_VECTOR (2*word_size -1 downto 0));
end wrapper;

architecture Behavioral of wrapper is

component mult_32x32 is
    --generic (word_size: natural:= 16);
    Port (
    a : in  STD_LOGIC_VECTOR (word_size-1 downto 0);
    b : in  STD_LOGIC_VECTOR (word_size-1 downto 0);
    prod: out STD_LOGIC_VECTOR (word_size * 2 - 1 downto 0));
  end component;


begin
	mult_inst: mult_32x32

		Port map (
        A => a,
        B => b,
        PROD => prod
		);

end Behavioral;
