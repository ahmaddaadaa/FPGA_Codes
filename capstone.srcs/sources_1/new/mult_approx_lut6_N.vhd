----------------------------------------------------------------------------------
--  Author: Michaiah Williams, University of Victoria
--  Project: Paralel Baugh-Wooley Segmented Approximate Multiplier
--  Creation Date: 2026-06-30
--  Description: performs multiplication using approximate_lut6_mult in paralel
----------------------------------------------------------------------------------


library IEEE;
library std;
use std.env.all;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.std_logic_signed.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_textio.all;
use ieee.std_logic_arith.all;
use std.textio.all;
use ieee.math_real.all;

package column_vector_pkg is
        type column_vector is array(natural range <>) of std_logic_vector(7 downto 0);
        type column_vector_temp is array(natural range <>) of std_logic_vector(10 downto 0);
        type column_vector_double is array(natural range <>) of std_logic_vector(14 downto 0);
end package;

library IEEE;
library std;
use std.env.all;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.std_logic_signed.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_textio.all;
use ieee.std_logic_arith.all;
use std.textio.all;
use ieee.math_real.all;
use work.column_vector_pkg.all;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity approximate_lut6_mult_N is
    generic(REFINEMENT_PART : INTEGER:= 0;   -- which solution (part of partial products) to be used for accuracy refinement
            NUM_PARALEL : INTEGER:= 16;      -- how many multiplications to run in paralel
            INOUT_BUF_EN : BOOLEAN:= True);
    Port ( a_i : in column_vector(NUM_PARALEL - 1 downto 0);  -- Mult input 1
           b_i : in STD_LOGIC_VECTOR(7 downto 0);  -- Mult input 2
           clk, rst : in STD_LOGIC;
           result_o : out column_vector_double(NUM_PARALEL - 1 downto 0)
           );
end approximate_lut6_mult_N;

architecture Behavioral of approximate_lut6_mult_N is
    signal result_temp  : column_vector_temp(NUM_PARALEL - 1 downto 0);

    component approximate_lut6_mult is
        generic(REFINEMENT_PART : INTEGER:= REFINEMENT_PART;   -- which solution (part of partial products) to be used for accuracy refinement
                INOUT_BUF_EN : BOOLEAN:= INOUT_BUF_EN);
        Port ( a_i : in STD_LOGIC_VECTOR(7 downto 0);  -- Mult input 1
               b_i : in STD_LOGIC_VECTOR(7 downto 0);  -- Mult input 2
               clk, rst : in STD_LOGIC;
               result_o : out STD_LOGIC_VECTOR (10 downto 0)
               );
    end component;
    
    component copier is
        generic(N : INTEGER:= 15);
        Port ( i : in STD_LOGIC_VECTOR(N-1 downto 0);  -- Mult input 1
               o : out STD_LOGIC_VECTOR(N-1 downto 0)
               );
    end component;

begin

    GEN_MULT:
        for I in 0 to (NUM_PARALEL - 1) generate
            MULTA : approximate_lut6_mult
            generic map(REFINEMENT_PART => REFINEMENT_PART,
                        INOUT_BUF_EN => INOUT_BUF_EN)
            Port map (  a_i => a_i(I),  -- Mult input 1
                        b_i => b_i,     -- Mult input 2
                        clk => clk,
                        rst => rst,
                        result_o => result_temp(I));
            TMPA : copier
            generic map(N => 11)
            Port map (  i => result_temp(I),
                        o => result_o(I)(14 downto 4));
            TAILA : copier
            generic map(N => 4)
            Port map (  i => "0000",
                        o => result_o(I)(3 downto 0));
        end generate GEN_MULT;
        
end Behavioral;