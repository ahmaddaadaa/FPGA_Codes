library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mlp_types_pkg.all;

-- Architecture-specific UART top for the banked P16 accelerator.
-- It preserves the legacy 16-byte commands used for parameter loading and
-- adds CMD_STREAM_INPUT, whose 784-byte payload is written directly into the
-- input BRAM as it arrives.  The image is never materialized as 784 registers.
entity tiny_mlp_uart_top is
    generic (
        CLKS_PER_BIT        : integer := 868;
        -- Defaults preserve the legacy flat model.  Banked accelerators can
        -- raise the accepted wire-address range without changing port widths.
        WEIGHT_ADDRESS_LIMIT : integer := NUM_WEIGHTS
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

    --------------------------------------------------------------------
    -- Protocol constants
    --------------------------------------------------------------------
    constant START_BYTE : std_logic_vector(7 downto 0) := x"AA";

    constant CMD_WRITE_WEIGHT : std_logic_vector(7 downto 0) := x"01";
    constant CMD_WRITE_BIAS   : std_logic_vector(7 downto 0) := x"02";
    constant CMD_WRITE_INPUT  : std_logic_vector(7 downto 0) := x"03";
    constant CMD_START        : std_logic_vector(7 downto 0) := x"04";
    constant CMD_READ_OUT     : std_logic_vector(7 downto 0) := x"05";
    constant CMD_STATUS       : std_logic_vector(7 downto 0) := x"06";
    constant CMD_STREAM_INPUT : std_logic_vector(7 downto 0) := x"07";

    constant CMD_ACK        : std_logic_vector(7 downto 0) := x"F0";
    constant CMD_OUT_DATA   : std_logic_vector(7 downto 0) := x"81";
    constant CMD_STATUS_DAT : std_logic_vector(7 downto 0) := x"86";
    constant CMD_ERROR      : std_logic_vector(7 downto 0) := x"FF";

    constant BYTE_00 : std_logic_vector(7 downto 0) := x"00";
    constant BYTE_01 : std_logic_vector(7 downto 0) := x"01";
    --------------------------------------------------------------------
    -- Keep this small for the current UART parser.
    -- The PC should send large final-model memories in chunks.
    --------------------------------------------------------------------
    constant MAX_PAYLOAD : integer := 16;
    constant STREAM_IMAGE_BYTES : integer := NUM_INPUTS;
    constant MAX_RX_PAYLOAD : integer := STREAM_IMAGE_BYTES;
    constant OUTPUT_PAYLOAD_BYTES : integer := NUM_OUTPUTS * 4;
    constant TX_BUF_SIZE : integer := 6 + OUTPUT_PAYLOAD_BYTES + 1;

    --------------------------------------------------------------------
    -- Parser FSM
    --------------------------------------------------------------------
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

    signal rx_valid : std_logic;
    signal rx_byte  : std_logic_vector(7 downto 0);

    signal rx_cmd    : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_addr_h : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_addr_l : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_len_h  : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_len_l  : std_logic_vector(7 downto 0) := (others => '0');

    signal rx_len_int    : integer range 0 to MAX_RX_PAYLOAD := 0;
    signal payload_count : integer range 0 to MAX_RX_PAYLOAD := 0;
    signal stream_write_enabled : std_logic := '0';

    type payload_buf_t is array (0 to MAX_PAYLOAD - 1) of std_logic_vector(7 downto 0);
    signal payload_buf : payload_buf_t := (others => (others => '0'));

    signal checksum_acc : unsigned(7 downto 0) := (others => '0');

    --------------------------------------------------------------------
    -- Pending command latch
    --
    -- The parser latches a complete valid packet here. The service FSM
    -- consumes it only when the TX engine is idle. This prevents valid
    -- commands from being dropped while a response is still being sent.
    --------------------------------------------------------------------
    signal cmd_pending : std_logic := '0';

    signal pending_cmd     : std_logic_vector(7 downto 0) := (others => '0');
    signal pending_addr    : integer range 0 to 65535 := 0;
    signal pending_len     : integer range 0 to MAX_RX_PAYLOAD := 0;
    signal pending_payload : payload_buf_t := (others => (others => '0'));
    signal pending_stream_accepted : std_logic := '0';

    --------------------------------------------------------------------
    -- TX sender FSM
    --------------------------------------------------------------------
    type tx_state_t is (
        TX_IDLE,
        TX_LOAD,
        TX_WAIT_BUSY,
        TX_WAIT_DONE
    );

    signal tx_state : tx_state_t := TX_IDLE;

    signal tx_start : std_logic := '0';
    signal tx_byte  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_busy  : std_logic;
    signal tx_done  : std_logic;

    type tx_buf_t is array (0 to TX_BUF_SIZE - 1) of std_logic_vector(7 downto 0);
    signal tx_buf : tx_buf_t := (others => (others => '0'));

    signal tx_len   : integer range 0 to TX_BUF_SIZE := 0;
    signal tx_index : integer range 0 to TX_BUF_SIZE := 0;
    signal tx_kick  : std_logic := '0';

    --------------------------------------------------------------------
    -- Command service FSM
    --------------------------------------------------------------------
    type service_state_t is (
        SERVICE_IDLE,
        WRITE_WEIGHT_STEP,
        WRITE_INPUT_STEP,
        WRITE_BIAS_STEP
    );

    signal service_state : service_state_t := SERVICE_IDLE;

    signal write_index     : integer range 0 to MAX_PAYLOAD := 0;
    signal write_base_addr : integer range 0 to 65535 := 0;
    signal ack_cmd         : std_logic_vector(7 downto 0) := (others => '0');

    --------------------------------------------------------------------
    -- BRAM write ports driven by UART service FSM
    --------------------------------------------------------------------
    signal input_we    : std_logic := '0';
    signal input_waddr : unsigned(INPUT_ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal input_wdata : signed(7 downto 0) := (others => '0');

    signal weight_we    : std_logic := '0';
    signal weight_waddr : unsigned(WEIGHT_ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal weight_wdata : signed(7 downto 0) := (others => '0');

    signal bias_we    : std_logic := '0';
    signal bias_waddr : unsigned(BIAS_ADDR_WIDTH - 1 downto 0) := (others => '0');
    signal bias_wdata : signed(31 downto 0) := (others => '0');

    --------------------------------------------------------------------
    -- MLP control/status
    --------------------------------------------------------------------
    signal mlp_start : std_logic := '0';
    signal mlp_busy  : std_logic;
    signal mlp_done  : std_logic;
    signal mlp_outputs : signed(NUM_OUTPUTS * 32 - 1 downto 0);

    --------------------------------------------------------------------
    -- Helpers
    --------------------------------------------------------------------
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

    --------------------------------------------------------------------
    -- UART RX
    --------------------------------------------------------------------
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

    --------------------------------------------------------------------
    -- UART TX
    --------------------------------------------------------------------
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

    --------------------------------------------------------------------
    -- BRAM-based MLP accelerator
    --------------------------------------------------------------------
    u_mlp : entity work.tiny_mlp_accelerator_bram
        port map (
            clk   => clk,
            rst   => rst,
            start => mlp_start,

            input_we    => input_we,
            input_waddr => input_waddr,
            input_wdata => input_wdata,

            weight_we    => weight_we,
            weight_waddr => weight_waddr,
            weight_wdata => weight_wdata,

            bias_we    => bias_we,
            bias_waddr => bias_waddr,
            bias_wdata => bias_wdata,

            busy => mlp_busy,
            done => mlp_done,
            inference_complete => open,

            outputs => mlp_outputs
        );

    --------------------------------------------------------------------
    -- TX packet sender
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
    -- Parser and command service
    --------------------------------------------------------------------
    process(clk)
        variable cks         : unsigned(7 downto 0);
        variable status_byte : std_logic_vector(7 downto 0);
        variable output_slv  : std_logic_vector(31 downto 0);
        variable len_v       : integer;
        variable addr_v      : integer;
        variable word32      : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then

                ----------------------------------------------------------------
                -- Parser reset
                ----------------------------------------------------------------
                parser_state <= WAIT_START;
                checksum_acc <= (others => '0');

                rx_cmd    <= (others => '0');
                rx_addr_h <= (others => '0');
                rx_addr_l <= (others => '0');
                rx_len_h  <= (others => '0');
                rx_len_l  <= (others => '0');

                rx_len_int    <= 0;
                payload_count <= 0;
                stream_write_enabled <= '0';
                payload_buf   <= (others => (others => '0'));

                ----------------------------------------------------------------
                -- Pending command reset
                ----------------------------------------------------------------
                cmd_pending <= '0';
                pending_cmd <= (others => '0');
                pending_addr <= 0;
                pending_len <= 0;
                pending_payload <= (others => (others => '0'));
                pending_stream_accepted <= '0';

                ----------------------------------------------------------------
                -- Service/reset
                ----------------------------------------------------------------
                service_state <= SERVICE_IDLE;
                write_index <= 0;
                write_base_addr <= 0;
                ack_cmd <= (others => '0');

                ----------------------------------------------------------------
                -- Output/write controls reset
                ----------------------------------------------------------------
                mlp_start <= '0';
                tx_kick   <= '0';

                input_we  <= '0';
                weight_we <= '0';
                bias_we   <= '0';

                input_waddr  <= (others => '0');
                weight_waddr <= (others => '0');
                bias_waddr   <= (others => '0');

                input_wdata  <= (others => '0');
                weight_wdata <= (others => '0');
                bias_wdata   <= (others => '0');

                tx_buf <= (others => (others => '0'));
                tx_len <= 0;

            else

                ----------------------------------------------------------------
                -- Default one-cycle strobes low
                ----------------------------------------------------------------
                mlp_start <= '0';
                tx_kick   <= '0';

                input_we  <= '0';
                weight_we <= '0';
                bias_we   <= '0';

                ----------------------------------------------------------------
                -- UART packet parser
                ----------------------------------------------------------------
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

                            len_v := to_integer(unsigned(rx_len_h)) * 256
                                   + to_integer(unsigned(rx_byte));

                            if rx_cmd = CMD_STREAM_INPUT then
                                if len_v /= STREAM_IMAGE_BYTES then
                                    parser_state <= WAIT_START;
                                    rx_len_int <= 0;
                                    stream_write_enabled <= '0';
                                else
                                    rx_len_int <= len_v;
                                    payload_count <= 0;
                                    if mlp_busy = '0' and cmd_pending = '0' then
                                        stream_write_enabled <= '1';
                                    else
                                        stream_write_enabled <= '0';
                                    end if;
                                    parser_state <= GET_PAYLOAD;
                                end if;

                            elsif rx_len_h /= BYTE_00 or len_v > MAX_PAYLOAD then
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

                        when GET_PAYLOAD =>
                            if rx_cmd = CMD_STREAM_INPUT then
                                if stream_write_enabled = '1' then
                                    input_we <= '1';
                                    input_waddr <= to_unsigned(
                                        payload_count, INPUT_ADDR_WIDTH
                                    );
                                    input_wdata <= signed(rx_byte);
                                end if;
                            else
                                payload_buf(payload_count) <= rx_byte;
                            end if;
                            checksum_acc <= add8(checksum_acc, rx_byte);

                            if payload_count = rx_len_int - 1 then
                                parser_state <= GET_CHECKSUM;
                            else
                                payload_count <= payload_count + 1;
                            end if;

                        when GET_CHECKSUM =>
                            if rx_byte = std_logic_vector(checksum_acc) then

                                -- Latch the complete packet only if the previous
                                -- command has already been consumed.
                                if cmd_pending = '0' then
                                    addr_v := to_integer(unsigned(rx_addr_h)) * 256
                                            + to_integer(unsigned(rx_addr_l));

                                    pending_cmd     <= rx_cmd;
                                    pending_addr    <= addr_v;
                                    pending_len     <= rx_len_int;
                                    pending_payload <= payload_buf;
                                    if rx_cmd = CMD_STREAM_INPUT then
                                        pending_stream_accepted <= stream_write_enabled;
                                    else
                                        pending_stream_accepted <= '1';
                                    end if;
                                    cmd_pending     <= '1';
                                end if;

                            end if;

                            parser_state <= WAIT_START;
                            checksum_acc <= (others => '0');
                            rx_len_int <= 0;
                            payload_count <= 0;
                            stream_write_enabled <= '0';

                    end case;
                end if;

                ----------------------------------------------------------------
                -- Command service FSM
                --
                -- This is the BRAM-specific part. Instead of writing all memory
                -- entries in a for-loop in one cycle, each WRITE command writes
                -- one memory word per clock cycle.
                ----------------------------------------------------------------
                case service_state is

                    ------------------------------------------------------------
                    -- Wait for a complete pending command and idle TX engine
                    ------------------------------------------------------------
                    when SERVICE_IDLE =>

                        if cmd_pending = '1' and tx_state = TX_IDLE then

                            ----------------------------------------------------
                            -- WRITE_WEIGHT: payload is signed int8 bytes
                            ----------------------------------------------------
                            if pending_cmd = CMD_WRITE_WEIGHT then

                                if mlp_busy = '1' then
                                    build_error(tx_buf, tx_len, 1);
                                    tx_kick <= '1';
                                    cmd_pending <= '0';

                                elsif pending_len = 0 then
                                    build_error(tx_buf, tx_len, 3);
                                    tx_kick <= '1';
                                    cmd_pending <= '0';

                                elsif pending_addr >= WEIGHT_ADDRESS_LIMIT or
                                      pending_addr + pending_len > WEIGHT_ADDRESS_LIMIT then
                                    build_error(tx_buf, tx_len, 3);
                                    tx_kick <= '1';
                                    cmd_pending <= '0';

                                else
                                    write_base_addr <= pending_addr;
                                    write_index <= 0;
                                    ack_cmd <= CMD_WRITE_WEIGHT;
                                    service_state <= WRITE_WEIGHT_STEP;
                                end if;

                            ----------------------------------------------------
                            -- WRITE_BIAS: payload is little-endian int32 words
                            ----------------------------------------------------
                            elsif pending_cmd = CMD_WRITE_BIAS then

                                if mlp_busy = '1' then
                                    build_error(tx_buf, tx_len, 1);
                                    tx_kick <= '1';
                                    cmd_pending <= '0';

                                elsif pending_len = 0 or (pending_len mod 4) /= 0 then
                                    build_error(tx_buf, tx_len, 3);
                                    tx_kick <= '1';
                                    cmd_pending <= '0';

                                elsif pending_addr >= NUM_BIASES or
                                      pending_addr + (pending_len / 4) > NUM_BIASES then
                                    build_error(tx_buf, tx_len, 3);
                                    tx_kick <= '1';
                                    cmd_pending <= '0';

                                else
                                    write_base_addr <= pending_addr;
                                    write_index <= 0;
                                    ack_cmd <= CMD_WRITE_BIAS;
                                    service_state <= WRITE_BIAS_STEP;
                                end if;

                            ----------------------------------------------------
                            -- WRITE_INPUT: payload is signed int8 bytes
                            ----------------------------------------------------
                            elsif pending_cmd = CMD_WRITE_INPUT then

                                if mlp_busy = '1' then
                                    build_error(tx_buf, tx_len, 1);
                                    tx_kick <= '1';
                                    cmd_pending <= '0';

                                elsif pending_len = 0 then
                                    build_error(tx_buf, tx_len, 3);
                                    tx_kick <= '1';
                                    cmd_pending <= '0';

                                elsif pending_addr >= NUM_INPUTS or
                                      pending_addr + pending_len > NUM_INPUTS then
                                    build_error(tx_buf, tx_len, 3);
                                    tx_kick <= '1';
                                    cmd_pending <= '0';

                                else
                                    write_base_addr <= pending_addr;
                                    write_index <= 0;
                                    ack_cmd <= CMD_WRITE_INPUT;
                                    service_state <= WRITE_INPUT_STEP;
                                end if;

                            ----------------------------------------------------
                            -- STREAM_INPUT: one complete 784-byte image was
                            -- written directly into input BRAM by the parser.
                            ----------------------------------------------------
                            elsif pending_cmd = CMD_STREAM_INPUT then

                                if pending_stream_accepted = '0' or
                                   mlp_busy = '1' then
                                    build_error(tx_buf, tx_len, 1);
                                elsif pending_addr /= 0 or
                                      pending_len /= STREAM_IMAGE_BYTES then
                                    build_error(tx_buf, tx_len, 3);
                                else
                                    build_ack(tx_buf, tx_len, CMD_STREAM_INPUT);
                                end if;

                                tx_kick <= '1';
                                cmd_pending <= '0';
                                pending_stream_accepted <= '0';

                            ----------------------------------------------------
                            -- START
                            ----------------------------------------------------
                            elsif pending_cmd = CMD_START then

                                if mlp_busy = '1' then
                                    build_error(tx_buf, tx_len, 1);
                                else
                                    mlp_start <= '1';
                                    build_ack(tx_buf, tx_len, CMD_START);
                                end if;

                                tx_kick <= '1';
                                cmd_pending <= '0';

                            ----------------------------------------------------
                            -- STATUS
                            ----------------------------------------------------
                            elsif pending_cmd = CMD_STATUS then

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
                                cmd_pending <= '0';

                            ----------------------------------------------------
                            -- READ_OUTPUT
                            ----------------------------------------------------
                            elsif pending_cmd = CMD_READ_OUT then

                                tx_buf(0)  <= START_BYTE;
                                tx_buf(1)  <= CMD_OUT_DATA;
                                tx_buf(2)  <= BYTE_00;
                                tx_buf(3)  <= BYTE_00;
                                tx_buf(4)  <= std_logic_vector(to_unsigned(OUTPUT_PAYLOAD_BYTES / 256, 8));
                                tx_buf(5)  <= std_logic_vector(to_unsigned(OUTPUT_PAYLOAD_BYTES mod 256, 8));

                                cks := unsigned(START_BYTE)
                                     + unsigned(CMD_OUT_DATA)
                                     + u8(0) + u8(0)
                                     + to_unsigned(OUTPUT_PAYLOAD_BYTES / 256, 8)
                                     + to_unsigned(OUTPUT_PAYLOAD_BYTES mod 256, 8);

                                for i in 0 to NUM_OUTPUTS - 1 loop
                                    output_slv := std_logic_vector(mlp_outputs((i + 1) * 32 - 1 downto i * 32));

                                    tx_buf(6 + 4 * i + 0) <= output_slv(7 downto 0);
                                    tx_buf(6 + 4 * i + 1) <= output_slv(15 downto 8);
                                    tx_buf(6 + 4 * i + 2) <= output_slv(23 downto 16);
                                    tx_buf(6 + 4 * i + 3) <= output_slv(31 downto 24);

                                    cks := cks
                                         + unsigned(output_slv(7 downto 0))
                                         + unsigned(output_slv(15 downto 8))
                                         + unsigned(output_slv(23 downto 16))
                                         + unsigned(output_slv(31 downto 24));
                                end loop;

                                tx_buf(6 + OUTPUT_PAYLOAD_BYTES) <= std_logic_vector(cks);
                                tx_len     <= TX_BUF_SIZE;
                                tx_kick    <= '1';
                                cmd_pending <= '0';

                            ----------------------------------------------------
                            -- Unknown command
                            ----------------------------------------------------
                            else
                                build_error(tx_buf, tx_len, 2);
                                tx_kick <= '1';
                                cmd_pending <= '0';
                            end if;

                        end if;

                    ------------------------------------------------------------
                    -- Sequential BRAM writes
                    ------------------------------------------------------------
                    when WRITE_WEIGHT_STEP =>

                        weight_we <= '1';
                        weight_waddr <= to_unsigned(write_base_addr + write_index,
                                                    WEIGHT_ADDR_WIDTH);
                        weight_wdata <= signed(pending_payload(write_index));

                        if write_index = pending_len - 1 then
                            build_ack(tx_buf, tx_len, ack_cmd);
                            tx_kick <= '1';
                            cmd_pending <= '0';
                            service_state <= SERVICE_IDLE;
                        else
                            write_index <= write_index + 1;
                        end if;

                    when WRITE_INPUT_STEP =>

                        input_we <= '1';
                        input_waddr <= to_unsigned(write_base_addr + write_index,
                                                   INPUT_ADDR_WIDTH);
                        input_wdata <= signed(pending_payload(write_index));

                        if write_index = pending_len - 1 then
                            build_ack(tx_buf, tx_len, ack_cmd);
                            tx_kick <= '1';
                            cmd_pending <= '0';
                            service_state <= SERVICE_IDLE;
                        else
                            write_index <= write_index + 1;
                        end if;

                    when WRITE_BIAS_STEP =>

                        bias_we <= '1';
                        bias_waddr <= to_unsigned(write_base_addr + write_index,
                                                  BIAS_ADDR_WIDTH);

                        word32 := pending_payload(4 * write_index + 3)
                                & pending_payload(4 * write_index + 2)
                                & pending_payload(4 * write_index + 1)
                                & pending_payload(4 * write_index + 0);

                        bias_wdata <= signed(word32);

                        if write_index = (pending_len / 4) - 1 then
                            build_ack(tx_buf, tx_len, ack_cmd);
                            tx_kick <= '1';
                            cmd_pending <= '0';
                            service_state <= SERVICE_IDLE;
                        else
                            write_index <= write_index + 1;
                        end if;

                end case;

            end if;
        end if;
    end process;

end architecture;
