library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mul8s_approx_trunc is
    port (
        a : in  signed(7 downto 0);
        b : in  signed(7 downto 0);
        p : out signed(15 downto 0)
    );
end entity;

architecture rtl of mul8s_approx_trunc is
    signal exact_product : signed(15 downto 0);
begin

    exact_product <= a * b;

    -- Approximation: zero out lower 4 product bits
    p <= exact_product(15 downto 4) & "0000";

end architecture;