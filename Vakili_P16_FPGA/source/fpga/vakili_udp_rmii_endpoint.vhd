library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mlp_types_pkg.all;

-- Minimal 100BASE-TX RMII / ARP / IPv4 / UDP endpoint for the frozen P16
-- accelerator.  It deliberately implements one fixed IPv4 address and one UDP
-- port rather than a general-purpose network stack.  One UDP datagram carries
-- exactly one image; replies carry the matching sequence number and logits.
entity vakili_udp_rmii_endpoint is
    generic (
        BOARD_MAC : std_logic_vector(47 downto 0) := x"020000000702";
        BOARD_IP  : std_logic_vector(31 downto 0) := x"C0A80702";
        UDP_PORT  : integer := 5005
    );
    port (
        clk : in std_logic;
        rst : in std_logic;

        rmii_rx_ce : in std_logic;
        rmii_tx_ce : in std_logic;
        eth_crsdv  : in std_logic;
        eth_rxerr  : in std_logic;
        eth_rxd    : in std_logic_vector(1 downto 0);
        eth_txen   : out std_logic;
        eth_txd    : out std_logic_vector(1 downto 0);

        input_we    : out std_logic;
        input_waddr : out unsigned(INPUT_ADDR_WIDTH - 1 downto 0);
        input_wdata : out signed(7 downto 0);

        weight_we    : out std_logic;
        weight_waddr : out unsigned(WEIGHT_ADDR_WIDTH - 1 downto 0);
        weight_wdata : out signed(7 downto 0);

        bias_we    : out std_logic;
        bias_waddr : out unsigned(BIAS_ADDR_WIDTH - 1 downto 0);
        bias_wdata : out signed(31 downto 0);

        mlp_start   : out std_logic;
        mlp_busy    : in std_logic;
        mlp_complete : in std_logic;
        mlp_outputs : in signed(NUM_OUTPUTS * 32 - 1 downto 0);

        activity_pulse : out std_logic;
        error_pulse    : out std_logic;
        debug_diagnostics : out std_logic_vector(383 downto 0)
    );
end entity;

architecture rtl of vakili_udp_rmii_endpoint is
    constant ETH_TYPE_IPV4 : std_logic_vector(15 downto 0) := x"0800";
    constant ETH_TYPE_ARP  : std_logic_vector(15 downto 0) := x"0806";
    constant CRC_RESIDUE   : std_logic_vector(31 downto 0) := x"DEBB20E3";
    constant MAGIC         : std_logic_vector(31 downto 0) := x"56414B49"; -- VAKI
    constant PROTOCOL_VERSION : std_logic_vector(7 downto 0) := x"01";
    constant CMD_PING      : std_logic_vector(7 downto 0) := x"01";
    constant CMD_INFER     : std_logic_vector(7 downto 0) := x"02";
    constant CMD_WRITE_WEIGHT : std_logic_vector(7 downto 0) := x"03";
    constant CMD_WRITE_BIAS   : std_logic_vector(7 downto 0) := x"04";
    constant RSP_PING      : std_logic_vector(7 downto 0) := x"81";
    constant RSP_INFER     : std_logic_vector(7 downto 0) := x"82";
    constant RSP_WRITE_WEIGHT : std_logic_vector(7 downto 0) := x"83";
    constant RSP_WRITE_BIAS   : std_logic_vector(7 downto 0) := x"84";
    constant RSP_ERROR     : std_logic_vector(7 downto 0) := x"FF";
    constant APP_HEADER_BYTES : integer := 16;
    constant IMAGE_BYTES      : integer := NUM_INPUTS;
    constant PING_PAYLOAD_BYTES : integer := APP_HEADER_BYTES;
    constant INFER_REQUEST_BYTES : integer := APP_HEADER_BYTES + IMAGE_BYTES;
    constant INFER_RESPONSE_BYTES : integer := APP_HEADER_BYTES + 4 + NUM_OUTPUTS * 4;
    constant PING_DIAGNOSTIC_BYTES : integer := 16;
    constant WEIGHT_ADDRESS_LIMIT : integer := 52736;
    constant TX_BUFFER_BYTES : integer := 128;
    constant MIN_PREAMBLE_DIBITS : integer := 12;

    subtype byte_t is std_logic_vector(7 downto 0);
    type tx_buffer_t is array (0 to TX_BUFFER_BYTES - 1) of byte_t;
    type tx_state_t is (
        TX_IDLE,
        TX_CHECKSUM,
        TX_CHECKSUM_FOLD,
        TX_CHECKSUM_FINAL,
        TX_BUILD,
        TX_PREAMBLE,
        TX_DATA,
        TX_FCS,
        TX_IFG
    );

    constant RESPONSE_ARP   : std_logic_vector(1 downto 0) := "00";
    constant RESPONSE_PING  : std_logic_vector(1 downto 0) := "01";
    constant RESPONSE_INFER : std_logic_vector(1 downto 0) := "10";
    constant RESPONSE_ERROR : std_logic_vector(1 downto 0) := "11";

    signal rx_active : std_logic := '0';
    signal rx_in_frame : std_logic := '0';
    signal rx_nibble_sample_phase : std_logic := '0';
    signal rx_byte_nibble_index : std_logic := '0';
    signal rx_first_dibit : std_logic_vector(1 downto 0) := (others => '0');
    signal rx_first_dibit_error : std_logic := '0';
    signal rx_byte_shift : byte_t := (others => '0');
    signal rx_preamble_dibits : integer range 0 to 255 := 0;
    signal rx_frame_index : integer range 0 to 2047 := 0;
    signal rx_crc : std_logic_vector(31 downto 0) := (others => '1');
    signal rx_error_seen : std_logic := '0';

    signal rx_dest_board_match : std_logic := '1';
    signal rx_dest_broadcast_match : std_logic := '1';
    signal rx_eth_type : std_logic_vector(15 downto 0) := (others => '0');
    signal rx_source_mac : std_logic_vector(47 downto 0) := (others => '0');
    signal rx_source_ip : std_logic_vector(31 downto 0) := (others => '0');
    signal rx_source_port : std_logic_vector(15 downto 0) := (others => '0');
    signal rx_sequence : std_logic_vector(31 downto 0) := (others => '0');
    signal rx_command : byte_t := (others => '0');
    signal rx_ip_total_length : integer range 0 to 65535 := 0;
    signal rx_udp_length : integer range 0 to 65535 := 0;
    signal rx_body_length : integer range 0 to 65535 := 0;
    signal rx_image_count : integer range 0 to IMAGE_BYTES := 0;
    signal rx_parameter_address : integer range 0 to 65535 := 0;
    signal rx_parameter_count : integer range 0 to 2047 := 0;
    signal rx_bias_word : std_logic_vector(31 downto 0) := (others => '0');
    signal rx_ipv4_valid : std_logic := '1';
    signal rx_udp_valid : std_logic := '1';
    signal rx_app_valid : std_logic := '1';
    signal rx_arp_valid : std_logic := '1';

    signal awaiting_inference : std_logic := '0';
    signal job_source_mac : std_logic_vector(47 downto 0) := (others => '0');
    signal job_source_ip : std_logic_vector(31 downto 0) := (others => '0');
    signal job_source_port : std_logic_vector(15 downto 0) := (others => '0');
    signal job_sequence : std_logic_vector(31 downto 0) := (others => '0');

    signal response_valid : std_logic := '0';
    signal response_taken : std_logic := '0';
    signal response_kind : std_logic_vector(1 downto 0) := RESPONSE_PING;
    signal response_status : byte_t := x"00";
    signal response_command : byte_t := RSP_ERROR;
    signal response_dest_mac : std_logic_vector(47 downto 0) := (others => '0');
    signal response_dest_ip : std_logic_vector(31 downto 0) := (others => '0');
    signal response_dest_port : std_logic_vector(15 downto 0) := (others => '0');
    signal response_sequence : std_logic_vector(31 downto 0) := (others => '0');

    -- Sticky receive/inference diagnostics.  Every PING response returns this
    -- 16-byte snapshot, which makes a failed long inference transaction
    -- debuggable without rebuilding the FPGA or relying on human-visible LEDs.
    signal diagnostic_flags : std_logic_vector(15 downto 0) := (others => '0');
    signal diag_last_frame_bytes : integer range 0 to 65535 := 0;
    signal diag_last_image_bytes : integer range 0 to 65535 := 0;
    signal diag_last_body_length : integer range 0 to 65535 := 0;
    signal diag_last_udp_length : integer range 0 to 65535 := 0;
    signal diag_last_ip_length : integer range 0 to 65535 := 0;
    signal diag_last_sequence : std_logic_vector(31 downto 0) := (others => '0');
    signal response_diagnostics : std_logic_vector(127 downto 0);
    signal live_diagnostic_flags : std_logic_vector(15 downto 0);
    signal rx_carrier_event_count : integer range 0 to 65535 := 0;
    signal rx_sfd_count : integer range 0 to 65535 := 0;
    signal rx_completed_frame_count : integer range 0 to 65535 := 0;
    signal rx_good_fcs_count : integer range 0 to 65535 := 0;
    signal rx_no_sfd_count : integer range 0 to 65535 := 0;
    signal rx_last_preamble_dibits : integer range 0 to 65535 := 0;
    signal rx_last_completed_frame_bytes : integer range 0 to 65535 := 0;
    signal rx_last_command : byte_t := (others => '0');

    signal tx_buffer : tx_buffer_t := (others => (others => '0'));
    signal tx_data_length : integer range 0 to TX_BUFFER_BYTES := 0;
    signal tx_state : tx_state_t := TX_IDLE;
    signal tx_kind : std_logic_vector(1 downto 0) := RESPONSE_PING;
    signal tx_status : byte_t := x"00";
    signal tx_dest_mac : std_logic_vector(47 downto 0) := (others => '0');
    signal tx_dest_ip : std_logic_vector(31 downto 0) := (others => '0');
    signal tx_dest_port : std_logic_vector(15 downto 0) := (others => '0');
    signal tx_sequence : std_logic_vector(31 downto 0) := (others => '0');
    signal tx_outputs : signed(NUM_OUTPUTS * 32 - 1 downto 0) := (others => '0');
    signal tx_diagnostics : std_logic_vector(127 downto 0) := (others => '0');
    signal tx_ip_total_length : integer range 0 to 1500 := 0;
    signal tx_udp_length : integer range 0 to 1500 := 0;
    signal tx_body_length : integer range 0 to INFER_RESPONSE_BYTES := 0;
    signal tx_frame_length : integer range 0 to TX_BUFFER_BYTES := 0;
    signal tx_command : byte_t := RSP_PING;
    signal tx_checksum_acc : unsigned(19 downto 0) := (others => '0');
    signal tx_checksum_fold_sum : unsigned(16 downto 0) := (others => '0');
    signal tx_checksum_index : integer range 0 to 8 := 0;
    signal tx_ipv4_checksum : std_logic_vector(15 downto 0) := (others => '0');
    signal tx_preamble_byte : integer range 0 to 7 := 0;
    signal tx_byte_index : integer range 0 to TX_BUFFER_BYTES := 0;
    signal tx_dibit_index : integer range 0 to 3 := 0;
    signal tx_crc : std_logic_vector(31 downto 0) := (others => '1');
    signal tx_fcs_value : std_logic_vector(31 downto 0) := (others => '0');
    signal tx_fcs_dibit : integer range 0 to 15 := 0;
    signal tx_ifg_dibit : integer range 0 to 47 := 0;

    function mac_byte(value : std_logic_vector(47 downto 0);
                      index : integer) return byte_t is
    begin
        return value(47 - index * 8 downto 40 - index * 8);
    end function;

    function ip_byte(value : std_logic_vector(31 downto 0);
                     index : integer) return byte_t is
    begin
        return value(31 - index * 8 downto 24 - index * 8);
    end function;

    function crc32_dibit(
        current : std_logic_vector(31 downto 0);
        data    : std_logic_vector(1 downto 0)
    ) return std_logic_vector is
        variable value : std_logic_vector(31 downto 0) := current;
        variable mix : std_logic;
    begin
        for bit_index in 0 to 1 loop
            mix := value(0) xor data(bit_index);
            value := '0' & value(31 downto 1);
            if mix = '1' then
                value := value xor x"EDB88320";
            end if;
        end loop;
        return value;
    end function;

    function select_dibit(value : byte_t; index : integer)
        return std_logic_vector is
    begin
        case index is
            when 0 => return value(1 downto 0);
            when 1 => return value(3 downto 2);
            when 2 => return value(5 downto 4);
            when others => return value(7 downto 6);
        end case;
    end function;

    procedure put_u16(
        signal buffer_value : out tx_buffer_t;
        base : in integer;
        value : in std_logic_vector(15 downto 0)
    ) is
    begin
        buffer_value(base) <= value(15 downto 8);
        buffer_value(base + 1) <= value(7 downto 0);
    end procedure;

    procedure put_u32(
        signal buffer_value : out tx_buffer_t;
        base : in integer;
        value : in std_logic_vector(31 downto 0)
    ) is
    begin
        buffer_value(base) <= value(31 downto 24);
        buffer_value(base + 1) <= value(23 downto 16);
        buffer_value(base + 2) <= value(15 downto 8);
        buffer_value(base + 3) <= value(7 downto 0);
    end procedure;

    procedure put_mac(
        signal buffer_value : out tx_buffer_t;
        base : in integer;
        value : in std_logic_vector(47 downto 0)
    ) is
    begin
        for index in 0 to 5 loop
            buffer_value(base + index) <= mac_byte(value, index);
        end loop;
    end procedure;

    procedure build_arp_response(
        signal buffer_value : out tx_buffer_t;
        signal data_length : out integer;
        destination_mac : in std_logic_vector(47 downto 0);
        destination_ip : in std_logic_vector(31 downto 0)
    ) is
    begin
        put_mac(buffer_value, 0, destination_mac);
        put_mac(buffer_value, 6, BOARD_MAC);
        put_u16(buffer_value, 12, ETH_TYPE_ARP);
        put_u16(buffer_value, 14, x"0001");
        put_u16(buffer_value, 16, ETH_TYPE_IPV4);
        buffer_value(18) <= x"06";
        buffer_value(19) <= x"04";
        put_u16(buffer_value, 20, x"0002");
        put_mac(buffer_value, 22, BOARD_MAC);
        put_u32(buffer_value, 28, BOARD_IP);
        put_mac(buffer_value, 32, destination_mac);
        put_u32(buffer_value, 38, destination_ip);
        for index in 42 to 59 loop
            buffer_value(index) <= x"00";
        end loop;
        data_length <= 60;
    end procedure;

    procedure build_udp_response(
        signal buffer_value : out tx_buffer_t;
        signal data_length : out integer;
        kind : in std_logic_vector(1 downto 0);
        status : in byte_t;
        destination_mac : in std_logic_vector(47 downto 0);
        destination_ip : in std_logic_vector(31 downto 0);
        destination_port : in std_logic_vector(15 downto 0);
        sequence_value : in std_logic_vector(31 downto 0);
        outputs : in signed(NUM_OUTPUTS * 32 - 1 downto 0);
        diagnostics : in std_logic_vector(127 downto 0);
        ip_total_length : in integer;
        udp_length : in integer;
        body_length : in integer;
        frame_length : in integer;
        command : in byte_t;
        checksum : in std_logic_vector(15 downto 0)
    ) is
        variable identification : std_logic_vector(15 downto 0);
        variable logit : std_logic_vector(31 downto 0);
    begin
        identification := sequence_value(15 downto 0);

        put_mac(buffer_value, 0, destination_mac);
        put_mac(buffer_value, 6, BOARD_MAC);
        put_u16(buffer_value, 12, ETH_TYPE_IPV4);
        buffer_value(14) <= x"45";
        buffer_value(15) <= x"00";
        put_u16(buffer_value, 16, std_logic_vector(to_unsigned(ip_total_length, 16)));
        put_u16(buffer_value, 18, identification);
        put_u16(buffer_value, 20, x"4000");
        buffer_value(22) <= x"40";
        buffer_value(23) <= x"11";
        put_u16(buffer_value, 24, checksum);
        put_u32(buffer_value, 26, BOARD_IP);
        put_u32(buffer_value, 30, destination_ip);
        put_u16(buffer_value, 34, std_logic_vector(to_unsigned(UDP_PORT, 16)));
        put_u16(buffer_value, 36, destination_port);
        put_u16(buffer_value, 38, std_logic_vector(to_unsigned(udp_length, 16)));
        put_u16(buffer_value, 40, x"0000"); -- Legal for UDP over IPv4.

        put_u32(buffer_value, 42, MAGIC);
        buffer_value(46) <= PROTOCOL_VERSION;
        buffer_value(47) <= command;
        buffer_value(48) <= status;
        buffer_value(49) <= std_logic_vector(to_unsigned(APP_HEADER_BYTES, 8));
        put_u32(buffer_value, 50, sequence_value);
        put_u16(
            buffer_value, 54,
            std_logic_vector(to_unsigned(body_length, 16))
        );
        buffer_value(56) <= x"10"; -- P16 lane count.
        buffer_value(57) <= x"00";

        if kind = RESPONSE_INFER then
            -- Prediction is intentionally derived from the returned logits by
            -- the host. A combinational ten-way argmax created a 52-level,
            -- 28 ns path and duplicated information already in this packet.
            buffer_value(58) <= x"00";
            buffer_value(59) <= x"00";
            buffer_value(60) <= x"00";
            buffer_value(61) <= x"00";
            for index in 0 to NUM_OUTPUTS - 1 loop
                logit := std_logic_vector(
                    outputs((index + 1) * 32 - 1 downto index * 32)
                );
                put_u32(buffer_value, 62 + 4 * index, logit);
            end loop;
        elsif kind = RESPONSE_PING then
            for index in 0 to PING_DIAGNOSTIC_BYTES - 1 loop
                buffer_value(58 + index) <= diagnostics(
                    127 - index * 8 downto 120 - index * 8
                );
            end loop;
        else
            -- Minimum Ethernet payload padding after the 16-byte app header.
            buffer_value(58) <= x"00";
            buffer_value(59) <= x"00";
        end if;
        data_length <= frame_length;
    end procedure;
begin
    response_diagnostics <=
        diagnostic_flags &
        std_logic_vector(to_unsigned(diag_last_frame_bytes, 16)) &
        std_logic_vector(to_unsigned(diag_last_image_bytes, 16)) &
        std_logic_vector(to_unsigned(diag_last_body_length, 16)) &
        std_logic_vector(to_unsigned(diag_last_udp_length, 16)) &
        std_logic_vector(to_unsigned(diag_last_ip_length, 16)) &
        diag_last_sequence;

    -- The first sixteen bytes match the PING diagnostic body.  The next
    -- sixteen are live state and the final sixteen are receive counters for
    -- the independent UART debug command, which remains readable even if
    -- Ethernet transmission is wedged.
    live_diagnostic_flags <=
        "000000" & rmii_tx_ce & rmii_rx_ce & eth_rxerr & eth_crsdv &
        response_taken & rx_in_frame & rx_active & mlp_busy &
        awaiting_inference & response_valid;
    debug_diagnostics <=
        response_diagnostics &
        live_diagnostic_flags &
        std_logic_vector(to_unsigned(tx_state_t'pos(tx_state), 16)) &
        std_logic_vector(to_unsigned(tx_data_length, 16)) &
        std_logic_vector(to_unsigned(tx_byte_index, 16)) &
        std_logic_vector(to_unsigned(tx_dibit_index, 16)) &
        std_logic_vector(to_unsigned(tx_ifg_dibit, 16)) &
        std_logic_vector(to_unsigned(rx_frame_index, 16)) &
        std_logic_vector(to_unsigned(to_integer(unsigned(response_kind)), 16)) &
        std_logic_vector(to_unsigned(rx_carrier_event_count, 16)) &
        std_logic_vector(to_unsigned(rx_sfd_count, 16)) &
        std_logic_vector(to_unsigned(rx_completed_frame_count, 16)) &
        std_logic_vector(to_unsigned(rx_good_fcs_count, 16)) &
        std_logic_vector(to_unsigned(rx_no_sfd_count, 16)) &
        std_logic_vector(to_unsigned(rx_last_preamble_dibits, 16)) &
        std_logic_vector(to_unsigned(rx_last_completed_frame_bytes, 16)) &
        x"00" & rx_last_command;

    rx_and_control : process(clk)
        variable assembled_byte : byte_t;
        variable assembled_nibble : std_logic_vector(3 downto 0);
        variable next_crc : std_logic_vector(31 downto 0);
        variable byte_index : integer;
        variable common_ipv4_valid : boolean;
        variable common_arp_valid : boolean;
        variable parameter_bias_word : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rx_active <= '0';
                rx_in_frame <= '0';
                rx_nibble_sample_phase <= '0';
                rx_byte_nibble_index <= '0';
                rx_first_dibit <= (others => '0');
                rx_first_dibit_error <= '0';
                rx_byte_shift <= (others => '0');
                rx_preamble_dibits <= 0;
                rx_frame_index <= 0;
                rx_crc <= (others => '1');
                rx_error_seen <= '0';
                rx_dest_board_match <= '1';
                rx_dest_broadcast_match <= '1';
                rx_eth_type <= (others => '0');
                rx_source_mac <= (others => '0');
                rx_source_ip <= (others => '0');
                rx_source_port <= (others => '0');
                rx_sequence <= (others => '0');
                rx_command <= (others => '0');
                rx_ip_total_length <= 0;
                rx_udp_length <= 0;
                rx_body_length <= 0;
                rx_image_count <= 0;
                rx_parameter_address <= 0;
                rx_parameter_count <= 0;
                rx_bias_word <= (others => '0');
                rx_ipv4_valid <= '1';
                rx_udp_valid <= '1';
                rx_app_valid <= '1';
                rx_arp_valid <= '1';
                awaiting_inference <= '0';
                job_source_mac <= (others => '0');
                job_source_ip <= (others => '0');
                job_source_port <= (others => '0');
                job_sequence <= (others => '0');
                response_valid <= '0';
                response_kind <= RESPONSE_PING;
                response_status <= x"00";
                response_command <= RSP_ERROR;
                response_dest_mac <= (others => '0');
                response_dest_ip <= (others => '0');
                response_dest_port <= (others => '0');
                response_sequence <= (others => '0');
                diagnostic_flags <= (others => '0');
                diag_last_frame_bytes <= 0;
                diag_last_image_bytes <= 0;
                diag_last_body_length <= 0;
                diag_last_udp_length <= 0;
                diag_last_ip_length <= 0;
                diag_last_sequence <= (others => '0');
                rx_carrier_event_count <= 0;
                rx_sfd_count <= 0;
                rx_completed_frame_count <= 0;
                rx_good_fcs_count <= 0;
                rx_no_sfd_count <= 0;
                rx_last_preamble_dibits <= 0;
                rx_last_completed_frame_bytes <= 0;
                rx_last_command <= (others => '0');
                input_we <= '0';
                input_waddr <= (others => '0');
                input_wdata <= (others => '0');
                weight_we <= '0';
                weight_waddr <= (others => '0');
                weight_wdata <= (others => '0');
                bias_we <= '0';
                bias_waddr <= (others => '0');
                bias_wdata <= (others => '0');
                mlp_start <= '0';
                activity_pulse <= '0';
                error_pulse <= '0';
            else
                input_we <= '0';
                weight_we <= '0';
                bias_we <= '0';
                mlp_start <= '0';
                activity_pulse <= '0';
                error_pulse <= '0';

                if response_taken = '1' then
                    response_valid <= '0';
                end if;

                if awaiting_inference = '1' and mlp_busy = '1' then
                    diagnostic_flags(4) <= '1'; -- accelerator reported busy
                end if;

                if awaiting_inference = '1' and mlp_complete = '1' then
                    diagnostic_flags(5) <= '1'; -- completion event observed
                    if response_valid = '0' then
                        diagnostic_flags(6) <= '1'; -- inference reply queued
                        awaiting_inference <= '0';
                        response_valid <= '1';
                        response_kind <= RESPONSE_INFER;
                        response_status <= x"00";
                        response_dest_mac <= job_source_mac;
                        response_dest_ip <= job_source_ip;
                        response_dest_port <= job_source_port;
                        response_sequence <= job_sequence;
                    end if;
                end if;

                if rmii_rx_ce = '1' then
                    if rx_in_frame = '0' then
                        -- CRS_DV may assert part-way through a dibit and the
                        -- LAN8720A is allowed to present leading 00 dibits
                        -- while its receive decoder acquires the carrier.  Do
                        -- not use that asynchronous assertion as byte phase.
                        -- Instead, find the run of 01 preamble dibits followed
                        -- by the SFD's final 11 dibit.
                        if eth_crsdv = '1' then
                            if rx_active = '0' then
                                rx_active <= '1';
                                if rx_carrier_event_count < 65535 then
                                    rx_carrier_event_count <=
                                        rx_carrier_event_count + 1;
                                end if;
                                if eth_rxd = "01" then
                                    rx_preamble_dibits <= 1;
                                else
                                    rx_preamble_dibits <= 0;
                                end if;
                                rx_frame_index <= 0;
                                rx_crc <= (others => '1');
                                rx_error_seen <= eth_rxerr;
                                rx_dest_board_match <= '1';
                                rx_dest_broadcast_match <= '1';
                                rx_eth_type <= (others => '0');
                                rx_source_mac <= (others => '0');
                                rx_source_ip <= (others => '0');
                                rx_source_port <= (others => '0');
                                rx_sequence <= (others => '0');
                                rx_command <= (others => '0');
                                rx_ip_total_length <= 0;
                                rx_udp_length <= 0;
                                rx_body_length <= 0;
                                rx_image_count <= 0;
                                rx_parameter_address <= 0;
                                rx_parameter_count <= 0;
                                rx_bias_word <= (others => '0');
                                rx_ipv4_valid <= '1';
                                rx_udp_valid <= '1';
                                rx_app_valid <= '1';
                                rx_arp_valid <= '1';
                            else
                                if eth_rxerr = '1' then
                                    rx_error_seen <= '1';
                                end if;
                                if eth_rxd = "01" then
                                    if rx_preamble_dibits < 255 then
                                        rx_preamble_dibits <=
                                            rx_preamble_dibits + 1;
                                    end if;
                                elsif eth_rxd = "11" and
                                      rx_preamble_dibits >=
                                          MIN_PREAMBLE_DIBITS then
                                    rx_in_frame <= '1';
                                    rx_nibble_sample_phase <= '0';
                                    rx_byte_nibble_index <= '0';
                                    rx_frame_index <= 0;
                                    rx_crc <= (others => '1');
                                    rx_last_preamble_dibits <=
                                        rx_preamble_dibits;
                                    if rx_sfd_count < 65535 then
                                        rx_sfd_count <= rx_sfd_count + 1;
                                    end if;
                                else
                                    rx_preamble_dibits <= 0;
                                end if;
                            end if;
                        elsif rx_active = '1' then
                            -- Carrier ended before an SFD was found.  Keeping
                            -- this separate from completed frames makes clock
                            -- phase/noise failures immediately visible over
                            -- the out-of-band UART diagnostic command.
                            rx_active <= '0';
                            rx_last_preamble_dibits <= rx_preamble_dibits;
                            rx_preamble_dibits <= 0;
                            if rx_no_sfd_count < 65535 then
                                rx_no_sfd_count <= rx_no_sfd_count + 1;
                            end if;
                        end if;
                    else
                        -- The LAN8720A multiplexes CRS and recovered RXDV on
                        -- CRS_DV.  When carrier ends while receive data is
                        -- still draining, consecutive samples may alternate
                        -- low/high.  The second dibit of each nibble carries
                        -- the usable RXDV indication, so decide nibble validity
                        -- only after both dibits have been captured.
                        if rx_nibble_sample_phase = '0' then
                            rx_first_dibit <= eth_rxd;
                            rx_first_dibit_error <= eth_rxerr;
                            rx_nibble_sample_phase <= '1';
                        else
                            rx_nibble_sample_phase <= '0';
                            if eth_crsdv = '1' then
                                assembled_nibble := eth_rxd & rx_first_dibit;
                                next_crc := crc32_dibit(
                                    crc32_dibit(rx_crc, rx_first_dibit),
                                    eth_rxd
                                );
                                rx_crc <= next_crc;
                                if rx_first_dibit_error = '1' or
                                   eth_rxerr = '1' then
                                    rx_error_seen <= '1';
                                end if;

                                if rx_byte_nibble_index = '0' then
                                    rx_byte_shift(3 downto 0) <=
                                        assembled_nibble;
                                    rx_byte_nibble_index <= '1';
                                else
                                    assembled_byte :=
                                        assembled_nibble &
                                        rx_byte_shift(3 downto 0);
                                    rx_byte_nibble_index <= '0';
                                byte_index := rx_frame_index;
                                if rx_frame_index < 2047 then
                                    rx_frame_index <= rx_frame_index + 1;
                                end if;

                                if byte_index >= 0 and byte_index <= 5 then
                                    if assembled_byte /= mac_byte(BOARD_MAC, byte_index) then
                                        rx_dest_board_match <= '0';
                                    end if;
                                    if assembled_byte /= x"FF" then
                                        rx_dest_broadcast_match <= '0';
                                    end if;
                                elsif byte_index >= 6 and byte_index <= 11 then
                                    rx_source_mac(47 - (byte_index - 6) * 8 downto
                                                  40 - (byte_index - 6) * 8) <= assembled_byte;
                                elsif byte_index = 12 then
                                    rx_eth_type(15 downto 8) <= assembled_byte;
                                elsif byte_index = 13 then
                                    rx_eth_type(7 downto 0) <= assembled_byte;
                                end if;

                                -- ARP request validation and sender capture.
                                if rx_eth_type = ETH_TYPE_ARP then
                                case byte_index is
                                    when 14 => if assembled_byte /= x"00" then rx_arp_valid <= '0'; end if;
                                    when 15 => if assembled_byte /= x"01" then rx_arp_valid <= '0'; end if;
                                    when 16 => if assembled_byte /= x"08" then rx_arp_valid <= '0'; end if;
                                    when 17 => if assembled_byte /= x"00" then rx_arp_valid <= '0'; end if;
                                    when 18 => if assembled_byte /= x"06" then rx_arp_valid <= '0'; end if;
                                    when 19 => if assembled_byte /= x"04" then rx_arp_valid <= '0'; end if;
                                    when 20 => if assembled_byte /= x"00" then rx_arp_valid <= '0'; end if;
                                    when 21 => if assembled_byte /= x"01" then rx_arp_valid <= '0'; end if;
                                    when 28 => rx_source_ip(31 downto 24) <= assembled_byte;
                                    when 29 => rx_source_ip(23 downto 16) <= assembled_byte;
                                    when 30 => rx_source_ip(15 downto 8) <= assembled_byte;
                                    when 31 => rx_source_ip(7 downto 0) <= assembled_byte;
                                    when 38 => if assembled_byte /= BOARD_IP(31 downto 24) then rx_arp_valid <= '0'; end if;
                                    when 39 => if assembled_byte /= BOARD_IP(23 downto 16) then rx_arp_valid <= '0'; end if;
                                    when 40 => if assembled_byte /= BOARD_IP(15 downto 8) then rx_arp_valid <= '0'; end if;
                                    when 41 => if assembled_byte /= BOARD_IP(7 downto 0) then rx_arp_valid <= '0'; end if;
                                    when others => null;
                                end case;
                                end if;

                                -- Fixed IPv4/UDP header validation.
                                if rx_eth_type = ETH_TYPE_IPV4 then
                                case byte_index is
                                    when 14 => if assembled_byte /= x"45" then rx_ipv4_valid <= '0'; end if;
                                    when 16 => rx_ip_total_length <= to_integer(unsigned(assembled_byte)) * 256;
                                    when 17 => rx_ip_total_length <= rx_ip_total_length + to_integer(unsigned(assembled_byte));
                                    when 23 => if assembled_byte /= x"11" then rx_ipv4_valid <= '0'; end if;
                                    when 26 => rx_source_ip(31 downto 24) <= assembled_byte;
                                    when 27 => rx_source_ip(23 downto 16) <= assembled_byte;
                                    when 28 => rx_source_ip(15 downto 8) <= assembled_byte;
                                    when 29 => rx_source_ip(7 downto 0) <= assembled_byte;
                                    when 30 => if assembled_byte /= BOARD_IP(31 downto 24) then rx_ipv4_valid <= '0'; end if;
                                    when 31 => if assembled_byte /= BOARD_IP(23 downto 16) then rx_ipv4_valid <= '0'; end if;
                                    when 32 => if assembled_byte /= BOARD_IP(15 downto 8) then rx_ipv4_valid <= '0'; end if;
                                    when 33 => if assembled_byte /= BOARD_IP(7 downto 0) then rx_ipv4_valid <= '0'; end if;
                                    when 34 => rx_source_port(15 downto 8) <= assembled_byte;
                                    when 35 => rx_source_port(7 downto 0) <= assembled_byte;
                                    when 36 => if assembled_byte /= std_logic_vector(to_unsigned(UDP_PORT / 256, 8)) then rx_udp_valid <= '0'; end if;
                                    when 37 => if assembled_byte /= std_logic_vector(to_unsigned(UDP_PORT mod 256, 8)) then rx_udp_valid <= '0'; end if;
                                    when 38 => rx_udp_length <= to_integer(unsigned(assembled_byte)) * 256;
                                    when 39 => rx_udp_length <= rx_udp_length + to_integer(unsigned(assembled_byte));
                                    when others => null;
                                end case;

                                -- Application header and image body.
                                case byte_index is
                                    when 42 => if assembled_byte /= MAGIC(31 downto 24) then rx_app_valid <= '0'; end if;
                                    when 43 => if assembled_byte /= MAGIC(23 downto 16) then rx_app_valid <= '0'; end if;
                                    when 44 => if assembled_byte /= MAGIC(15 downto 8) then rx_app_valid <= '0'; end if;
                                    when 45 => if assembled_byte /= MAGIC(7 downto 0) then rx_app_valid <= '0'; end if;
                                    when 46 => if assembled_byte /= PROTOCOL_VERSION then rx_app_valid <= '0'; end if;
                                    when 47 => rx_command <= assembled_byte;
                                    when 49 => if assembled_byte /= std_logic_vector(to_unsigned(APP_HEADER_BYTES, 8)) then rx_app_valid <= '0'; end if;
                                    when 50 => rx_sequence(31 downto 24) <= assembled_byte;
                                    when 51 => rx_sequence(23 downto 16) <= assembled_byte;
                                    when 52 => rx_sequence(15 downto 8) <= assembled_byte;
                                    when 53 => rx_sequence(7 downto 0) <= assembled_byte;
                                    when 54 => rx_body_length <= to_integer(unsigned(assembled_byte)) * 256;
                                    when 55 => rx_body_length <= rx_body_length + to_integer(unsigned(assembled_byte));
                                    when 56 => rx_parameter_address <= to_integer(unsigned(assembled_byte)) * 256;
                                    when 57 => rx_parameter_address <= rx_parameter_address + to_integer(unsigned(assembled_byte));
                                    when others => null;
                                end case;

                                if rx_command = CMD_INFER and
                                   byte_index >= 58 and
                                   byte_index < 58 + IMAGE_BYTES then
                                    input_we <= '1';
                                    input_waddr <= to_unsigned(
                                        byte_index - 58, INPUT_ADDR_WIDTH
                                    );
                                    input_wdata <= signed(assembled_byte);
                                    if rx_image_count < IMAGE_BYTES then
                                        rx_image_count <= rx_image_count + 1;
                                    end if;
                                end if;

                                -- Parameter writes reuse the application's
                                -- final 16-bit header field as a base address.
                                -- Weight addresses count bytes in the banked
                                -- {bank_address,lane} layout. Bias addresses
                                -- count 32-bit words; their payload is network
                                -- byte order. Writes are idempotent, so a host
                                -- may safely retry a chunk whose ACK was lost.
                                if (rx_command = CMD_WRITE_WEIGHT or
                                    rx_command = CMD_WRITE_BIAS) and
                                   rx_dest_board_match = '1' and
                                   rx_ipv4_valid = '1' and
                                   rx_udp_valid = '1' and
                                   rx_app_valid = '1' and
                                   byte_index >= 58 and
                                   byte_index < 58 + rx_body_length then
                                    if rx_parameter_count < 2047 then
                                        rx_parameter_count <=
                                            rx_parameter_count + 1;
                                    end if;

                                    if rx_command = CMD_WRITE_WEIGHT and
                                       mlp_busy = '0' and
                                       awaiting_inference = '0' and
                                       rx_parameter_address +
                                           (byte_index - 58) <
                                           WEIGHT_ADDRESS_LIMIT then
                                        weight_we <= '1';
                                        weight_waddr <= to_unsigned(
                                            rx_parameter_address +
                                                (byte_index - 58),
                                            WEIGHT_ADDR_WIDTH
                                        );
                                        weight_wdata <= signed(assembled_byte);
                                    elsif rx_command = CMD_WRITE_BIAS then
                                        case (byte_index - 58) mod 4 is
                                            when 0 =>
                                                rx_bias_word(31 downto 24) <=
                                                    assembled_byte;
                                            when 1 =>
                                                rx_bias_word(23 downto 16) <=
                                                    assembled_byte;
                                            when 2 =>
                                                rx_bias_word(15 downto 8) <=
                                                    assembled_byte;
                                            when others =>
                                                rx_bias_word(7 downto 0) <=
                                                    assembled_byte;
                                                if mlp_busy = '0' and
                                                   awaiting_inference = '0' and
                                                   rx_parameter_address +
                                                       ((byte_index - 58) / 4) <
                                                       NUM_BIASES then
                                                    bias_we <= '1';
                                                    bias_waddr <= to_unsigned(
                                                        rx_parameter_address +
                                                            ((byte_index - 58) / 4),
                                                        BIAS_ADDR_WIDTH
                                                    );
                                                    parameter_bias_word :=
                                                        rx_bias_word;
                                                    parameter_bias_word(
                                                        7 downto 0
                                                    ) := assembled_byte;
                                                    bias_wdata <= signed(
                                                        parameter_bias_word
                                                    );
                                                end if;
                                        end case;
                                    end if;
                                end if;
                                end if; -- IPv4 parser
                            end if; -- second nibble completes a byte
                        else
                            -- A low second-dibit CRS_DV is recovered RXDV=0,
                            -- not necessarily the first raw low sample after
                            -- carrier loss.  Finalize only on this boundary so
                            -- the residual frame bytes and FCS are not cut off.
                            rx_active <= '0';
                            rx_preamble_dibits <= 0;
                            rx_byte_nibble_index <= '0';
                            if rx_completed_frame_count < 65535 then
                                rx_completed_frame_count <=
                                    rx_completed_frame_count + 1;
                            end if;
                            rx_last_completed_frame_bytes <= rx_frame_index;
                            rx_last_command <= rx_command;
                            if rx_crc = CRC_RESIDUE and
                               rx_error_seen = '0' then
                                if rx_good_fcs_count < 65535 then
                                    rx_good_fcs_count <=
                                        rx_good_fcs_count + 1;
                                end if;
                            end if;
                            common_arp_valid :=
                                rx_in_frame = '1' and
                            rx_crc = CRC_RESIDUE and
                            rx_error_seen = '0' and
                            rx_eth_type = ETH_TYPE_ARP and
                            (rx_dest_broadcast_match = '1' or
                             rx_dest_board_match = '1') and
                            rx_arp_valid = '1';
                        common_ipv4_valid :=
                            rx_in_frame = '1' and
                            rx_crc = CRC_RESIDUE and
                            rx_error_seen = '0' and
                            rx_dest_board_match = '1' and
                            rx_eth_type = ETH_TYPE_IPV4 and
                            rx_ipv4_valid = '1' and
                            rx_udp_valid = '1' and
                            rx_app_valid = '1';

                        -- Preserve exactly how far the most recent inference
                        -- request progressed.  This remains readable through
                        -- a subsequent short PING even if no inference reply
                        -- was produced.
                        if rx_in_frame = '1' and rx_command = CMD_INFER then
                            -- Host retries retain the same sequence number.
                            -- Preserve the first attempt's later-stage flags
                            -- rather than replacing them with a busy retry.
                            if rx_sequence /= diag_last_sequence then
                                diagnostic_flags <= (others => '0');
                            end if;
                            diagnostic_flags(0) <= '1'; -- command observed
                            diag_last_frame_bytes <= rx_frame_index;
                            diag_last_image_bytes <= rx_image_count;
                            diag_last_body_length <= rx_body_length;
                            diag_last_udp_length <= rx_udp_length;
                            diag_last_ip_length <= rx_ip_total_length;
                            diag_last_sequence <= rx_sequence;

                            if common_ipv4_valid then
                                diagnostic_flags(1) <= '1';
                            end if;
                            if common_ipv4_valid and
                               rx_body_length = IMAGE_BYTES and
                               rx_image_count = IMAGE_BYTES and
                               rx_udp_length = 8 + INFER_REQUEST_BYTES and
                               rx_ip_total_length = 20 + 8 + INFER_REQUEST_BYTES then
                                diagnostic_flags(2) <= '1';
                            end if;
                        end if;

                        if rx_in_frame = '1' and rx_crc /= CRC_RESIDUE then
                            diagnostic_flags(7) <= '1'; -- bad Ethernet FCS
                        end if;
                        if rx_in_frame = '1' and rx_error_seen = '1' then
                            diagnostic_flags(8) <= '1'; -- PHY RX error
                        end if;

                        if common_arp_valid and response_valid = '0' and
                           awaiting_inference = '0' then
                            response_valid <= '1';
                            response_kind <= RESPONSE_ARP;
                            response_status <= x"00";
                            response_dest_mac <= rx_source_mac;
                            response_dest_ip <= rx_source_ip;
                            response_dest_port <= (others => '0');
                            response_sequence <= (others => '0');
                            activity_pulse <= '1';
                        elsif common_ipv4_valid and
                              rx_command = CMD_PING and
                              rx_body_length = 0 and
                              rx_udp_length = 8 + PING_PAYLOAD_BYTES and
                              rx_ip_total_length = 20 + 8 + PING_PAYLOAD_BYTES and
                              response_valid = '0' and
                              awaiting_inference = '0' then
                            response_valid <= '1';
                            response_kind <= RESPONSE_PING;
                            response_status <= x"00";
                            response_dest_mac <= rx_source_mac;
                            response_dest_ip <= rx_source_ip;
                            response_dest_port <= rx_source_port;
                            response_sequence <= rx_sequence;
                            activity_pulse <= '1';
                        elsif common_ipv4_valid and
                              (rx_command = CMD_WRITE_WEIGHT or
                               rx_command = CMD_WRITE_BIAS) and
                              response_valid = '0' and
                              awaiting_inference = '0' then
                            -- Parameter packets are stop-and-wait and return
                            -- an empty command-specific ACK. A nonzero status
                            -- rejects malformed ranges/lengths or a write
                            -- attempted while the accelerator is busy.
                            response_valid <= '1';
                            response_kind <= RESPONSE_ERROR;
                            response_dest_mac <= rx_source_mac;
                            response_dest_ip <= rx_source_ip;
                            response_dest_port <= rx_source_port;
                            response_sequence <= rx_sequence;
                            if rx_command = CMD_WRITE_WEIGHT then
                                response_command <= RSP_WRITE_WEIGHT;
                                if mlp_busy = '0' and
                                   rx_body_length > 0 and
                                   rx_parameter_count = rx_body_length and
                                   rx_parameter_address + rx_body_length <=
                                       WEIGHT_ADDRESS_LIMIT and
                                   rx_udp_length = 8 + APP_HEADER_BYTES +
                                       rx_body_length and
                                   rx_ip_total_length = 20 + 8 +
                                       APP_HEADER_BYTES + rx_body_length then
                                    response_status <= x"00";
                                    activity_pulse <= '1';
                                else
                                    response_status <= x"01";
                                    error_pulse <= '1';
                                end if;
                            else
                                response_command <= RSP_WRITE_BIAS;
                                if mlp_busy = '0' and
                                   rx_body_length > 0 and
                                   (rx_body_length mod 4) = 0 and
                                   rx_parameter_count = rx_body_length and
                                   rx_parameter_address +
                                       (rx_body_length / 4) <= NUM_BIASES and
                                   rx_udp_length = 8 + APP_HEADER_BYTES +
                                       rx_body_length and
                                   rx_ip_total_length = 20 + 8 +
                                       APP_HEADER_BYTES + rx_body_length then
                                    response_status <= x"00";
                                    activity_pulse <= '1';
                                else
                                    response_status <= x"01";
                                    error_pulse <= '1';
                                end if;
                            end if;
                        elsif common_ipv4_valid and
                              rx_command = CMD_INFER and
                              rx_body_length = IMAGE_BYTES and
                              rx_image_count = IMAGE_BYTES and
                              rx_udp_length = 8 + INFER_REQUEST_BYTES and
                              rx_ip_total_length = 20 + 8 + INFER_REQUEST_BYTES then
                            if mlp_busy = '0' and awaiting_inference = '0' and
                               response_valid = '0' then
                                diagnostic_flags(3) <= '1'; -- request accepted
                                mlp_start <= '1';
                                awaiting_inference <= '1';
                                job_source_mac <= rx_source_mac;
                                job_source_ip <= rx_source_ip;
                                job_source_port <= rx_source_port;
                                job_sequence <= rx_sequence;
                                activity_pulse <= '1';
                            else
                                -- This endpoint is intentionally stop-and-wait.
                                -- Drop duplicate/new inference requests while
                                -- the one accelerator job is outstanding.  A
                                -- queued busy error could otherwise occupy the
                                -- sole response slot on the exact cycle the
                                -- core's one-cycle completion event arrives.
                                diagnostic_flags(9) <= '1'; -- rejected busy
                            end if;
                        elsif rx_in_frame = '1' and rx_crc /= CRC_RESIDUE then
                            error_pulse <= '1';
                        end if;
                        rx_in_frame <= '0';
                            end if; -- recovered RXDV on second dibit
                        end if; -- nibble sample phase
                    end if; -- preamble acquisition / frame data
                end if; -- RMII receive clock enable
            end if;
        end if;
    end process;

    transmitter : process(clk)
        variable current_byte : byte_t;
        variable current_dibit : std_logic_vector(1 downto 0);
        variable next_crc : std_logic_vector(31 downto 0);
        variable checksum_word : unsigned(15 downto 0);
        variable checksum_sum : unsigned(19 downto 0);
        variable checksum_fold_value : unsigned(16 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                eth_txen <= '0';
                eth_txd <= "00";
                response_taken <= '0';
                tx_buffer <= (others => (others => '0'));
                tx_data_length <= 0;
                tx_state <= TX_IDLE;
                tx_kind <= RESPONSE_PING;
                tx_status <= x"00";
                tx_dest_mac <= (others => '0');
                tx_dest_ip <= (others => '0');
                tx_dest_port <= (others => '0');
                tx_sequence <= (others => '0');
                tx_outputs <= (others => '0');
                tx_diagnostics <= (others => '0');
                tx_ip_total_length <= 0;
                tx_udp_length <= 0;
                tx_body_length <= 0;
                tx_frame_length <= 0;
                tx_command <= RSP_PING;
                tx_checksum_acc <= (others => '0');
                tx_checksum_fold_sum <= (others => '0');
                tx_checksum_index <= 0;
                tx_ipv4_checksum <= (others => '0');
                tx_preamble_byte <= 0;
                tx_byte_index <= 0;
                tx_dibit_index <= 0;
                tx_crc <= (others => '1');
                tx_fcs_value <= (others => '0');
                tx_fcs_dibit <= 0;
                tx_ifg_dibit <= 0;
            else
                response_taken <= '0';
                if rmii_tx_ce = '1' then
                    case tx_state is
                        when TX_IDLE =>
                            eth_txen <= '0';
                            eth_txd <= "00";
                            if response_valid = '1' then
                                -- Snapshot the complete response. Packet
                                -- construction takes several cycles so the
                                -- producer is free to clear response_valid.
                                tx_kind <= response_kind;
                                tx_status <= response_status;
                                tx_dest_mac <= response_dest_mac;
                                tx_dest_ip <= response_dest_ip;
                                tx_dest_port <= response_dest_port;
                                tx_sequence <= response_sequence;
                                tx_outputs <= mlp_outputs;
                                tx_diagnostics <= response_diagnostics;
                                tx_checksum_acc <= (others => '0');
                                tx_checksum_index <= 0;

                                if response_kind = RESPONSE_ARP then
                                    tx_state <= TX_BUILD;
                                elsif response_kind = RESPONSE_INFER then
                                    tx_ip_total_length <= 88;
                                    tx_udp_length <= 68;
                                    tx_body_length <= 44;
                                    tx_frame_length <= 102;
                                    tx_command <= RSP_INFER;
                                    tx_state <= TX_CHECKSUM;
                                elsif response_kind = RESPONSE_ERROR then
                                    tx_ip_total_length <= 44;
                                    tx_udp_length <= 24;
                                    tx_body_length <= 0;
                                    tx_frame_length <= 60;
                                    tx_command <= response_command;
                                    tx_state <= TX_CHECKSUM;
                                else
                                    tx_ip_total_length <= 20 + 8 + APP_HEADER_BYTES + PING_DIAGNOSTIC_BYTES;
                                    tx_udp_length <= 8 + APP_HEADER_BYTES + PING_DIAGNOSTIC_BYTES;
                                    tx_body_length <= PING_DIAGNOSTIC_BYTES;
                                    tx_frame_length <= 14 + 20 + 8 + APP_HEADER_BYTES + PING_DIAGNOSTIC_BYTES;
                                    tx_command <= RSP_PING;
                                    tx_state <= TX_CHECKSUM;
                                end if;
                            end if;

                        when TX_CHECKSUM =>
                            -- Accumulate one IPv4 header word per cycle. This
                            -- replaces the response builder's 13-CARRY4
                            -- combinational path with a single short adder.
                            case tx_checksum_index is
                                when 0 => checksum_word := to_unsigned(16#4500#, 16);
                                when 1 => checksum_word := to_unsigned(tx_ip_total_length, 16);
                                when 2 => checksum_word := unsigned(tx_sequence(15 downto 0));
                                when 3 => checksum_word := to_unsigned(16#4000#, 16);
                                when 4 => checksum_word := to_unsigned(16#4011#, 16);
                                when 5 => checksum_word := unsigned(BOARD_IP(31 downto 16));
                                when 6 => checksum_word := unsigned(BOARD_IP(15 downto 0));
                                when 7 => checksum_word := unsigned(tx_dest_ip(31 downto 16));
                                when others => checksum_word := unsigned(tx_dest_ip(15 downto 0));
                            end case;
                            checksum_sum := tx_checksum_acc + resize(checksum_word, 20);
                            tx_checksum_acc <= checksum_sum;
                            if tx_checksum_index = 8 then
                                tx_state <= TX_CHECKSUM_FOLD;
                            else
                                tx_checksum_index <= tx_checksum_index + 1;
                            end if;

                        when TX_CHECKSUM_FOLD =>
                            tx_checksum_fold_sum <=
                                resize(tx_checksum_acc(15 downto 0), 17) +
                                resize(tx_checksum_acc(19 downto 16), 17);
                            tx_state <= TX_CHECKSUM_FINAL;

                        when TX_CHECKSUM_FINAL =>
                            checksum_fold_value :=
                                resize(tx_checksum_fold_sum(15 downto 0), 17) +
                                resize(tx_checksum_fold_sum(16 downto 16), 17);
                            tx_ipv4_checksum <= std_logic_vector(
                                not checksum_fold_value(15 downto 0)
                            );
                            tx_state <= TX_BUILD;

                        when TX_BUILD =>
                            if tx_kind = RESPONSE_ARP then
                                build_arp_response(
                                    tx_buffer, tx_data_length,
                                    tx_dest_mac, tx_dest_ip
                                );
                            else
                                    build_udp_response(
                                        tx_buffer, tx_data_length,
                                        tx_kind, tx_status,
                                        tx_dest_mac, tx_dest_ip,
                                        tx_dest_port, tx_sequence,
                                        tx_outputs, tx_diagnostics,
                                        tx_ip_total_length,
                                        tx_udp_length,
                                        tx_body_length,
                                        tx_frame_length,
                                        tx_command,
                                        tx_ipv4_checksum
                                    );
                            end if;
                            response_taken <= '1';
                            tx_preamble_byte <= 0;
                            tx_dibit_index <= 0;
                            tx_state <= TX_PREAMBLE;

                        when TX_PREAMBLE =>
                            eth_txen <= '1';
                            if tx_preamble_byte = 7 then
                                current_byte := x"D5";
                            else
                                current_byte := x"55";
                            end if;
                            eth_txd <= select_dibit(current_byte, tx_dibit_index);
                            if tx_dibit_index = 3 then
                                tx_dibit_index <= 0;
                                if tx_preamble_byte = 7 then
                                    tx_byte_index <= 0;
                                    tx_crc <= (others => '1');
                                    tx_state <= TX_DATA;
                                else
                                    tx_preamble_byte <= tx_preamble_byte + 1;
                                end if;
                            else
                                tx_dibit_index <= tx_dibit_index + 1;
                            end if;

                        when TX_DATA =>
                            eth_txen <= '1';
                            current_byte := tx_buffer(tx_byte_index);
                            current_dibit := select_dibit(
                                current_byte, tx_dibit_index
                            );
                            eth_txd <= current_dibit;
                            next_crc := crc32_dibit(tx_crc, current_dibit);
                            tx_crc <= next_crc;
                            if tx_dibit_index = 3 then
                                tx_dibit_index <= 0;
                                if tx_byte_index = tx_data_length - 1 then
                                    tx_fcs_value <= not next_crc;
                                    tx_fcs_dibit <= 0;
                                    tx_state <= TX_FCS;
                                else
                                    tx_byte_index <= tx_byte_index + 1;
                                end if;
                            else
                                tx_dibit_index <= tx_dibit_index + 1;
                            end if;

                        when TX_FCS =>
                            eth_txen <= '1';
                            eth_txd <= tx_fcs_value(1 downto 0);
                            tx_fcs_value <= "00" & tx_fcs_value(31 downto 2);
                            if tx_fcs_dibit = 15 then
                                tx_ifg_dibit <= 0;
                                tx_state <= TX_IFG;
                            else
                                tx_fcs_dibit <= tx_fcs_dibit + 1;
                            end if;

                        when TX_IFG =>
                            eth_txen <= '0';
                            eth_txd <= "00";
                            if tx_ifg_dibit = 47 then
                                tx_state <= TX_IDLE;
                            else
                                tx_ifg_dibit <= tx_ifg_dibit + 1;
                            end if;
                    end case;
                end if;
            end if;
        end if;
    end process;
end architecture;
