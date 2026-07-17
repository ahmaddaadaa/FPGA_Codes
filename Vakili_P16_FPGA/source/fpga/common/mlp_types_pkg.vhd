library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package mlp_types_pkg is

    --------------------------------------------------------------------
    -- MNIST-scale target model: 784 -> 64 -> 32 -> 10
    --------------------------------------------------------------------
    constant NUM_INPUTS  : integer := 784;
    constant NUM_HIDDEN1 : integer := 64;
    constant NUM_HIDDEN2 : integer := 32;
    constant NUM_OUTPUTS : integer := 10;

    constant W1_BASE : integer := 0;
    constant W2_BASE : integer := NUM_INPUTS * NUM_HIDDEN1;
    constant W3_BASE : integer := W2_BASE + NUM_HIDDEN1 * NUM_HIDDEN2;

    constant NUM_WEIGHTS : integer :=
        NUM_INPUTS * NUM_HIDDEN1 +
        NUM_HIDDEN1 * NUM_HIDDEN2 +
        NUM_HIDDEN2 * NUM_OUTPUTS;

    constant B1_BASE : integer := 0;
    constant B2_BASE : integer := NUM_HIDDEN1;
    constant B3_BASE : integer := NUM_HIDDEN1 + NUM_HIDDEN2;

    constant NUM_BIASES : integer :=
        NUM_HIDDEN1 + NUM_HIDDEN2 + NUM_OUTPUTS;

    --------------------------------------------------------------------
    -- Address widths
    --------------------------------------------------------------------
    constant INPUT_ADDR_WIDTH  : integer := 10; -- 784 inputs
    constant WEIGHT_ADDR_WIDTH : integer := 16; -- 52544 weights
    constant BIAS_ADDR_WIDTH   : integer := 7;  -- 106 biases

    subtype s8  is signed(7 downto 0);
    subtype s16 is signed(15 downto 0);
    subtype s32 is signed(31 downto 0);

end package;
