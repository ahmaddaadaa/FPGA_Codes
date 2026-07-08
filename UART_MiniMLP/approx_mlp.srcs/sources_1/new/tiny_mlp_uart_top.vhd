library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mlp_types_pkg.all;

entity tiny_mlp_uart_top is
    generic (
        CLKS_PER_BIT : integer := 868
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;

        uart_rx_i : in  std_logic;
        uart_tx_o : out std_logic;

        led_busy  : out std_logic;
        led_done  : out std_logic
    );
end entity;

architecture rtl of tiny_mlp_uart_top is

    constant START_BYTE : std_logic_vector(7 downto 0) := x"AA";

    constant CMD_WRITE_WEIGHT : std_logic_vector(7 downto 0) := x"01";
    constant CMD_WRITE_BIAS   : std_logic_vector(7 downto 0) := x"02";
    constant CMD_WRITE_INPUT  : std_logic_vector(7 downto 0) := x"03";
    constant CMD_START        : std_logic_vector(7 downto 0) := x"04";
    constant CMD_READ_OUT     : std_logic_vector(7 downto 0) := x"05";
    constant CMD_STATUS       : std_logic_vector(7 downto 0) := x"06";

    constant CMD_ACK        : std_logic_vector(7 downto 0) := x"F0";
    constant CMD_OUT_DATA   : std_logic_vector(7 downto 0) := x"81";
    constant CMD_STATUS_DAT : std_logic_vector(7 downto 0) := x"86";
    constant CMD_ERROR      : std_logic_vector(7 downto 0) := x"FF";

    constant BYTE_00 : std_logic_vector(7 downto 0) := x"00";
    constant BYTE_01 : std_logic_vector(7 downto 0) := x"01";
    constant BYTE_02 : std_logic_vector(7 downto 0) := x"02";
    constant BYTE_03 : std_logic_vector(7 downto 0) := x"03";
    constant BYTE_08 : std_logic_vector(7 downto 0) := x"08";

    constant MAX_PAYLOAD : integer := 16;

    type parser_state_t is (
        WAIT_START,
        GET_CMD,
        GET_ADDR_H,
        GET_ADDR_L,
        GET_LEN_H,
        GET_LEN_L,
        GET_PAYLOAD,
        GET_CHECKSUM
    );

    signal parser_state : parser_state_t := WAIT_START;

    type tx_state_t is (
        TX_IDLE,
        TX_LOAD,
        TX_WAIT_BUSY,
        TX_WAIT_DONE
    );

    signal tx_state : tx_state_t := TX_IDLE;

    signal rx_valid : std_logic;
    signal rx_byte  : std_logic_vector(7 downto 0);

    signal rx_cmd    : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_addr_h : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_addr_l : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_len_h  : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_len_l  : std_logic_vector(7 downto 0) := (others => '0');

    signal rx_len_int    : integer range 0 to MAX_PAYLOAD := 0;
    signal payload_count : integer range 0 to MAX_PAYLOAD := 0;

    type payload_buf_t is array (0 to MAX_PAYLOAD - 1) of std_logic_vector(7 downto 0);
    signal payload_buf : payload_buf_t := (others => (others => '0'));

    signal checksum_acc : unsigned(7 downto 0) := (others => '0');

    signal tx_start : std_logic := '0';
    signal tx_byte  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_busy  : std_logic;
    signal tx_done  : std_logic;

    type tx_buf_t is array (0 to 31) of std_logic_vector(7 downto 0);
    signal tx_buf : tx_buf_t := (others => (others => '0'));

    signal tx_len   : integer range 0 to 32 := 0;
    signal tx_index : integer range 0 to 32 := 0;
    signal tx_kick  : std_logic := '0';

    signal input_mem : input_mem_t := (
        to_signed(1, 8),
        to_signed(2, 8),
        to_signed(3, 8),
        to_signed(4, 8)
    );

    signal weight_mem : weight_mem_t := (
        -- W1: hidden 0
        to_signed(1, 8),
        to_signed(1, 8),
        to_signed(1, 8),
        to_signed(1, 8),

        -- W1: hidden 1
        to_signed(2, 8),
        to_signed(0, 8),
        to_signed(-1, 8),
        to_signed(1, 8),

        -- W2: output 0
        to_signed(1, 8),
        to_signed(-1, 8),

        -- W2: output 1
        to_signed(2, 8),
        to_signed(1, 8)
    );

    signal bias_mem : bias_mem_t := (
        to_signed(0, 32),
        to_signed(0, 32),
        to_signed(0, 32),
        to_signed(0, 32)
    );

    signal mlp_start : std_logic := '0';
    signal mlp_busy  : std_logic;
    signal mlp_done  : std_logic;
    signal mlp_out0  : signed(31 downto 0);
    signal mlp_out1  : signed(31 downto 0);

    function add8(
        a : unsigned(7 downto 0);
        b : std_logic_vector(7 downto 0)
    ) return unsigned is
    begin
        return a + unsigned(b);
    end function;

    function u8(i : integer) return unsigned is
    begin
        return to_unsigned(i, 8);
    end function;

    procedure build_ack(
        signal buf : out tx_buf_t;
        signal len : out integer;
        cmd        : in  std_logic_vector(7 downto 0)
    ) is
        variable cks : unsigned(7 downto 0);
    begin
        buf(0) <= START_BYTE;
        buf(1) <= CMD_ACK;
        buf(2) <= BYTE_00;
        buf(3) <= BYTE_00;
        buf(4) <= BYTE_00;
        buf(5) <= BYTE_01;
        buf(6) <= cmd;

        cks := unsigned(START_BYTE)
             + unsigned(CMD_ACK)
             + u8(0) + u8(0) + u8(0) + u8(1)
             + unsigned(cmd);

        buf(7) <= std_logic_vector(cks);
        len <= 8;
    end procedure;

    procedure build_error(
        signal buf : out tx_buf_t;
        signal len : out integer;
        code       : in  integer
    ) is
        variable cks : unsigned(7 downto 0);
    begin
        buf(0) <= START_BYTE;
        buf(1) <= CMD_ERROR;
        buf(2) <= BYTE_00;
        buf(3) <= BYTE_00;
        buf(4) <= BYTE_00;
        buf(5) <= BYTE_01;
        buf(6) <= std_logic_vector(to_unsigned(code, 8));

        cks := unsigned(START_BYTE)
             + unsigned(CMD_ERROR)
             + u8(0) + u8(0) + u8(0) + u8(1)
             + u8(code);

        buf(7) <= std_logic_vector(cks);
        len <= 8;
    end procedure;

begin

    led_busy <= mlp_busy;
    led_done <= mlp_done;

    u_rx : entity work.uart_rx
        generic map (
            CLKS_PER_BIT => CLKS_PER_BIT
        )
        port map (
            clk       => clk,
            rst       => rst,
            rx_serial => uart_rx_i,
            rx_valid  => rx_valid,
            rx_byte   => rx_byte
        );

    u_tx : entity work.uart_tx
        generic map (
            CLKS_PER_BIT => CLKS_PER_BIT
        )
        port map (
            clk       => clk,
            rst       => rst,
            tx_start  => tx_start,
            tx_byte   => tx_byte,
            tx_serial => uart_tx_o,
            tx_busy   => tx_busy,
            tx_done   => tx_done
        );

    u_mlp : entity work.tiny_mlp_accelerator
        port map (
            clk        => clk,
            rst        => rst,
            start      => mlp_start,
            busy       => mlp_busy,
            done       => mlp_done,
            input_mem  => input_mem,
            weight_mem => weight_mem,
            bias_mem   => bias_mem,
            out0       => mlp_out0,
            out1       => mlp_out1
        );

    --------------------------------------------------------------------
    -- TX sender
    --------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                tx_start <= '0';
                tx_byte  <= (others => '0');
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
                            tx_byte  <= tx_buf(tx_index);
                            tx_start <= '1';
                            tx_state <= TX_WAIT_BUSY;
                        else
                            tx_index <= 0;
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

    --------------------------------------------------------------------
    -- Parser and command handler
    --------------------------------------------------------------------
    process(clk)
        variable cks         : unsigned(7 downto 0);
        variable status_byte : std_logic_vector(7 downto 0);
        variable out0_slv    : std_logic_vector(31 downto 0);
        variable out1_slv    : std_logic_vector(31 downto 0);
        variable len_v       : integer;
        variable addr_v      : integer;
        variable word32      : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                parser_state <= WAIT_START;
                checksum_acc <= (others => '0');

                rx_cmd    <= (others => '0');
                rx_addr_h <= (others => '0');
                rx_addr_l <= (others => '0');
                rx_len_h  <= (others => '0');
                rx_len_l  <= (others => '0');

                rx_len_int    <= 0;
                payload_count <= 0;
                payload_buf   <= (others => (others => '0'));

                mlp_start <= '0';
                tx_kick   <= '0';

                tx_buf <= (others => (others => '0'));
                tx_len <= 0;

                input_mem <= (
                    to_signed(1, 8),
                    to_signed(2, 8),
                    to_signed(3, 8),
                    to_signed(4, 8)
                );

                weight_mem <= (
                    to_signed(1, 8),
                    to_signed(1, 8),
                    to_signed(1, 8),
                    to_signed(1, 8),
                    to_signed(2, 8),
                    to_signed(0, 8),
                    to_signed(-1, 8),
                    to_signed(1, 8),
                    to_signed(1, 8),
                    to_signed(-1, 8),
                    to_signed(2, 8),
                    to_signed(1, 8)
                );

                bias_mem <= (
                    to_signed(0, 32),
                    to_signed(0, 32),
                    to_signed(0, 32),
                    to_signed(0, 32)
                );

            else
                mlp_start <= '0';
                tx_kick   <= '0';

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
                            rx_len_l <= rx_byte;
                            checksum_acc <= add8(checksum_acc, rx_byte);

                            if rx_len_h /= BYTE_00 then
                                parser_state <= WAIT_START;
                                rx_len_int <= 0;
                            else
                                len_v := to_integer(unsigned(rx_byte));

                                if len_v > MAX_PAYLOAD then
                                    parser_state <= WAIT_START;
                                    rx_len_int <= 0;
                                elsif len_v = 0 then
                                    rx_len_int <= 0;
                                    parser_state <= GET_CHECKSUM;
                                else
                                    rx_len_int <= len_v;
                                    payload_count <= 0;
                                    parser_state <= GET_PAYLOAD;
                                end if;
                            end if;

                        when GET_PAYLOAD =>
                            payload_buf(payload_count) <= rx_byte;
                            checksum_acc <= add8(checksum_acc, rx_byte);

                            if payload_count = rx_len_int - 1 then
                                parser_state <= GET_CHECKSUM;
                            else
                                payload_count <= payload_count + 1;
                            end if;

                        when GET_CHECKSUM =>
                            if rx_byte = std_logic_vector(checksum_acc) then

                                if tx_state = TX_IDLE then

                                    addr_v := to_integer(unsigned(rx_addr_l));

                                    ------------------------------------------------
                                    -- WRITE_WEIGHT: payload = signed int8 bytes
                                    ------------------------------------------------
                                    if rx_cmd = CMD_WRITE_WEIGHT then

                                        if mlp_busy = '1' then
                                            build_error(tx_buf, tx_len, 1);
                                            tx_kick <= '1';

                                        elsif rx_addr_h /= BYTE_00 or addr_v >= NUM_WEIGHTS or addr_v + rx_len_int > NUM_WEIGHTS then
                                            build_error(tx_buf, tx_len, 3);
                                            tx_kick <= '1';

                                        else
                                            for i in 0 to MAX_PAYLOAD - 1 loop
                                                if i < rx_len_int then
                                                    weight_mem(addr_v + i) <= signed(payload_buf(i));
                                                end if;
                                            end loop;

                                            build_ack(tx_buf, tx_len, CMD_WRITE_WEIGHT);
                                            tx_kick <= '1';
                                        end if;

                                    ------------------------------------------------
                                    -- WRITE_BIAS: payload = little-endian int32 words
                                    ------------------------------------------------
                                    elsif rx_cmd = CMD_WRITE_BIAS then

                                        if mlp_busy = '1' then
                                            build_error(tx_buf, tx_len, 1);
                                            tx_kick <= '1';

                                        elsif rx_addr_h /= BYTE_00 or addr_v >= NUM_BIASES or (rx_len_int mod 4) /= 0 or addr_v + (rx_len_int / 4) > NUM_BIASES then
                                            build_error(tx_buf, tx_len, 3);
                                            tx_kick <= '1';

                                        else
                                            for i in 0 to 3 loop
                                                if (4 * i + 3) < rx_len_int then
                                                    word32 := payload_buf(4 * i + 3)
                                                            & payload_buf(4 * i + 2)
                                                            & payload_buf(4 * i + 1)
                                                            & payload_buf(4 * i + 0);

                                                    bias_mem(addr_v + i) <= signed(word32);
                                                end if;
                                            end loop;

                                            build_ack(tx_buf, tx_len, CMD_WRITE_BIAS);
                                            tx_kick <= '1';
                                        end if;

                                    ------------------------------------------------
                                    -- WRITE_INPUT: payload = signed int8 bytes
                                    ------------------------------------------------
                                    elsif rx_cmd = CMD_WRITE_INPUT then

                                        if mlp_busy = '1' then
                                            build_error(tx_buf, tx_len, 1);
                                            tx_kick <= '1';

                                        elsif rx_addr_h /= BYTE_00 or addr_v >= NUM_INPUTS or addr_v + rx_len_int > NUM_INPUTS then
                                            build_error(tx_buf, tx_len, 3);
                                            tx_kick <= '1';

                                        else
                                            for i in 0 to MAX_PAYLOAD - 1 loop
                                                if i < rx_len_int then
                                                    input_mem(addr_v + i) <= signed(payload_buf(i));
                                                end if;
                                            end loop;

                                            build_ack(tx_buf, tx_len, CMD_WRITE_INPUT);
                                            tx_kick <= '1';
                                        end if;

                                    ------------------------------------------------
                                    -- START
                                    ------------------------------------------------
                                    elsif rx_cmd = CMD_START then

                                        if mlp_busy = '0' then
                                            mlp_start <= '1';
                                            build_ack(tx_buf, tx_len, CMD_START);
                                            tx_kick <= '1';
                                        else
                                            build_error(tx_buf, tx_len, 1);
                                            tx_kick <= '1';
                                        end if;

                                    ------------------------------------------------
                                    -- STATUS
                                    ------------------------------------------------
                                    elsif rx_cmd = CMD_STATUS then

                                        status_byte := "000000" & mlp_done & mlp_busy;

                                        tx_buf(0) <= START_BYTE;
                                        tx_buf(1) <= CMD_STATUS_DAT;
                                        tx_buf(2) <= BYTE_00;
                                        tx_buf(3) <= BYTE_00;
                                        tx_buf(4) <= BYTE_00;
                                        tx_buf(5) <= BYTE_01;
                                        tx_buf(6) <= status_byte;

                                        cks := unsigned(START_BYTE)
                                             + unsigned(CMD_STATUS_DAT)
                                             + u8(0) + u8(0) + u8(0) + u8(1)
                                             + unsigned(status_byte);

                                        tx_buf(7) <= std_logic_vector(cks);
                                        tx_len    <= 8;
                                        tx_kick   <= '1';

                                    ------------------------------------------------
                                    -- READ_OUTPUT
                                    ------------------------------------------------
                                    elsif rx_cmd = CMD_READ_OUT then

                                        out0_slv := std_logic_vector(mlp_out0);
                                        out1_slv := std_logic_vector(mlp_out1);

                                        tx_buf(0)  <= START_BYTE;
                                        tx_buf(1)  <= CMD_OUT_DATA;
                                        tx_buf(2)  <= BYTE_00;
                                        tx_buf(3)  <= BYTE_00;
                                        tx_buf(4)  <= BYTE_00;
                                        tx_buf(5)  <= BYTE_08;

                                        tx_buf(6)  <= out0_slv(7 downto 0);
                                        tx_buf(7)  <= out0_slv(15 downto 8);
                                        tx_buf(8)  <= out0_slv(23 downto 16);
                                        tx_buf(9)  <= out0_slv(31 downto 24);

                                        tx_buf(10) <= out1_slv(7 downto 0);
                                        tx_buf(11) <= out1_slv(15 downto 8);
                                        tx_buf(12) <= out1_slv(23 downto 16);
                                        tx_buf(13) <= out1_slv(31 downto 24);

                                        cks := unsigned(START_BYTE)
                                             + unsigned(CMD_OUT_DATA)
                                             + u8(0) + u8(0) + u8(0) + u8(8)
                                             + unsigned(out0_slv(7 downto 0))
                                             + unsigned(out0_slv(15 downto 8))
                                             + unsigned(out0_slv(23 downto 16))
                                             + unsigned(out0_slv(31 downto 24))
                                             + unsigned(out1_slv(7 downto 0))
                                             + unsigned(out1_slv(15 downto 8))
                                             + unsigned(out1_slv(23 downto 16))
                                             + unsigned(out1_slv(31 downto 24));

                                        tx_buf(14) <= std_logic_vector(cks);
                                        tx_len     <= 15;
                                        tx_kick    <= '1';

                                    else
                                        build_error(tx_buf, tx_len, 2);
                                        tx_kick <= '1';
                                    end if;
                                end if;
                            end if;

                            parser_state <= WAIT_START;
                            checksum_acc <= (others => '0');
                            rx_len_int <= 0;
                            payload_count <= 0;

                    end case;
                end if;
            end if;
        end if;
    end process;

end architecture;