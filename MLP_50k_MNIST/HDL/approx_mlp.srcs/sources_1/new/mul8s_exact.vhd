library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mul8s_exact is
    port (
        clk : in  std_logic;
        rst : in  std_logic;
        a   : in  signed(7 downto 0);
        b   : in  signed(7 downto 0);
        p   : out signed(15 downto 0)
    );
end entity;

architecture rtl of mul8s_exact is

    -- Force LUT implementation rather than DSP48.
    -- This better matches the comparison setup in the Vakili paper.
    attribute use_dsp : string;
    attribute use_dsp of rtl : architecture is "no";

begin

    -- Combinational exact multiplier.
    -- clk/rst are unused but kept for interface compatibility.
    p <= a * b;

end architecture;