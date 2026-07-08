library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package mlp_types_pkg is

    --------------------------------------------------------------------
    -- Current Step 1 test model: 4 -> 2 -> 2
    --------------------------------------------------------------------
    constant NUM_INPUTS  : integer := 4;
    constant NUM_HIDDEN  : integer := 2;
    constant NUM_OUTPUTS : integer := 2;

    constant NUM_WEIGHTS : integer := 12;
    constant NUM_BIASES  : integer := 4;

    --------------------------------------------------------------------
    -- Address widths for current model
    --
    -- input  depth = 4  -> 2 bits
    -- weight depth = 12 -> 4 bits
    -- bias   depth = 4  -> 2 bits
    --------------------------------------------------------------------
    constant INPUT_ADDR_WIDTH  : integer := 2;
    constant WEIGHT_ADDR_WIDTH : integer := 4;
    constant BIAS_ADDR_WIDTH   : integer := 2;

    subtype s8  is signed(7 downto 0);
    subtype s16 is signed(15 downto 0);
    subtype s32 is signed(31 downto 0);

end package;