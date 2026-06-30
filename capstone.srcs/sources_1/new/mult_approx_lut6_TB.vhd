---------------------------------------------------------------------------------------------------
--                __________
--    ______     /   ________      _          ______
--   |  ____|   /   /   ______    | |        |  ____|
--   | |       /   /   /      \   | |        | |
--   | |____  /   /   /        \  | |        | |____
--   |  ____| \   \   \        /  | |        |  ____|   
--   | |       \   \   \______/   | |        | |
--   | |____    \   \________     | |_____   | |____
--   |______|    \ _________      |_______|  |______|
--
--  ECCoLe: Edge Computing, Communication and Learning Lab 
--
--  Author: Shervin Vakili, INRS University
--  Heavily revised by Michaiah Williams, University of Victoria
--  Project: Baugh-Wooley Segmented Approximate Multiplier
--  Creation Date: 2023-11-21
--  Description: Testbench for INT8 Multiplier
--  See ECCoLe_LICENSE
------------------------------------------------------------------------------------------------


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

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity TB_Mult6_INT8 is
--  Port ( );
end TB_Mult6_INT8;

architecture Behavioral of TB_Mult6_INT8 is
    constant BITWIDTH : integer := 8;
    constant clk_period : time := 10 ns;
    signal a_count: unsigned (BITWIDTH-1 downto 0);
    signal b_count: unsigned (BITWIDTH-1 downto 0);
    signal result0: std_logic_vector (14 downto 0);
    signal result_signed0: signed (14 downto 0);
    signal result1: std_logic_vector (14 downto 0);
    signal result_signed1: signed (14 downto 0);
    signal result_exact: signed (15 downto 0);
    signal diff0: signed (15 downto 0);
    signal diff1: signed (15 downto 0);
    signal max_diff0: signed (15 downto 0);
    signal max_diff1: signed (15 downto 0);
    signal clk, rst         : STD_LOGIC;  


    component approximate_lut6_mult is
        generic(REFINEMENT_PART : INTEGER:= 3;   -- which solution (part of partial products) to be used for accuracy refinement
                INOUT_BUF_EN : BOOLEAN:= True);
        Port ( a_i : in STD_LOGIC_VECTOR(7 downto 0);  -- Mult input 1
               b_i : in STD_LOGIC_VECTOR(7 downto 0);  -- Mult input 2
               clk, rst : in STD_LOGIC;
               result_o : out STD_LOGIC_VECTOR (10 downto 0)
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
        variable result_normalized0  : integer := 0;
        variable result_normalized1  : integer := 0;
        variable result_temp         : signed(15 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                a_count <= (others => '0');
                b_count <= (others => '0');
                result0(3 downto 0) <= (others => '0');
                result1(3 downto 0) <= (others => '0');
                result_temp := (others => '0');
                max_diff0 <= (others => '0');
                max_diff1 <= (others => '0');
            else
                result_normalized0 := conv_integer(result_signed0) ;
                result_normalized1 := conv_integer(result_signed1) ;
                if result_exact >= result_normalized0 then
                    diff0 <= result_exact - result_normalized0;
                else
                    diff0 <= result_normalized0 - result_exact;
                end if;
                if diff0 > max_diff0 then
                    max_diff0 <= diff0;
                end if;
                if result_exact >= result_normalized1 then
                    diff1 <= result_exact - result_normalized1;
                else
                    diff1 <= result_normalized1 - result_exact;
                end if;
                if diff1 > max_diff1 then
                    max_diff1 <= diff1;
                end if;
                result_exact <= result_temp;
                result_temp := signed(a_count) * signed(b_count);
                if (conv_integer(a_count) = 2**BITWIDTH-1) then
                    a_count <= (others => '0');
                    if (conv_integer(b_count) = 2**BITWIDTH-1) then
                        finish;
                    else
                        b_count <= b_count + 1;
                        a_count <= a_count + 1;
                    end if;
                else
                    a_count <= a_count + 1;
                end if;
            end if;
        end if;
    end process;


    MUL_INST_0: approximate_lut6_mult
        generic map (REFINEMENT_PART => 0,   -- which solution (part of partial products) to be used for accuracy refinement
                    INOUT_BUF_EN => True)
        Port map( a_i => std_logic_vector(a_count),  -- Mult input 1
               b_i => std_logic_vector(b_count),  -- Mult input 2
               clk => clk,
               rst => rst,
               result_o => result0(14 downto 4)
               );
               
        MUL_INST_1: approximate_lut6_mult
        generic map (REFINEMENT_PART => 1,   -- which solution (part of partial products) to be used for accuracy refinement
                    INOUT_BUF_EN => True)
        Port map( a_i => std_logic_vector(a_count),  -- Mult input 1
               b_i => std_logic_vector(b_count),  -- Mult input 2
               clk => clk,
               rst => rst,
               result_o => result1(14 downto 4)
               );

    result_signed0 <= signed(result0);
    result_signed1 <= signed(result1);

end Behavioral;