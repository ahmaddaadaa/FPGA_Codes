library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mlp_types_pkg.all;

entity tiny_mlp_accelerator is
    port (
        clk   : in  std_logic;
        rst   : in  std_logic;

        start : in  std_logic;
        busy  : out std_logic;
        done  : out std_logic;

        input_mem  : in input_mem_t;
        weight_mem : in weight_mem_t;
        bias_mem   : in bias_mem_t;

        out0  : out signed(31 downto 0);
        out1  : out signed(31 downto 0)
    );
end entity;

architecture rtl of tiny_mlp_accelerator is

    type state_t is (
        IDLE,

        INIT_L1,
        FETCH_L1,
        WAIT_MUL_L1_A,
        WAIT_MUL_L1_B,
        ACCUM_L1,
        STORE_HIDDEN,

        INIT_L2,
        FETCH_L2,
        WAIT_MUL_L2_A,
        WAIT_MUL_L2_B,
        ACCUM_L2,
        STORE_OUTPUT,

        FINISH
    );

    signal state : state_t := IDLE;

    signal input_idx  : integer range 0 to NUM_INPUTS - 1 := 0;
    signal hidden_idx : integer range 0 to NUM_HIDDEN - 1 := 0;
    signal output_idx : integer range 0 to NUM_OUTPUTS - 1 := 0;

    signal acc : signed(31 downto 0) := (others => '0');

    signal hidden     : hidden_mem_t := (others => (others => '0'));
    signal output_vec : output_mem_t := (others => (others => '0'));

    signal busy_reg : std_logic := '0';
    signal done_reg : std_logic := '0';

    signal mac_a : signed(7 downto 0) := (others => '0');
    signal mac_b : signed(7 downto 0) := (others => '0');

    signal product : signed(15 downto 0) := (others => '0');

begin

    busy <= busy_reg;
    done <= done_reg;

    out0 <= output_vec(0);
    out1 <= output_vec(1);

    --------------------------------------------------------------------
    -- Multiplier instance
    --
    -- Exact version:
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
     u_mul : entity work.mul8s_vakili_wrapper
         generic map (
             REFINEMENT_PART => 1,
             INOUT_BUF_EN    => true
         )
         port map (
             clk => clk,
             rst => rst,
             a   => mac_a,
             b   => mac_b,
             p   => product
         );
--    ------------------------------------------------------------------
    
    --------------------------------------------------------------------
    -- Multiplier instance
    --
    -- evoApproxLib mul8s_1L2H (IC oriented design)
    --------------------------------------------------------------------
--    u_mul : entity work.mul8s_1L2H_wrapper
--    port map (
--        clk => clk,
--        rst => rst,
--        a   => mac_a,
--        b   => mac_b,
--        p   => product
--    );

    process(clk)
        variable w_addr : integer;
        variable b_addr : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state      <= IDLE;
                input_idx  <= 0;
                hidden_idx <= 0;
                output_idx <= 0;

                acc   <= (others => '0');
                mac_a <= (others => '0');
                mac_b <= (others => '0');

                hidden     <= (others => (others => '0'));
                output_vec <= (others => (others => '0'));

                busy_reg <= '0';
                done_reg <= '0';

            else
                case state is

                    ------------------------------------------------------------
                    -- Idle / start
                    ------------------------------------------------------------
                    when IDLE =>
                        busy_reg <= '0';

                        if start = '1' then
                            busy_reg   <= '1';
                            done_reg   <= '0';

                            input_idx  <= 0;
                            hidden_idx <= 0;
                            output_idx <= 0;

                            acc   <= (others => '0');
                            mac_a <= (others => '0');
                            mac_b <= (others => '0');

                            state <= INIT_L1;
                        end if;

                    ------------------------------------------------------------
                    -- Layer 1
                    ------------------------------------------------------------
                    when INIT_L1 =>
                        b_addr := hidden_idx;
                        acc    <= bias_mem(b_addr);

                        input_idx <= 0;
                        state     <= FETCH_L1;

                    when FETCH_L1 =>
                        w_addr := hidden_idx * NUM_INPUTS + input_idx;

                        mac_a <= input_mem(input_idx);
                        mac_b <= weight_mem(w_addr);

                        state <= WAIT_MUL_L1_A;

                    when WAIT_MUL_L1_A =>
                        state <= WAIT_MUL_L1_B;

                    when WAIT_MUL_L1_B =>
                        state <= ACCUM_L1;

                    when ACCUM_L1 =>
                        acc <= acc + resize(product, 32);

                        if input_idx = NUM_INPUTS - 1 then
                            state <= STORE_HIDDEN;
                        else
                            input_idx <= input_idx + 1;
                            state     <= FETCH_L1;
                        end if;

                    when STORE_HIDDEN =>
                        -- ReLU + int8 clipping
                        if acc < to_signed(0, 32) then
                            hidden(hidden_idx) <= to_signed(0, 8);
                        elsif acc > to_signed(127, 32) then
                            hidden(hidden_idx) <= to_signed(127, 8);
                        else
                            hidden(hidden_idx) <= resize(acc, 8);
                        end if;

                        if hidden_idx = NUM_HIDDEN - 1 then
                            output_idx <= 0;
                            state      <= INIT_L2;
                        else
                            hidden_idx <= hidden_idx + 1;
                            state      <= INIT_L1;
                        end if;

                    ------------------------------------------------------------
                    -- Layer 2
                    ------------------------------------------------------------
                    when INIT_L2 =>
                        b_addr := NUM_HIDDEN + output_idx;
                        acc    <= bias_mem(b_addr);

                        hidden_idx <= 0;
                        state      <= FETCH_L2;

                    when FETCH_L2 =>
                        w_addr := NUM_INPUTS * NUM_HIDDEN
                                  + output_idx * NUM_HIDDEN
                                  + hidden_idx;

                        mac_a <= hidden(hidden_idx);
                        mac_b <= weight_mem(w_addr);

                        state <= WAIT_MUL_L2_A;

                    when WAIT_MUL_L2_A =>
                        state <= WAIT_MUL_L2_B;

                    when WAIT_MUL_L2_B =>
                        state <= ACCUM_L2;

                    when ACCUM_L2 =>
                        acc <= acc + resize(product, 32);

                        if hidden_idx = NUM_HIDDEN - 1 then
                            state <= STORE_OUTPUT;
                        else
                            hidden_idx <= hidden_idx + 1;
                            state      <= FETCH_L2;
                        end if;

                    when STORE_OUTPUT =>
                        output_vec(output_idx) <= acc;

                        if output_idx = NUM_OUTPUTS - 1 then
                            state <= FINISH;
                        else
                            output_idx <= output_idx + 1;
                            state      <= INIT_L2;
                        end if;

                    ------------------------------------------------------------
                    -- Done
                    ------------------------------------------------------------
                    when FINISH =>
                        busy_reg <= '0';
                        done_reg <= '1';
                        state    <= IDLE;

                end case;
            end if;
        end if;
    end process;

end architecture;