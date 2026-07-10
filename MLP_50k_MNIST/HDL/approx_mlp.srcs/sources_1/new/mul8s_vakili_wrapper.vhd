library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;


--undergoing evaluation REFINEMENT_PART
--        REFINEMENT_PART : integer := 0; -- default
--undergoing evaluation
entity mul8s_vakili_wrapper is
    generic (
        REFINEMENT_PART : integer := 0; 
        INOUT_BUF_EN    : boolean := true
    );
    port (
        clk : in  std_logic;
        rst : in  std_logic;
        a   : in  signed(7 downto 0);
        b   : in  signed(7 downto 0);
        p   : out signed(15 downto 0)
    );
end entity;

architecture rtl of mul8s_vakili_wrapper is

    signal raw_result : std_logic_vector(10 downto 0);

begin

    u_vakili : entity work.approximate_lut6_mult
        generic map (
            REFINEMENT_PART => REFINEMENT_PART,
            INOUT_BUF_EN    => INOUT_BUF_EN
        )
        port map (
            a_i      => std_logic_vector(a),
            b_i      => std_logic_vector(b),
            clk      => clk,
            rst      => rst,
            result_o => raw_result
        );

    --------------------------------------------------------------------
    -- Corrected interpretation:
    --
    -- The Vakili module already forms its approximate product internally.
    -- Do not shift left by 5.
    --------------------------------------------------------------------
--    p <= resize(signed(raw_result), 16);
--    p <= signed(raw_result & "00000");
    p <= signed((resize(signed(raw_result), 12)) & "0000");

end architecture;