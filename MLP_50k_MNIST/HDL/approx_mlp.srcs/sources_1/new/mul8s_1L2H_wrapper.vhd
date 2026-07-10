library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mul8s_1L2H_wrapper is
    port (
        clk : in  std_logic;
        rst : in  std_logic;
        a   : in  signed(7 downto 0);
        b   : in  signed(7 downto 0);
        p   : out signed(15 downto 0)
    );
end entity;

architecture rtl of mul8s_1L2H_wrapper is

    component mul8s_1L2H is
        port (
            A : in  std_logic_vector(7 downto 0);
            B : in  std_logic_vector(7 downto 0);
            O : out std_logic_vector(15 downto 0)
        );
    end component;

    signal product_slv : std_logic_vector(15 downto 0);

begin

    -- clk/rst are unused because mul8s_1L2H is combinational.
    -- They are kept only to match the common multiplier interface.

    u_mul8s_1L2H : mul8s_1L2H
        port map (
            A => std_logic_vector(a),
            B => std_logic_vector(b),
            O => product_slv
        );

    p <= signed(product_slv);

end architecture;