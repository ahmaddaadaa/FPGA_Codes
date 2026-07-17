library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

use work.mlp_types_pkg.all;

entity tiny_mlp_uart_ethernet_top is
    generic (
        UART_CLKS_PER_BIT : integer := 100;
        PHY_RESET_CYCLES  : integer := 3000000
    );
    port (
        clk : in std_logic;
        rst : in std_logic;

        uart_rx_i : in std_logic;
        uart_tx_o : out std_logic;

        eth_rstn   : out std_logic;
        eth_refclk : out std_logic;
        eth_crsdv  : in std_logic;
        eth_rxerr  : in std_logic;
        eth_rxd    : in std_logic_vector(1 downto 0);
        eth_txen   : out std_logic;
        eth_txd    : out std_logic_vector(1 downto 0);

        led_busy : out std_logic;
        led_done : out std_logic
    );
end entity;

architecture rtl of tiny_mlp_uart_ethernet_top is
    signal rmii_phase : std_logic := '0';
    signal refclk_forward_level : std_logic;
    signal rmii_rx_ce : std_logic;
    signal rmii_tx_ce : std_logic;
    signal rmii_crsdv_input : std_logic := '0';
    signal rmii_rxerr_input : std_logic := '0';
    signal rmii_rxd_input : std_logic_vector(1 downto 0) := (others => '0');
    signal phy_reset_count : integer range 0 to PHY_RESET_CYCLES := 0;
    signal phy_ready : std_logic := '0';

    signal input_we    : std_logic;
    signal input_waddr : unsigned(INPUT_ADDR_WIDTH - 1 downto 0);
    signal input_wdata : signed(7 downto 0);
    signal weight_we    : std_logic;
    signal weight_waddr : unsigned(WEIGHT_ADDR_WIDTH - 1 downto 0);
    signal weight_wdata : signed(7 downto 0);
    signal ethernet_weight_we    : std_logic;
    signal ethernet_weight_waddr : unsigned(WEIGHT_ADDR_WIDTH - 1 downto 0);
    signal ethernet_weight_wdata : signed(7 downto 0);
    signal merged_weight_we    : std_logic;
    signal merged_weight_waddr : unsigned(WEIGHT_ADDR_WIDTH - 1 downto 0);
    signal merged_weight_wdata : signed(7 downto 0);
    signal bias_we    : std_logic;
    signal bias_waddr : unsigned(BIAS_ADDR_WIDTH - 1 downto 0);
    signal bias_wdata : signed(31 downto 0);
    signal ethernet_bias_we    : std_logic;
    signal ethernet_bias_waddr : unsigned(BIAS_ADDR_WIDTH - 1 downto 0);
    signal ethernet_bias_wdata : signed(31 downto 0);
    signal merged_bias_we    : std_logic;
    signal merged_bias_waddr : unsigned(BIAS_ADDR_WIDTH - 1 downto 0);
    signal merged_bias_wdata : signed(31 downto 0);

    signal mlp_start : std_logic;
    signal mlp_busy : std_logic;
    signal mlp_done : std_logic;
    signal mlp_complete : std_logic;
    signal mlp_outputs : signed(NUM_OUTPUTS * 32 - 1 downto 0);
    signal ethernet_reset : std_logic;
    signal activity_pulse : std_logic;
    signal error_pulse : std_logic;
    signal ethernet_diagnostics : std_logic_vector(383 downto 0);
begin
    led_busy <= mlp_busy;
    led_done <= mlp_done;
    eth_rstn <= phy_ready;
    ethernet_reset <= rst or not phy_ready;
    merged_weight_we <= weight_we or ethernet_weight_we;
    merged_weight_waddr <= ethernet_weight_waddr
        when ethernet_weight_we = '1' else weight_waddr;
    merged_weight_wdata <= ethernet_weight_wdata
        when ethernet_weight_we = '1' else weight_wdata;
    merged_bias_we <= bias_we or ethernet_bias_we;
    merged_bias_waddr <= ethernet_bias_waddr
        when ethernet_bias_we = '1' else bias_waddr;
    merged_bias_wdata <= ethernet_bias_wdata
        when ethernet_bias_we = '1' else bias_wdata;

    -- The PHY receives a continuous 50 MHz reference derived from the board's
    -- 100 MHz oscillator.  RX is sampled on each rising reference-clock edge;
    -- TX changes on the intervening falling edge, providing 10 ns setup.
    rmii_rx_ce <= not rmii_phase;
    rmii_tx_ce <= rmii_phase;
    refclk_forward_level <= not rmii_phase;

    -- Use the dedicated output DDR register for a low-skew 50 MHz forwarded
    -- clock. D1=D2 holds each divided-clock level for a complete 100 MHz
    -- cycle; the level alternates on successive rising edges.
    u_refclk_forward : ODDR
        generic map (
            DDR_CLK_EDGE => "SAME_EDGE"
        )
        port map (
            Q => eth_refclk,
            C => clk,
            CE => '1',
            D1 => refclk_forward_level,
            D2 => refclk_forward_level,
            R => rst,
            S => '0'
        );

    clock_and_phy_reset : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rmii_phase <= '0';
                phy_reset_count <= 0;
                phy_ready <= '0';
            else
                rmii_phase <= not rmii_phase;
                if phy_reset_count < PHY_RESET_CYCLES then
                    phy_reset_count <= phy_reset_count + 1;
                    phy_ready <= '0';
                else
                    phy_ready <= '1';
                end if;
            end if;
        end if;
    end process;

    -- Capture one RMII dibit every 20 ns. The endpoint consumes the previous
    -- capture on the same enable edge, adding one harmless dibit of latency
    -- while keeping raw PHY inputs out of the packet parser's combinational
    -- logic. XDC keeps these first-stage registers in fabric because packing
    -- them into this HR bank inserts a large ZHOLD_DELAY element.
    rmii_input_registers : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rmii_crsdv_input <= '0';
                rmii_rxerr_input <= '0';
                rmii_rxd_input <= (others => '0');
            elsif rmii_rx_ce = '1' then
                rmii_crsdv_input <= eth_crsdv;
                rmii_rxerr_input <= eth_rxerr;
                rmii_rxd_input <= eth_rxd;
            end if;
        end if;
    end process;

    u_parameter_loader : entity work.uart_parameter_loader
        generic map (
            CLKS_PER_BIT => UART_CLKS_PER_BIT,
            WEIGHT_ADDRESS_LIMIT => 52736
        )
        port map (
            clk => clk,
            rst => rst,
            uart_rx_i => uart_rx_i,
            uart_tx_o => uart_tx_o,
            core_busy => mlp_busy,
            debug_diagnostics => ethernet_diagnostics,
            weight_we => weight_we,
            weight_waddr => weight_waddr,
            weight_wdata => weight_wdata,
            bias_we => bias_we,
            bias_waddr => bias_waddr,
            bias_wdata => bias_wdata
        );

    u_ethernet : entity work.vakili_udp_rmii_endpoint
        generic map (
            BOARD_MAC => x"020000000702",
            BOARD_IP => x"C0A80702",
            UDP_PORT => 5005
        )
        port map (
            clk => clk,
            rst => ethernet_reset,
            rmii_rx_ce => rmii_rx_ce,
            rmii_tx_ce => rmii_tx_ce,
            eth_crsdv => rmii_crsdv_input,
            eth_rxerr => rmii_rxerr_input,
            eth_rxd => rmii_rxd_input,
            eth_txen => eth_txen,
            eth_txd => eth_txd,
            input_we => input_we,
            input_waddr => input_waddr,
            input_wdata => input_wdata,
            weight_we => ethernet_weight_we,
            weight_waddr => ethernet_weight_waddr,
            weight_wdata => ethernet_weight_wdata,
            bias_we => ethernet_bias_we,
            bias_waddr => ethernet_bias_waddr,
            bias_wdata => ethernet_bias_wdata,
            mlp_start => mlp_start,
            mlp_busy => mlp_busy,
            mlp_complete => mlp_complete,
            mlp_outputs => mlp_outputs,
            activity_pulse => activity_pulse,
            error_pulse => error_pulse,
            debug_diagnostics => ethernet_diagnostics
        );

    u_mlp : entity work.tiny_mlp_accelerator_bram
        port map (
            clk => clk,
            rst => rst,
            start => mlp_start,
            input_we => input_we,
            input_waddr => input_waddr,
            input_wdata => input_wdata,
            weight_we => merged_weight_we,
            weight_waddr => merged_weight_waddr,
            weight_wdata => merged_weight_wdata,
            bias_we => merged_bias_we,
            bias_waddr => merged_bias_waddr,
            bias_wdata => merged_bias_wdata,
            busy => mlp_busy,
            done => mlp_done,
            inference_complete => mlp_complete,
            outputs => mlp_outputs
        );
end architecture;
