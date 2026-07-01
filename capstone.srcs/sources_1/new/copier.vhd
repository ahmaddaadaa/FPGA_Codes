----------------------------------------------------------------------------------
--  Author: Michaiah Williams, University of Victoria
--  Project: helper function
--  Creation Date: 2026-06-30
--  Description: copies N bits
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity copier is
    generic(N : INTEGER:= 15);
    Port ( i : in STD_LOGIC_VECTOR(N-1 downto 0);
           o : out STD_LOGIC_VECTOR(N-1 downto 0)
           );
end copier;

architecture Behavioral of copier is

begin

    o <= i;

end Behavioral;
