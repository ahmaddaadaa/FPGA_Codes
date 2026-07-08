library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package mlp_types_pkg is

    constant NUM_INPUTS  : integer := 4;
    constant NUM_HIDDEN  : integer := 2;
    constant NUM_OUTPUTS : integer := 2;

    constant NUM_WEIGHTS : integer := 12;
    constant NUM_BIASES  : integer := 4;

    subtype s8  is signed(7 downto 0);
    subtype s32 is signed(31 downto 0);

    type input_mem_t  is array (0 to NUM_INPUTS - 1) of s8;
    type weight_mem_t is array (0 to NUM_WEIGHTS - 1) of s8;
    type bias_mem_t   is array (0 to NUM_BIASES - 1) of s32;
    type hidden_mem_t is array (0 to NUM_HIDDEN - 1) of s8;
    type output_mem_t is array (0 to NUM_OUTPUTS - 1) of s32;

end package;