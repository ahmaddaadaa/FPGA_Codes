library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_rx is
    generic (
        CLKS_PER_BIT : integer := 868  -- 100 MHz / 115200 baud
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        rx_serial : in  std_logic;
        rx_valid  : out std_logic;
        rx_byte   : out std_logic_vector(7 downto 0)
    );
end entity;

architecture rtl of uart_rx is

    type state_t is (
        IDLE,
        START_BIT,
        DATA_BITS,
        STOP_BIT,
        CLEANUP
    );

    signal state : state_t := IDLE;

    signal clk_count : integer range 0 to CLKS_PER_BIT - 1 := 0;
    signal bit_index : integer range 0 to 7 := 0;
    signal rx_shift  : std_logic_vector(7 downto 0) := (others => '0');

    --------------------------------------------------------------------
    -- Synchronizer for asynchronous UART RX input
    --------------------------------------------------------------------
    signal rx_meta : std_logic := '1';
    signal rx_sync : std_logic := '1';

begin

    --------------------------------------------------------------------
    -- Two-flop synchronizer
    --------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rx_meta <= '1';
                rx_sync <= '1';
            else
                rx_meta <= rx_serial;
                rx_sync <= rx_meta;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- UART receiver FSM
    --------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state     <= IDLE;
                clk_count <= 0;
                bit_index <= 0;
                rx_shift  <= (others => '0');
                rx_valid  <= '0';
                rx_byte   <= (others => '0');

            else
                rx_valid <= '0';

                case state is

                    ----------------------------------------------------
                    -- Wait for falling edge/start bit
                    ----------------------------------------------------
                    when IDLE =>
                        clk_count <= 0;
                        bit_index <= 0;

                        if rx_sync = '0' then
                            state <= START_BIT;
                        end if;

                    ----------------------------------------------------
                    -- Sample middle of start bit
                    ----------------------------------------------------
                    when START_BIT =>
                        if clk_count = (CLKS_PER_BIT - 1) / 2 then
                            if rx_sync = '0' then
                                clk_count <= 0;
                                state <= DATA_BITS;
                            else
                                clk_count <= 0;
                                state <= IDLE;
                            end if;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    ----------------------------------------------------
                    -- Receive 8 data bits, LSB first
                    ----------------------------------------------------
                    when DATA_BITS =>
                        if clk_count = CLKS_PER_BIT - 1 then
                            clk_count <= 0;
                            rx_shift(bit_index) <= rx_sync;

                            if bit_index = 7 then
                                bit_index <= 0;
                                state <= STOP_BIT;
                            else
                                bit_index <= bit_index + 1;
                            end if;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    ----------------------------------------------------
                    -- Stop bit
                    ----------------------------------------------------
                    when STOP_BIT =>
                        if clk_count = CLKS_PER_BIT - 1 then
                            clk_count <= 0;

                            -- Only accept byte if stop bit is high.
                            -- If stop bit is low, treat it as a framing error
                            -- and discard the byte.
                            if rx_sync = '1' then
                                rx_byte  <= rx_shift;
                                rx_valid <= '1';
                            end if;

                            state <= CLEANUP;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    ----------------------------------------------------
                    -- Return to idle
                    ----------------------------------------------------
                    when CLEANUP =>
                        state <= IDLE;

                end case;
            end if;
        end if;
    end process;

end architecture;