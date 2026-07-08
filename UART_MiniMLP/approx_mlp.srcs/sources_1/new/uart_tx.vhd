library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
    generic (
        CLKS_PER_BIT : integer := 868  -- 100 MHz / 115200 baud
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        tx_start  : in  std_logic;
        tx_byte   : in  std_logic_vector(7 downto 0);
        tx_serial : out std_logic;
        tx_busy   : out std_logic;
        tx_done   : out std_logic
    );
end entity;

architecture rtl of uart_tx is

    type state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT, CLEANUP);
    signal state : state_t := IDLE;

    signal clk_count : integer range 0 to CLKS_PER_BIT - 1 := 0;
    signal bit_index : integer range 0 to 7 := 0;
    signal tx_shift  : std_logic_vector(7 downto 0) := (others => '0');

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state     <= IDLE;
                clk_count <= 0;
                bit_index <= 0;
                tx_shift  <= (others => '0');
                tx_serial <= '1';
                tx_busy   <= '0';
                tx_done   <= '0';
            else
                tx_done <= '0';

                case state is

                    when IDLE =>
                        tx_serial <= '1';
                        tx_busy   <= '0';
                        clk_count <= 0;
                        bit_index <= 0;

                        if tx_start = '1' then
                            tx_shift <= tx_byte;
                            tx_busy  <= '1';
                            state    <= START_BIT;
                        end if;

                    when START_BIT =>
                        tx_serial <= '0';
                        tx_busy   <= '1';

                        if clk_count = CLKS_PER_BIT - 1 then
                            clk_count <= 0;
                            state <= DATA_BITS;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    when DATA_BITS =>
                        tx_serial <= tx_shift(bit_index);
                        tx_busy   <= '1';

                        if clk_count = CLKS_PER_BIT - 1 then
                            clk_count <= 0;

                            if bit_index = 7 then
                                bit_index <= 0;
                                state <= STOP_BIT;
                            else
                                bit_index <= bit_index + 1;
                            end if;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    when STOP_BIT =>
                        tx_serial <= '1';
                        tx_busy   <= '1';

                        if clk_count = CLKS_PER_BIT - 1 then
                            clk_count <= 0;
                            state <= CLEANUP;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    when CLEANUP =>
                        tx_busy <= '0';
                        tx_done <= '1';
                        state <= IDLE;

                end case;
            end if;
        end if;
    end process;

end architecture;