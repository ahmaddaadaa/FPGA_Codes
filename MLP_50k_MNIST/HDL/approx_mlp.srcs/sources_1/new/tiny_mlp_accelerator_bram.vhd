library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mlp_types_pkg.all;

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

        outputs : out signed(NUM_OUTPUTS * 32 - 1 downto 0)
    );
end entity;

architecture rtl of tiny_mlp_accelerator_bram is

    type state_t is (
        IDLE,

        INIT_L1_SET_BIAS,
        INIT_L1_WAIT_BIAS,
        INIT_L1_LOAD_BIAS,
        SET_ADDR_L1,
        WAIT_DATA_L1,
        LOAD_MUL_L1,
        WAIT_MUL_L1_A,
        WAIT_MUL_L1_B,
        ACCUM_L1,
        STORE_HIDDEN1,

        INIT_L2_SET_BIAS,
        INIT_L2_WAIT_BIAS,
        INIT_L2_LOAD_BIAS,
        SET_ADDR_L2,
        WAIT_DATA_L2,
        LOAD_MUL_L2,
        WAIT_MUL_L2_A,
        WAIT_MUL_L2_B,
        ACCUM_L2,
        STORE_HIDDEN2,

        INIT_L3_SET_BIAS,
        INIT_L3_WAIT_BIAS,
        INIT_L3_LOAD_BIAS,
        SET_ADDR_L3,
        WAIT_DATA_L3,
        LOAD_MUL_L3,
        WAIT_MUL_L3_A,
        WAIT_MUL_L3_B,
        ACCUM_L3,
        STORE_OUTPUT,

        FINISH
    );

    signal state : state_t := IDLE;

    signal input_raddr  : unsigned(INPUT_ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal input_rdata  : signed(7 downto 0);

    signal weight_raddr : unsigned(WEIGHT_ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal weight_rdata : signed(7 downto 0);

    signal bias_raddr   : unsigned(BIAS_ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal bias_rdata   : signed(31 downto 0);

    type hidden1_t is array (0 to NUM_HIDDEN1 - 1) of signed(7 downto 0);
    type hidden2_t is array (0 to NUM_HIDDEN2 - 1) of signed(7 downto 0);

    signal hidden1 : hidden1_t := (others => (others => '0'));
    signal hidden2 : hidden2_t := (others => (others => '0'));

    signal outputs_reg : signed(NUM_OUTPUTS * 32 - 1 downto 0) := (others => '0');

    signal input_idx   : integer range 0 to NUM_INPUTS - 1 := 0;
    signal hidden1_idx : integer range 0 to NUM_HIDDEN1 - 1 := 0;
    signal hidden2_idx : integer range 0 to NUM_HIDDEN2 - 1 := 0;
    signal output_idx  : integer range 0 to NUM_OUTPUTS - 1 := 0;

    signal mac_a       : signed(7 downto 0)  := (others => '0');
    signal mac_b       : signed(7 downto 0)  := (others => '0');
    signal product     : signed(15 downto 0) := (others => '0');
    signal product_reg : signed(15 downto 0) := (others => '0');

    signal acc : signed(31 downto 0) := (others => '0');

    signal busy_reg : std_logic := '0';
    signal done_reg : std_logic := '0';
    
-- (exact)
--    constant HIDDEN1_SCALE_SHIFT : integer := 0;
--    constant HIDDEN2_SCALE_SHIFT : integer := 0;


--  for mul8s_1L2H
    constant HIDDEN1_SCALE_SHIFT : integer := 3;
    constant HIDDEN2_SCALE_SHIFT : integer := 8;
    
    --  for Vakili
--    constant HIDDEN1_SCALE_SHIFT : integer := 3;
--    constant HIDDEN2_SCALE_SHIFT : integer := 9;

    function relu_clip_s8(
        x     : signed(31 downto 0);
        shift : integer
    ) return signed is
        variable y : signed(31 downto 0);
    begin
        if x < to_signed(0, 32) then
            return to_signed(0, 8);
        else
            y := shift_right(x, shift);

            if y > to_signed(127, 32) then
                return to_signed(127, 8);
            else
                return resize(y, 8);
            end if;
        end if;
    end function;

begin

    busy <= busy_reg;
    done <= done_reg;

    outputs <= outputs_reg;

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
            raddr => input_raddr,
            rdata => input_rdata
        );

    u_weight_ram : entity work.sync_ram_s8
        generic map (
            DEPTH      => NUM_WEIGHTS,
            ADDR_WIDTH => WEIGHT_ADDR_WIDTH
        )
        port map (
            clk   => clk,
            we    => weight_we,
            waddr => weight_waddr,
            wdata => weight_wdata,
            raddr => weight_raddr,
            rdata => weight_rdata
        );

    u_bias_ram : entity work.sync_ram_s32
        generic map (
            DEPTH      => NUM_BIASES,
            ADDR_WIDTH => BIAS_ADDR_WIDTH
        )
        port map (
            clk   => clk,
            we    => bias_we,
            waddr => bias_waddr,
            wdata => bias_wdata,
            raddr => bias_raddr,
            rdata => bias_rdata
        );

    --------------------------------------------------------------------
    -- Multiplier instance.
    -- Replace this entity with mul8s_1L2H_wrapper or mul8s_vakili_wrapper
    -- when testing approximate multipliers.
    --------------------------------------------------------------------
--    u_mul : entity work.mul8s_exact
--        port map (
--            clk => clk,
--            rst => rst,
--            a   => mac_a,
--            b   => mac_b,
--            p   => product
--        );
        
        --------------------------------------------------------------------
    -- To test the Vakili multiplier, replace the instance above with:
    --
    -- REFINEMENT_PART = 0 / 1 (reduced/ higher accuracy)
--     u_mul : entity work.mul8s_vakili_wrapper
--         generic map (
--             REFINEMENT_PART => 0,
--             INOUT_BUF_EN    => false
--         )
--         port map (
--             clk => clk,
--             rst => rst,
--             a   => mac_a,
--             b   => mac_b,
--             p   => product
--         );
--    ------------------------------------------------------------------
    
--    ------------------------------------------------------------------
--     Multiplier instance
    
--     evoApproxLib mul8s_1L2H (IC oriented design)
--    ------------------------------------------------------------------
    u_mul : entity work.mul8s_1L2H_wrapper
    port map (
        clk => clk,
        rst => rst,
        a   => mac_a,
        b   => mac_b,
        p   => product
    );

    process(clk)
        variable waddr_int : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;

                input_idx   <= 0;
                hidden1_idx <= 0;
                hidden2_idx <= 0;
                output_idx  <= 0;

                input_raddr  <= (others => '0');
                weight_raddr <= (others => '0');
                bias_raddr   <= (others => '0');

                mac_a       <= (others => '0');
                mac_b       <= (others => '0');
                product_reg <= (others => '0');
                acc         <= (others => '0');

                hidden1 <= (others => (others => '0'));
                hidden2 <= (others => (others => '0'));

                outputs_reg <= (others => '0');

                busy_reg <= '0';
                done_reg <= '0';

            else
                case state is

                    when IDLE =>
                        busy_reg <= '0';

                        if start = '1' then
                            done_reg <= '0';
                            busy_reg <= '1';

                            input_idx   <= 0;
                            hidden1_idx <= 0;
                            hidden2_idx <= 0;
                            output_idx  <= 0;

                            state <= INIT_L1_SET_BIAS;
                        end if;

                    ----------------------------------------------------------------
                    -- Layer 1: input -> hidden1
                    ----------------------------------------------------------------
                    when INIT_L1_SET_BIAS =>
                        bias_raddr <= to_unsigned(B1_BASE + hidden1_idx, BIAS_ADDR_WIDTH);
                        state <= INIT_L1_WAIT_BIAS;

                    when INIT_L1_WAIT_BIAS =>
                        state <= INIT_L1_LOAD_BIAS;

                    when INIT_L1_LOAD_BIAS =>
                        acc <= bias_rdata;
                        input_idx <= 0;
                        state <= SET_ADDR_L1;

                    when SET_ADDR_L1 =>
                        input_raddr <= to_unsigned(input_idx, INPUT_ADDR_WIDTH);

                        waddr_int := W1_BASE
                                   + hidden1_idx * NUM_INPUTS
                                   + input_idx;

                        weight_raddr <= to_unsigned(waddr_int, WEIGHT_ADDR_WIDTH);
                        state <= WAIT_DATA_L1;

                    when WAIT_DATA_L1 =>
                        state <= LOAD_MUL_L1;

                    when LOAD_MUL_L1 =>
                        mac_a <= input_rdata;
                        mac_b <= weight_rdata;
                        state <= WAIT_MUL_L1_A;

                    when WAIT_MUL_L1_A =>
                        state <= WAIT_MUL_L1_B;

                    when WAIT_MUL_L1_B =>
                        product_reg <= product;
                        state <= ACCUM_L1;

                    when ACCUM_L1 =>
                        acc <= acc + resize(product_reg, 32);

                        if input_idx = NUM_INPUTS - 1 then
                            state <= STORE_HIDDEN1;
                        else
                            input_idx <= input_idx + 1;
                            state <= SET_ADDR_L1;
                        end if;

                    when STORE_HIDDEN1 =>
                        hidden1(hidden1_idx) <= relu_clip_s8(acc, HIDDEN1_SCALE_SHIFT);

                        if hidden1_idx = NUM_HIDDEN1 - 1 then
                            hidden2_idx <= 0;
                            state <= INIT_L2_SET_BIAS;
                        else
                            hidden1_idx <= hidden1_idx + 1;
                            input_idx <= 0;
                            state <= INIT_L1_SET_BIAS;
                        end if;

                    ----------------------------------------------------------------
                    -- Layer 2: hidden1 -> hidden2
                    ----------------------------------------------------------------
                    when INIT_L2_SET_BIAS =>
                        bias_raddr <= to_unsigned(B2_BASE + hidden2_idx, BIAS_ADDR_WIDTH);
                        state <= INIT_L2_WAIT_BIAS;

                    when INIT_L2_WAIT_BIAS =>
                        state <= INIT_L2_LOAD_BIAS;

                    when INIT_L2_LOAD_BIAS =>
                        acc <= bias_rdata;
                        hidden1_idx <= 0;
                        state <= SET_ADDR_L2;

                    when SET_ADDR_L2 =>
                        waddr_int := W2_BASE
                                   + hidden2_idx * NUM_HIDDEN1
                                   + hidden1_idx;

                        weight_raddr <= to_unsigned(waddr_int, WEIGHT_ADDR_WIDTH);
                        state <= WAIT_DATA_L2;

                    when WAIT_DATA_L2 =>
                        state <= LOAD_MUL_L2;

                    when LOAD_MUL_L2 =>
                        mac_a <= hidden1(hidden1_idx);
                        mac_b <= weight_rdata;
                        state <= WAIT_MUL_L2_A;

                    when WAIT_MUL_L2_A =>
                        state <= WAIT_MUL_L2_B;

                    when WAIT_MUL_L2_B =>
                        product_reg <= product;
                        state <= ACCUM_L2;

                    when ACCUM_L2 =>
                        acc <= acc + resize(product_reg, 32);

                        if hidden1_idx = NUM_HIDDEN1 - 1 then
                            state <= STORE_HIDDEN2;
                        else
                            hidden1_idx <= hidden1_idx + 1;
                            state <= SET_ADDR_L2;
                        end if;

                    when STORE_HIDDEN2 =>
                        hidden2(hidden2_idx) <= relu_clip_s8(acc, HIDDEN2_SCALE_SHIFT);

                        if hidden2_idx = NUM_HIDDEN2 - 1 then
                            output_idx <= 0;
                            state <= INIT_L3_SET_BIAS;
                        else
                            hidden2_idx <= hidden2_idx + 1;
                            hidden1_idx <= 0;
                            state <= INIT_L2_SET_BIAS;
                        end if;

                    ----------------------------------------------------------------
                    -- Layer 3: hidden2 -> output
                    ----------------------------------------------------------------
                    when INIT_L3_SET_BIAS =>
                        bias_raddr <= to_unsigned(B3_BASE + output_idx, BIAS_ADDR_WIDTH);
                        state <= INIT_L3_WAIT_BIAS;

                    when INIT_L3_WAIT_BIAS =>
                        state <= INIT_L3_LOAD_BIAS;

                    when INIT_L3_LOAD_BIAS =>
                        acc <= bias_rdata;
                        hidden2_idx <= 0;
                        state <= SET_ADDR_L3;

                    when SET_ADDR_L3 =>
                        waddr_int := W3_BASE
                                   + output_idx * NUM_HIDDEN2
                                   + hidden2_idx;

                        weight_raddr <= to_unsigned(waddr_int, WEIGHT_ADDR_WIDTH);
                        state <= WAIT_DATA_L3;

                    when WAIT_DATA_L3 =>
                        state <= LOAD_MUL_L3;

                    when LOAD_MUL_L3 =>
                        mac_a <= hidden2(hidden2_idx);
                        mac_b <= weight_rdata;
                        state <= WAIT_MUL_L3_A;

                    when WAIT_MUL_L3_A =>
                        state <= WAIT_MUL_L3_B;

                    when WAIT_MUL_L3_B =>
                        product_reg <= product;
                        state <= ACCUM_L3;

                    when ACCUM_L3 =>
                        acc <= acc + resize(product_reg, 32);

                        if hidden2_idx = NUM_HIDDEN2 - 1 then
                            state <= STORE_OUTPUT;
                        else
                            hidden2_idx <= hidden2_idx + 1;
                            state <= SET_ADDR_L3;
                        end if;

                    when STORE_OUTPUT =>
                        outputs_reg((output_idx + 1) * 32 - 1 downto output_idx * 32) <= acc;

                        if output_idx = NUM_OUTPUTS - 1 then
                            state <= FINISH;
                        else
                            output_idx <= output_idx + 1;
                            hidden2_idx <= 0;
                            state <= INIT_L3_SET_BIAS;
                        end if;

                    ----------------------------------------------------------------
                    -- Finish
                    ----------------------------------------------------------------
                    when FINISH =>
                        busy_reg <= '0';
                        done_reg <= '1';
                        state <= IDLE;

                end case;
            end if;
        end if;
    end process;

end architecture;
