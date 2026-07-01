----------------------------------------------------------------------------------
--  Author: Michaiah Williams, University of Victoria
--  Project: Paralel Baugh-Wooley Segmented Approximate Multiplier
--  Creation Date: 2026-06-30
--  Description: testbench for paralel INT8 multiplier
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
use work.column_vector_pkg.all;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity TB_Mult6_INT8_16 is
--  Port ( );
end TB_Mult6_INT8_16;

architecture Behavioral of TB_Mult6_INT8_16 is
    constant BITWIDTH : integer := 8;
    constant VECLEN : integer := 16;
    constant clk_period : time := 10 ns;
    signal a_count: unsigned (BITWIDTH-1 downto 0);
    signal a_vec: column_vector(VECLEN-1 downto 0);
    signal b_count: unsigned (BITWIDTH-1 downto 0);
    signal result0: column_vector_double(VECLEN-1 downto 0);
    signal result1: column_vector_double(VECLEN-1 downto 0);
    signal clk, rst         : STD_LOGIC;  


    component approximate_lut6_mult_N is
        generic(REFINEMENT_PART : INTEGER:= 3;   -- which solution (part of partial products) to be used for accuracy refinement
                NUM_PARALEL : INTEGER:= 16;
                INOUT_BUF_EN : BOOLEAN:= True);
        Port ( a_i : in column_vector(NUM_PARALEL - 1 downto 0);  -- Mult input 1
               b_i : in STD_LOGIC_VECTOR(7 downto 0);  -- Mult input 2
               clk, rst : in STD_LOGIC;
               result_o : out column_vector_double(NUM_PARALEL - 1 downto 0)
               );
    end component;

begin

    clk_process :process
		begin
			clk <= '0';
			wait for clk_period/2;  --for 5 ns signal is '0'.
			clk <= '1';
			wait for clk_period/2;  --for next 5 ns signal is '1'.
		end process;				
	rst <=  '1' , '0' after 4 * clk_period;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                a_count <= (others => '0');
                b_count <= (others => '0');
            else
                if (conv_integer(a_count) = 2**BITWIDTH-VECLEN) then
                    a_count <= (others => '0');
                    if (conv_integer(b_count) = 2**BITWIDTH-1) then
                        finish;
                    else
                        b_count <= b_count + 1;
                        a_count <= a_count + VECLEN;
                    end if;
                else
                    a_count <= a_count + VECLEN;
                end if;
                INNER: for I in 0 to VECLEN-1 loop
                    a_vec(I) <= signed(a_count) + conv_signed(I, BITWIDTH);
                end loop INNER;
            end if;
        end if;
    end process;


    MUL_INST_0: approximate_lut6_mult_N
        generic map (REFINEMENT_PART => 0,   -- which solution (part of partial products) to be used for accuracy refinement
                    NUM_PARALEL => 16,
                    INOUT_BUF_EN => True)
        Port map( a_i => a_vec,  -- Mult input 1
               b_i => std_logic_vector(b_count),  -- Mult input 2
               clk => clk,
               rst => rst,
               result_o => result0
               );
               
        MUL_INST_1: approximate_lut6_mult_N
        generic map (REFINEMENT_PART => 1,   -- which solution (part of partial products) to be used for accuracy refinement
                    NUM_PARALEL => 16,
                    INOUT_BUF_EN => True)
        Port map( a_i => a_vec,  -- Mult input 1
               b_i => std_logic_vector(b_count),  -- Mult input 2
               clk => clk,
               rst => rst,
               result_o => result1
               );

end Behavioral;