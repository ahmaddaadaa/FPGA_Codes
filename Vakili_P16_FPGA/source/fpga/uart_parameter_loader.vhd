library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mlp_types_pkg.all;

-- UART is intentionally retained only for one-time parameter loading.  The
-- Ethernet endpoint owns image input, inference control, and result return.
-- The wire format is the existing 0xAA framed protocol so the frozen banked
-- weight uploader remains reusable at 1 Mbaud.
entity uart_parameter_loader is
    generic (
        CLKS_PER_BIT         : integer := 100;
        WEIGHT_ADDRESS_LIMIT : integer := 52736
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        uart_rx_i : in  std_logic;
        uart_tx_o : out std_logic;
        core_busy : in  std_logic;
        debug_diagnostics : in std_logic_vector(383 downto 0);

        weight_we    : out std_logic;
        weight_waddr : out unsigned(WEIGHT_ADDR_WIDTH - 1 downto 0);
        weight_wdata : out signed(7 downto 0);

        bias_we    : out std_logic;
        bias_waddr : out unsigned(BIAS_ADDR_WIDTH - 1 downto 0);
        bias_wdata : out signed(31 downto 0)
    );
end entity;

architecture rtl of uart_parameter_loader is
    constant START_BYTE       : std_logic_vector(7 downto 0) := x"AA";
    constant CMD_WRITE_WEIGHT : std_logic_vector(7 downto 0) := x"01";
    constant CMD_WRITE_BIAS   : std_logic_vector(7 downto 0) := x"02";
    constant CMD_READ_DIAGNOSTICS : std_logic_vector(7 downto 0) := x"03";
    constant CMD_DIAGNOSTICS_DATA : std_logic_vector(7 downto 0) := x"83";
    constant CMD_ACK          : std_logic_vector(7 downto 0) := x"F0";
    constant CMD_ERROR        : std_logic_vector(7 downto 0) := x"FF";
    constant MAX_PAYLOAD      : integer := 16;
    constant DIAGNOSTIC_BYTES : integer := 48;
    constant TX_BYTES         : integer := 56;

    type parser_state_t is (
        WAIT_START, GET_CMD, GET_ADDR_H, GET_ADDR_L,
        GET_LEN_H, GET_LEN_L, GET_PAYLOAD, GET_CHECKSUM
    );
    type service_state_t is (
        SERVICE_IDLE, WRITE_WEIGHT_STEP, WRITE_BIAS_STEP,
        BUILD_DIAGNOSTICS_STEP
    );
    type tx_state_t is (TX_IDLE, TX_LOAD, TX_WAIT_BUSY, TX_WAIT_DONE);
    type payload_t is array (0 to MAX_PAYLOAD - 1) of
        std_logic_vector(7 downto 0);
    type tx_buf_t is array (0 to TX_BYTES - 1) of
        std_logic_vector(7 downto 0);

    signal rx_valid : std_logic;
    signal rx_byte  : std_logic_vector(7 downto 0);
    signal tx_start : std_logic := '0';
    signal tx_byte  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_busy  : std_logic;
    signal tx_done  : std_logic;

    signal parser_state : parser_state_t := WAIT_START;
    signal service_state : service_state_t := SERVICE_IDLE;
    signal tx_state : tx_state_t := TX_IDLE;

    signal rx_cmd    : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_addr_h : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_addr_l : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_len_h  : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_len    : integer range 0 to MAX_PAYLOAD := 0;
    signal rx_index  : integer range 0 to MAX_PAYLOAD := 0;
    signal rx_payload : payload_t := (others => (others => '0'));
    signal checksum_acc : unsigned(7 downto 0) := (others => '0');

    signal command_pending : std_logic := '0';
    signal pending_cmd     : std_logic_vector(7 downto 0) := (others => '0');
    signal pending_addr    : integer range 0 to 65535 := 0;
    signal pending_len     : integer range 0 to MAX_PAYLOAD := 0;
    signal pending_payload : payload_t := (others => (others => '0'));
    signal write_index     : integer range 0 to MAX_PAYLOAD := 0;
    signal pending_diagnostics : std_logic_vector(383 downto 0) := (others => '0');
    signal diagnostic_index : integer range 0 to DIAGNOSTIC_BYTES - 1 := 0;
    signal diagnostic_checksum : unsigned(7 downto 0) := (others => '0');

    signal tx_buf   : tx_buf_t := (others => (others => '0'));
    signal tx_len   : integer range 0 to TX_BYTES := 0;
    signal tx_index : integer range 0 to TX_BYTES := 0;
    signal tx_kick  : std_logic := '0';

    function add8(a : unsigned(7 downto 0);
                  b : std_logic_vector(7 downto 0)) return unsigned is
    begin
        return a + unsigned(b);
    end function;

    procedure build_response(
        signal buf : out tx_buf_t;
        signal len : out integer;
        response   : in std_logic_vector(7 downto 0);
        value      : in std_logic_vector(7 downto 0)
    ) is
        variable sum : unsigned(7 downto 0);
    begin
        buf(0) <= START_BYTE;
        buf(1) <= response;
        buf(2) <= x"00";
        buf(3) <= x"00";
        buf(4) <= x"00";
        buf(5) <= x"01";
        buf(6) <= value;
        sum := unsigned(START_BYTE) + unsigned(response) + 1 + unsigned(value);
        buf(7) <= std_logic_vector(sum);
        len <= 8;
    end procedure;

begin
    u_rx : entity work.uart_rx
        generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (
            clk => clk, rst => rst, rx_serial => uart_rx_i,
            rx_valid => rx_valid, rx_byte => rx_byte
        );

    u_tx : entity work.uart_tx
        generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (
            clk => clk, rst => rst, tx_start => tx_start,
            tx_byte => tx_byte, tx_serial => uart_tx_o,
            tx_busy => tx_busy, tx_done => tx_done
        );

    tx_sender : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                tx_start <= '0';
                tx_byte <= (others => '0');
                tx_index <= 0;
                tx_state <= TX_IDLE;
            else
                tx_start <= '0';
                case tx_state is
                    when TX_IDLE =>
                        tx_index <= 0;
                        if tx_kick = '1' then
                            tx_state <= TX_LOAD;
                        end if;
                    when TX_LOAD =>
                        if tx_index < tx_len then
                            tx_byte <= tx_buf(tx_index);
                            tx_start <= '1';
                            tx_state <= TX_WAIT_BUSY;
                        else
                            tx_state <= TX_IDLE;
                        end if;
                    when TX_WAIT_BUSY =>
                        if tx_busy = '1' then
                            tx_state <= TX_WAIT_DONE;
                        end if;
                    when TX_WAIT_DONE =>
                        if tx_done = '1' then
                            tx_index <= tx_index + 1;
                            tx_state <= TX_LOAD;
                        end if;
                end case;
            end if;
        end if;
    end process;

    parser_and_writer : process(clk)
        variable length_value : integer;
        variable address_value : integer;
        variable word32 : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                parser_state <= WAIT_START;
                service_state <= SERVICE_IDLE;
                rx_cmd <= (others => '0');
                rx_addr_h <= (others => '0');
                rx_addr_l <= (others => '0');
                rx_len_h <= (others => '0');
                rx_len <= 0;
                rx_index <= 0;
                rx_payload <= (others => (others => '0'));
                checksum_acc <= (others => '0');
                command_pending <= '0';
                pending_cmd <= (others => '0');
                pending_addr <= 0;
                pending_len <= 0;
                pending_payload <= (others => (others => '0'));
                write_index <= 0;
                pending_diagnostics <= (others => '0');
                diagnostic_index <= 0;
                diagnostic_checksum <= (others => '0');
                tx_kick <= '0';
                tx_buf <= (others => (others => '0'));
                tx_len <= 0;
                weight_we <= '0';
                weight_waddr <= (others => '0');
                weight_wdata <= (others => '0');
                bias_we <= '0';
                bias_waddr <= (others => '0');
                bias_wdata <= (others => '0');
            else
                tx_kick <= '0';
                weight_we <= '0';
                bias_we <= '0';

                if rx_valid = '1' then
                    case parser_state is
                        when WAIT_START =>
                            if rx_byte = START_BYTE then
                                checksum_acc <= unsigned(START_BYTE);
                                parser_state <= GET_CMD;
                            end if;
                        when GET_CMD =>
                            rx_cmd <= rx_byte;
                            checksum_acc <= add8(checksum_acc, rx_byte);
                            parser_state <= GET_ADDR_H;
                        when GET_ADDR_H =>
                            rx_addr_h <= rx_byte;
                            checksum_acc <= add8(checksum_acc, rx_byte);
                            parser_state <= GET_ADDR_L;
                        when GET_ADDR_L =>
                            rx_addr_l <= rx_byte;
                            checksum_acc <= add8(checksum_acc, rx_byte);
                            parser_state <= GET_LEN_H;
                        when GET_LEN_H =>
                            rx_len_h <= rx_byte;
                            checksum_acc <= add8(checksum_acc, rx_byte);
                            parser_state <= GET_LEN_L;
                        when GET_LEN_L =>
                            checksum_acc <= add8(checksum_acc, rx_byte);
                            length_value := to_integer(unsigned(rx_byte));
                            if rx_len_h /= x"00" or length_value > MAX_PAYLOAD then
                                parser_state <= WAIT_START;
                            elsif length_value = 0 then
                                rx_len <= 0;
                                parser_state <= GET_CHECKSUM;
                            else
                                rx_len <= length_value;
                                rx_index <= 0;
                                parser_state <= GET_PAYLOAD;
                            end if;
                        when GET_PAYLOAD =>
                            rx_payload(rx_index) <= rx_byte;
                            checksum_acc <= add8(checksum_acc, rx_byte);
                            if rx_index = rx_len - 1 then
                                parser_state <= GET_CHECKSUM;
                            else
                                rx_index <= rx_index + 1;
                            end if;
                        when GET_CHECKSUM =>
                            if rx_byte = std_logic_vector(checksum_acc) and
                               command_pending = '0' then
                                address_value := to_integer(unsigned(rx_addr_h)) * 256
                                               + to_integer(unsigned(rx_addr_l));
                                pending_cmd <= rx_cmd;
                                pending_addr <= address_value;
                                pending_len <= rx_len;
                                pending_payload <= rx_payload;
                                command_pending <= '1';
                            end if;
                            parser_state <= WAIT_START;
                            checksum_acc <= (others => '0');
                            rx_len <= 0;
                            rx_index <= 0;
                    end case;
                end if;

                case service_state is
                    when SERVICE_IDLE =>
                        if command_pending = '1' and tx_state = TX_IDLE then
                            if pending_cmd = CMD_READ_DIAGNOSTICS and
                               pending_len = 0 then
                                pending_diagnostics <= debug_diagnostics;
                                tx_buf(0) <= START_BYTE;
                                tx_buf(1) <= CMD_DIAGNOSTICS_DATA;
                                tx_buf(2) <= x"00";
                                tx_buf(3) <= x"00";
                                tx_buf(4) <= x"00";
                                tx_buf(5) <= x"30";
                                diagnostic_index <= 0;
                                diagnostic_checksum <=
                                    unsigned(START_BYTE) +
                                    unsigned(CMD_DIAGNOSTICS_DATA) +
                                    DIAGNOSTIC_BYTES;
                                service_state <= BUILD_DIAGNOSTICS_STEP;
                            elsif pending_cmd = CMD_READ_DIAGNOSTICS then
                                build_response(tx_buf, tx_len, CMD_ERROR, x"03");
                                tx_kick <= '1';
                                command_pending <= '0';
                            elsif core_busy = '1' then
                                build_response(tx_buf, tx_len, CMD_ERROR, x"01");
                                tx_kick <= '1';
                                command_pending <= '0';
                            elsif pending_cmd = CMD_WRITE_WEIGHT then
                                if pending_len = 0 or
                                   pending_addr + pending_len > WEIGHT_ADDRESS_LIMIT then
                                    build_response(tx_buf, tx_len, CMD_ERROR, x"03");
                                    tx_kick <= '1';
                                    command_pending <= '0';
                                else
                                    write_index <= 0;
                                    service_state <= WRITE_WEIGHT_STEP;
                                end if;
                            elsif pending_cmd = CMD_WRITE_BIAS then
                                if pending_len = 0 or (pending_len mod 4) /= 0 or
                                   pending_addr + (pending_len / 4) > NUM_BIASES then
                                    build_response(tx_buf, tx_len, CMD_ERROR, x"03");
                                    tx_kick <= '1';
                                    command_pending <= '0';
                                else
                                    write_index <= 0;
                                    service_state <= WRITE_BIAS_STEP;
                                end if;
                            else
                                build_response(tx_buf, tx_len, CMD_ERROR, x"02");
                                tx_kick <= '1';
                                command_pending <= '0';
                            end if;
                        end if;

                    when WRITE_WEIGHT_STEP =>
                        weight_we <= '1';
                        weight_waddr <= to_unsigned(
                            pending_addr + write_index, WEIGHT_ADDR_WIDTH
                        );
                        weight_wdata <= signed(pending_payload(write_index));
                        if write_index = pending_len - 1 then
                            build_response(
                                tx_buf, tx_len, CMD_ACK, CMD_WRITE_WEIGHT
                            );
                            tx_kick <= '1';
                            command_pending <= '0';
                            service_state <= SERVICE_IDLE;
                        else
                            write_index <= write_index + 1;
                        end if;

                    when WRITE_BIAS_STEP =>
                        bias_we <= '1';
                        bias_waddr <= to_unsigned(
                            pending_addr + write_index, BIAS_ADDR_WIDTH
                        );
                        word32 := pending_payload(4 * write_index + 3)
                                & pending_payload(4 * write_index + 2)
                                & pending_payload(4 * write_index + 1)
                                & pending_payload(4 * write_index + 0);
                        bias_wdata <= signed(word32);
                        if write_index = (pending_len / 4) - 1 then
                            build_response(
                                tx_buf, tx_len, CMD_ACK, CMD_WRITE_BIAS
                            );
                            tx_kick <= '1';
                            command_pending <= '0';
                            service_state <= SERVICE_IDLE;
                        else
                            write_index <= write_index + 1;
                        end if;

                    when BUILD_DIAGNOSTICS_STEP =>
                        tx_buf(6 + diagnostic_index) <= pending_diagnostics(
                            383 - diagnostic_index * 8 downto
                            376 - diagnostic_index * 8
                        );
                        diagnostic_checksum <= add8(
                            diagnostic_checksum,
                            pending_diagnostics(
                                383 - diagnostic_index * 8 downto
                                376 - diagnostic_index * 8
                            )
                        );
                        if diagnostic_index = DIAGNOSTIC_BYTES - 1 then
                            tx_buf(54) <= std_logic_vector(add8(
                                diagnostic_checksum,
                                pending_diagnostics(7 downto 0)
                            ));
                            tx_len <= 55;
                            tx_kick <= '1';
                            command_pending <= '0';
                            service_state <= SERVICE_IDLE;
                        else
                            diagnostic_index <= diagnostic_index + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture;
