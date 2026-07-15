library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mlp_types_pkg.all;

-- Adapter from the UART loader's hardware-native address to the sixteen P16
-- weight memories exposed by the Vitis HLS Vakili-R1 core.  The 16-bit wire
-- address is {bank_address[11:0], lane[3:0]}; the host converts ordinary
-- output-major w1/w2/w3 tensors into this layout before upload.
entity tiny_mlp_accelerator_bram is
    port (
        clk   : in std_logic;
        rst   : in std_logic;
        start : in std_logic;

        input_we    : in std_logic;
        input_waddr : in unsigned(INPUT_ADDR_WIDTH - 1 downto 0);
        input_wdata : in signed(7 downto 0);

        weight_we    : in std_logic;
        weight_waddr : in unsigned(WEIGHT_ADDR_WIDTH - 1 downto 0);
        weight_wdata : in signed(7 downto 0);

        bias_we    : in std_logic;
        bias_waddr : in unsigned(BIAS_ADDR_WIDTH - 1 downto 0);
        bias_wdata : in signed(31 downto 0);

        busy : out std_logic;
        done : out std_logic;
        inference_complete : out std_logic;

        outputs : out signed(NUM_OUTPUTS * 32 - 1 downto 0)
    );
end entity;

architecture rtl of tiny_mlp_accelerator_bram is

    constant P16_LANES             : integer := 16;
    constant WEIGHT_BANK_DEPTH     : integer := 3296;
    constant WEIGHT_BANK_ADDR_BITS : integer := 12;

    type sl_array_t is array (0 to P16_LANES - 1) of std_logic;
    type u12_array_t is array (0 to P16_LANES - 1) of
        unsigned(WEIGHT_BANK_ADDR_BITS - 1 downto 0);
    type slv12_array_t is array (0 to P16_LANES - 1) of
        std_logic_vector(WEIGHT_BANK_ADDR_BITS - 1 downto 0);
    type s8_array_t is array (0 to P16_LANES - 1) of signed(7 downto 0);
    type slv8_array_t is array (0 to P16_LANES - 1) of
        std_logic_vector(7 downto 0);
    type output_mem_t is array (0 to NUM_OUTPUTS - 1) of signed(31 downto 0);

    component vakili_r1_p16_top is
        port (
            ap_clk   : in  std_logic;
            ap_rst   : in  std_logic;
            ap_start : in  std_logic;
            ap_done  : out std_logic;
            ap_idle  : out std_logic;
            ap_ready : out std_logic;

            input_r_address0 : out std_logic_vector(9 downto 0);
            input_r_ce0      : out std_logic;
            input_r_q0       : in  std_logic_vector(7 downto 0);

            weights_0_address0  : out std_logic_vector(11 downto 0);
            weights_0_ce0       : out std_logic;
            weights_0_q0        : in  std_logic_vector(7 downto 0);
            weights_1_address0  : out std_logic_vector(11 downto 0);
            weights_1_ce0       : out std_logic;
            weights_1_q0        : in  std_logic_vector(7 downto 0);
            weights_2_address0  : out std_logic_vector(11 downto 0);
            weights_2_ce0       : out std_logic;
            weights_2_q0        : in  std_logic_vector(7 downto 0);
            weights_3_address0  : out std_logic_vector(11 downto 0);
            weights_3_ce0       : out std_logic;
            weights_3_q0        : in  std_logic_vector(7 downto 0);
            weights_4_address0  : out std_logic_vector(11 downto 0);
            weights_4_ce0       : out std_logic;
            weights_4_q0        : in  std_logic_vector(7 downto 0);
            weights_5_address0  : out std_logic_vector(11 downto 0);
            weights_5_ce0       : out std_logic;
            weights_5_q0        : in  std_logic_vector(7 downto 0);
            weights_6_address0  : out std_logic_vector(11 downto 0);
            weights_6_ce0       : out std_logic;
            weights_6_q0        : in  std_logic_vector(7 downto 0);
            weights_7_address0  : out std_logic_vector(11 downto 0);
            weights_7_ce0       : out std_logic;
            weights_7_q0        : in  std_logic_vector(7 downto 0);
            weights_8_address0  : out std_logic_vector(11 downto 0);
            weights_8_ce0       : out std_logic;
            weights_8_q0        : in  std_logic_vector(7 downto 0);
            weights_9_address0  : out std_logic_vector(11 downto 0);
            weights_9_ce0       : out std_logic;
            weights_9_q0        : in  std_logic_vector(7 downto 0);
            weights_10_address0 : out std_logic_vector(11 downto 0);
            weights_10_ce0      : out std_logic;
            weights_10_q0       : in  std_logic_vector(7 downto 0);
            weights_11_address0 : out std_logic_vector(11 downto 0);
            weights_11_ce0      : out std_logic;
            weights_11_q0       : in  std_logic_vector(7 downto 0);
            weights_12_address0 : out std_logic_vector(11 downto 0);
            weights_12_ce0      : out std_logic;
            weights_12_q0       : in  std_logic_vector(7 downto 0);
            weights_13_address0 : out std_logic_vector(11 downto 0);
            weights_13_ce0      : out std_logic;
            weights_13_q0       : in  std_logic_vector(7 downto 0);
            weights_14_address0 : out std_logic_vector(11 downto 0);
            weights_14_ce0      : out std_logic;
            weights_14_q0       : in  std_logic_vector(7 downto 0);
            weights_15_address0 : out std_logic_vector(11 downto 0);
            weights_15_ce0      : out std_logic;
            weights_15_q0       : in  std_logic_vector(7 downto 0);

            biases_address0 : out std_logic_vector(6 downto 0);
            biases_ce0      : out std_logic;
            biases_q0       : in  std_logic_vector(31 downto 0);
            biases_address1 : out std_logic_vector(6 downto 0);
            biases_ce1      : out std_logic;
            biases_q1       : in  std_logic_vector(31 downto 0);

            outputs_address0 : out std_logic_vector(3 downto 0);
            outputs_ce0      : out std_logic;
            outputs_we0      : out std_logic;
            outputs_d0       : out std_logic_vector(31 downto 0);
            outputs_address1 : out std_logic_vector(3 downto 0);
            outputs_ce1      : out std_logic;
            outputs_we1      : out std_logic;
            outputs_d1       : out std_logic_vector(31 downto 0)
        );
    end component;

    -- ap_ctrl_hs requires ap_start to remain asserted until ap_ready accepts
    -- it.  The transport-facing start input is only a one-cycle event, so
    -- latch it here rather than relying on the HLS core sampling that pulse.
    signal hls_start : std_logic := '0';
    signal start_pending : std_logic := '0';
    signal hls_done  : std_logic;
    signal hls_idle  : std_logic;
    signal hls_ready : std_logic;

    signal input_r_address0 : std_logic_vector(9 downto 0);
    signal input_r_ce0      : std_logic;
    signal input_rdata      : signed(7 downto 0);

    signal weight_bank_we    : sl_array_t := (others => '0');
    signal weight_bank_waddr : u12_array_t := (others => (others => '0'));
    signal weight_bank_raddr : slv12_array_t;
    signal weight_bank_ce    : sl_array_t;
    signal weight_bank_rdata : s8_array_t;
    signal weight_bank_q     : slv8_array_t;

    signal biases_address0 : std_logic_vector(6 downto 0);
    signal biases_ce0      : std_logic;
    signal biases_rdata0   : signed(31 downto 0);
    signal biases_address1 : std_logic_vector(6 downto 0);
    signal biases_ce1      : std_logic;
    signal biases_rdata1   : signed(31 downto 0);

    signal outputs_address0 : std_logic_vector(3 downto 0);
    signal outputs_ce0      : std_logic;
    signal outputs_we0      : std_logic;
    signal outputs_d0       : std_logic_vector(31 downto 0);
    signal outputs_address1 : std_logic_vector(3 downto 0);
    signal outputs_ce1      : std_logic;
    signal outputs_we1      : std_logic;
    signal outputs_d1       : std_logic_vector(31 downto 0);

    signal output_mem : output_mem_t := (others => (others => '0'));
    signal busy_reg   : std_logic := '0';
    signal done_reg   : std_logic := '0';
    signal complete_reg : std_logic := '0';

begin

    busy <= busy_reg;
    done <= done_reg;
    inference_complete <= complete_reg;
    -- ap_ready is inactive until an ap_ctrl_hs transaction is under way.  It
    -- masks ap_start in the acceptance cycle so a non-pipelined core cannot
    -- interpret the still-registered pending bit as an automatic restart.
    hls_start <= start_pending and not hls_ready;
    -- Decode the hardware-native wire address.  This is intentionally only
    -- wiring plus a one-hot lane select: the previous flat-tensor decoder used
    -- constant division/modulo and produced a 21-level post-route path.
    bank_write_decode : process(weight_we, weight_waddr)
        variable lane_idx  : integer;
        variable bank_addr : integer;
    begin
        weight_bank_we <= (others => '0');
        weight_bank_waddr <= (others => (others => '0'));

        lane_idx := to_integer(weight_waddr(3 downto 0));
        bank_addr := to_integer(
            weight_waddr(WEIGHT_ADDR_WIDTH - 1 downto 4)
        );

        if weight_we = '1' and
           lane_idx >= 0 and lane_idx < P16_LANES and
           bank_addr >= 0 and bank_addr < WEIGHT_BANK_DEPTH then
            weight_bank_we(lane_idx) <= '1';
            weight_bank_waddr(lane_idx) <= to_unsigned(
                bank_addr, WEIGHT_BANK_ADDR_BITS
            );
        end if;
    end process;

    u_input_ram : entity work.sync_ram_s8
        generic map (
            DEPTH      => NUM_INPUTS,
            ADDR_WIDTH => INPUT_ADDR_WIDTH
        )
        port map (
            clk   => clk,
            we    => input_we,
            waddr => input_waddr,
            wdata => input_wdata,
            raddr => unsigned(input_r_address0),
            rdata => input_rdata
        );

    weight_banks : for lane in 0 to P16_LANES - 1 generate
        weight_bank_q(lane) <= std_logic_vector(weight_bank_rdata(lane));

        u_weight_ram : entity work.sync_ram_s8
            generic map (
                DEPTH      => WEIGHT_BANK_DEPTH,
                ADDR_WIDTH => WEIGHT_BANK_ADDR_BITS
            )
            port map (
                clk   => clk,
                we    => weight_bank_we(lane),
                waddr => weight_bank_waddr(lane),
                wdata => weight_wdata,
                raddr => unsigned(weight_bank_raddr(lane)),
                rdata => weight_bank_rdata(lane)
            );
    end generate;

    -- Replicate the small bias memory because HLS requests two independent
    -- synchronous reads.  UART writes update both copies identically.
    u_bias_ram0 : entity work.sync_ram_s32
        generic map (DEPTH => NUM_BIASES, ADDR_WIDTH => BIAS_ADDR_WIDTH)
        port map (
            clk => clk, we => bias_we, waddr => bias_waddr, wdata => bias_wdata,
            raddr => unsigned(biases_address0), rdata => biases_rdata0
        );

    u_bias_ram1 : entity work.sync_ram_s32
        generic map (DEPTH => NUM_BIASES, ADDR_WIDTH => BIAS_ADDR_WIDTH)
        port map (
            clk => clk, we => bias_we, waddr => bias_waddr, wdata => bias_wdata,
            raddr => unsigned(biases_address1), rdata => biases_rdata1
        );

    u_hls_core : vakili_r1_p16_top
        port map (
            ap_clk => clk, ap_rst => rst, ap_start => hls_start,
            ap_done => hls_done, ap_idle => hls_idle, ap_ready => hls_ready,

            input_r_address0 => input_r_address0,
            input_r_ce0 => input_r_ce0,
            input_r_q0 => std_logic_vector(input_rdata),

            weights_0_address0 => weight_bank_raddr(0), weights_0_ce0 => weight_bank_ce(0), weights_0_q0 => weight_bank_q(0),
            weights_1_address0 => weight_bank_raddr(1), weights_1_ce0 => weight_bank_ce(1), weights_1_q0 => weight_bank_q(1),
            weights_2_address0 => weight_bank_raddr(2), weights_2_ce0 => weight_bank_ce(2), weights_2_q0 => weight_bank_q(2),
            weights_3_address0 => weight_bank_raddr(3), weights_3_ce0 => weight_bank_ce(3), weights_3_q0 => weight_bank_q(3),
            weights_4_address0 => weight_bank_raddr(4), weights_4_ce0 => weight_bank_ce(4), weights_4_q0 => weight_bank_q(4),
            weights_5_address0 => weight_bank_raddr(5), weights_5_ce0 => weight_bank_ce(5), weights_5_q0 => weight_bank_q(5),
            weights_6_address0 => weight_bank_raddr(6), weights_6_ce0 => weight_bank_ce(6), weights_6_q0 => weight_bank_q(6),
            weights_7_address0 => weight_bank_raddr(7), weights_7_ce0 => weight_bank_ce(7), weights_7_q0 => weight_bank_q(7),
            weights_8_address0 => weight_bank_raddr(8), weights_8_ce0 => weight_bank_ce(8), weights_8_q0 => weight_bank_q(8),
            weights_9_address0 => weight_bank_raddr(9), weights_9_ce0 => weight_bank_ce(9), weights_9_q0 => weight_bank_q(9),
            weights_10_address0 => weight_bank_raddr(10), weights_10_ce0 => weight_bank_ce(10), weights_10_q0 => weight_bank_q(10),
            weights_11_address0 => weight_bank_raddr(11), weights_11_ce0 => weight_bank_ce(11), weights_11_q0 => weight_bank_q(11),
            weights_12_address0 => weight_bank_raddr(12), weights_12_ce0 => weight_bank_ce(12), weights_12_q0 => weight_bank_q(12),
            weights_13_address0 => weight_bank_raddr(13), weights_13_ce0 => weight_bank_ce(13), weights_13_q0 => weight_bank_q(13),
            weights_14_address0 => weight_bank_raddr(14), weights_14_ce0 => weight_bank_ce(14), weights_14_q0 => weight_bank_q(14),
            weights_15_address0 => weight_bank_raddr(15), weights_15_ce0 => weight_bank_ce(15), weights_15_q0 => weight_bank_q(15),

            biases_address0 => biases_address0,
            biases_ce0 => biases_ce0,
            biases_q0 => std_logic_vector(biases_rdata0),
            biases_address1 => biases_address1,
            biases_ce1 => biases_ce1,
            biases_q1 => std_logic_vector(biases_rdata1),

            outputs_address0 => outputs_address0,
            outputs_ce0 => outputs_ce0,
            outputs_we0 => outputs_we0,
            outputs_d0 => outputs_d0,
            outputs_address1 => outputs_address1,
            outputs_ce1 => outputs_ce1,
            outputs_we1 => outputs_we1,
            outputs_d1 => outputs_d1
        );

    control_and_outputs : process(clk)
        variable output_index : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                start_pending <= '0';
                busy_reg <= '0';
                done_reg <= '0';
                complete_reg <= '0';
                output_mem <= (others => (others => '0'));
            else
                -- Dedicated one-cycle completion event for non-polling
                -- transports. done_reg deliberately remains sticky for the
                -- legacy UART STATUS command until the next start.
                complete_reg <= '0';

                if start_pending = '1' and hls_ready = '1' then
                    start_pending <= '0';
                end if;

                -- Capture a transport request even if ap_ready is not high
                -- on that exact clock.  If ap_ready is already high, the
                -- assignment below deliberately wins for this clock and the
                -- HLS core observes ap_start on the following clock.
                if start = '1' and busy_reg = '0' and
                   start_pending = '0' then
                    start_pending <= '1';
                    busy_reg <= '1';
                    done_reg <= '0';
                end if;

                if outputs_ce0 = '1' and outputs_we0 = '1' then
                    output_index := to_integer(unsigned(outputs_address0));
                    if output_index >= 0 and output_index < NUM_OUTPUTS then
                        output_mem(output_index) <= signed(outputs_d0);
                    end if;
                end if;

                if outputs_ce1 = '1' and outputs_we1 = '1' then
                    output_index := to_integer(unsigned(outputs_address1));
                    if output_index >= 0 and output_index < NUM_OUTPUTS then
                        output_mem(output_index) <= signed(outputs_d1);
                    end if;
                end if;

                if hls_done = '1' then
                    busy_reg <= '0';
                    done_reg <= '1';
                    complete_reg <= '1';
                end if;
            end if;
        end if;
    end process;

    pack_outputs : for index in 0 to NUM_OUTPUTS - 1 generate
        outputs((index + 1) * 32 - 1 downto index * 32) <= output_mem(index);
    end generate;

end architecture;
