library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mlp_types_pkg.all;

-- Measurement top for the P16 accelerator, banked parameter/input memories,
-- and their adapter without a host transport. DONT_TOUCH keeps the complete
-- accelerator hierarchy present even though the write ports are tied off in
-- this resource-characterization image.
entity tiny_mlp_core_only_top is
    port (
        clk      : in std_logic;
        rst      : in std_logic;
        start    : in std_logic;
        led_busy : out std_logic;
        led_done : out std_logic
    );
end entity;

architecture rtl of tiny_mlp_core_only_top is
    signal mlp_busy : std_logic;
    signal mlp_done : std_logic;
    signal mlp_complete : std_logic;
    signal mlp_outputs : signed(NUM_OUTPUTS * 32 - 1 downto 0);

    attribute DONT_TOUCH : string;
    attribute KEEP_HIERARCHY : string;
    attribute DONT_TOUCH of u_accelerator : label is "TRUE";
    attribute KEEP_HIERARCHY of u_accelerator : label is "TRUE";
begin
    led_busy <= mlp_busy;
    led_done <= mlp_done;

    u_accelerator : entity work.tiny_mlp_accelerator_bram
        port map (
            clk => clk,
            rst => rst,
            start => start,
            input_we => '0',
            input_waddr => (others => '0'),
            input_wdata => (others => '0'),
            weight_we => '0',
            weight_waddr => (others => '0'),
            weight_wdata => (others => '0'),
            bias_we => '0',
            bias_waddr => (others => '0'),
            bias_wdata => (others => '0'),
            busy => mlp_busy,
            done => mlp_done,
            inference_complete => mlp_complete,
            outputs => mlp_outputs
        );
end architecture;
