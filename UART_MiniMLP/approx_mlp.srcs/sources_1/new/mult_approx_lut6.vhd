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
--  Edge Computing, Communication and Learning Lab (ECCoLe) 
--
--  Author: Shervin Vakili, INRS University
--  Project: Baugh-Wooley Segmented Approximate Multiplier
--  Creation Date: 2023-11-16
--  Module Name: approximate_mult - Behavioral 
--  Description: Approximate signed multiplier based of four 3x3 segmented multiplication and 
--               Baugh-Wooley algorithm.
--  See ECCoLe_LICENSE
---------------------------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
--use IEEE.STD_LOGIC_SIGNED.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.std_logic_arith.ALL;
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity approximate_lut6_mult is
    generic(REFINEMENT_PART : INTEGER:= 0;   -- which solution (part of partial products) to be used for accuracy refinement
            INOUT_BUF_EN : BOOLEAN:= True);
    Port ( a_i : in STD_LOGIC_VECTOR(7 downto 0);  -- Mult input 1
           b_i : in STD_LOGIC_VECTOR(7 downto 0);  -- Mult input 2
           clk, rst : in STD_LOGIC;
           result_o : out STD_LOGIC_VECTOR (10 downto 0)
           );
end approximate_lut6_mult;

architecture Behavioral of approximate_lut6_mult is
    signal a            : STD_LOGIC_VECTOR(7 downto 0);
    signal b            : STD_LOGIC_VECTOR(7 downto 0);
    signal result_temp  : STD_LOGIC_VECTOR(10 downto 0);  -- Mult input 2
    signal ps1_term1    : STD_LOGIC_VECTOR(4 downto 0);
    signal ps1_term2    : STD_LOGIC_VECTOR(4 downto 0);
    signal ps1_term3    : STD_LOGIC_VECTOR(4 downto 0);
    signal ps1          : STD_LOGIC_VECTOR(4 downto 0);
    signal ps2_term1    : STD_LOGIC_VECTOR(5 downto 0);
    signal ps2_term2    : STD_LOGIC_VECTOR(5 downto 0);
    signal ps2_term3    : STD_LOGIC_VECTOR(5 downto 0);
    signal ps2          : STD_LOGIC_VECTOR(5 downto 0);
    signal ps3_term1    : STD_LOGIC_VECTOR(5 downto 0);
    signal ps3_term2    : STD_LOGIC_VECTOR(5 downto 0);
    signal ps3_term3    : STD_LOGIC_VECTOR(5 downto 0);
    signal ps3          : STD_LOGIC_VECTOR(5 downto 0);
    signal ps4_term1    : STD_LOGIC_VECTOR(5 downto 0);
    signal ps4_term2    : STD_LOGIC_VECTOR(5 downto 0);
    signal ps4_term3    : STD_LOGIC_VECTOR(5 downto 0);
    --signal ps4_term4    : STD_LOGIC_VECTOR(5 downto 0);
    signal ps4          : STD_LOGIC_VECTOR(5 downto 0);

    signal ps5_term1    : STD_LOGIC_VECTOR(2 downto 0);
    signal ps5_term2    : STD_LOGIC_VECTOR(2 downto 0);
    signal ps5          : STD_LOGIC_VECTOR(2 downto 0);

begin
    --result_o <= a + b + c;
    process(clk)
    begin
        if (rising_edge(clk)) then
            if rst = '1' then
                a <= (others => '0');
                b <= (others => '0');
                result_o <= (others => '0');
            else
                a <= a_i;
                b <= b_i;
                result_o <= result_temp;
            end if;
        end if;
    end process;

    -- PS1
    ps1_term1   <= ("00" & not(a(5) and b(7)) & (a(5) and b(6)) & (a(5) and b(5))       );
    ps1_term2   <= ('0'  & not(a(6) and b(7)) & (a(6) and b(6)) & (a(6) and b(5)) & '0' );
    ps1_term3   <= ( (a(7) and b(7)) & not(a(7) and b(6)) & not(a(7) and b(5))    & "00");
    ps1         <= ps1_term1 + ps1_term2 + ps1_term3 ;

    --PS2
    ps2_term1   <= ("000" & not(a(2) and b(7)) & (a(2) and b(6)) & (a(2) and b(5))       );
    ps2_term2   <= ("00"  & not(a(3) and b(7)) & (a(3) and b(6)) & (a(3) and b(5)) & '0' );
    ps2_term3   <= ('0'   & not(a(4) and b(7)) & (a(4) and b(6)) & (a(4) and b(5)) & "00");
    ps2         <= ps2_term1 + ps2_term2 + ps2_term3 + "001000";

    --PS3
    ps3_term1   <= ("000" & (a(5) and b(4)) & (a(5) and b(3)) & (a(5) and b(2))         );
    ps3_term2   <= ("00"  & (a(6) and b(4)) & (a(6) and b(3)) & (a(6) and b(2)) & '0'   );
    ps3_term3   <= ('0'   & not(a(7) and b(4)) & not(a(7) and b(3)) & not(a(7) and b(2)) & "00"  );
    ps3         <= ps3_term1 + ps3_term2 + ps3_term3;

    --PS4
    ps4_term1   <= ("000" & (a(2) and b(4)) & (a(2) and b(3)) & (a(2) and b(2)));
    ps4_term2   <= ("00"  & (a(3) and b(4)) & (a(3) and b(3)) & (a(3) and b(2)) & '0'   );
    ps4_term3   <= ('0'   & (a(4) and b(4)) & (a(4) and b(3)) & (a(4) and b(2)) & "00"  );
    ps4         <= ps4_term1 + ps4_term2 + ps4_term3;

    --PS4
    PS5_0: if REFINEMENT_PART = 0 generate
        ps5 <= (others => '0');
    end generate;
    PS5_1: if REFINEMENT_PART = 1 generate
        ps5_term1   <= ('0' & (a(1) and b(6)) & (a(1) and b(5)) );
        ps5_term2   <= ('0'  & (a(6) and b(1)) & (a(6) and b(0)) );
        ps5         <= ps5_term1 + ps5_term2;
    end generate;
    
    
    result_temp <= (ps1 & "000000") + ("00" & ps2 & "000") + ("00" & ps3 & "000") + ("00000" & ps4) + ("000000" & ps5 & "00");


    end Behavioral;