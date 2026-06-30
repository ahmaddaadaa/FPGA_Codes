module spi_color_feature_engine (
    input  wire clk12,

    input  wire spi_mosi,
    input  wire spi_sclk,
    input  wire spi_cs_n,

    output wire spi_miso,
    output reg  led0,
    output reg  led1
);

    // ============================================================
    // SPI packet format from ESP32
    //
    // [A5] [5A] [Frame] [Chunk] [Length=64]
    // [64 image bytes]
    // [XOR checksum]
    //
    // RGB565 pixel format:
    // High byte: RRRRRGGG
    // Low byte:  GGGBBBBB
    // ============================================================

    localparam [2:0] WAIT_HEADER_1 = 3'd0;
    localparam [2:0] WAIT_HEADER_2 = 3'd1;
    localparam [2:0] GET_FRAME     = 3'd2;
    localparam [2:0] GET_CHUNK     = 3'd3;
    localparam [2:0] GET_LENGTH    = 3'd4;
    localparam [2:0] GET_PAYLOAD   = 3'd5;
    localparam [2:0] GET_CHECKSUM  = 3'd6;

    localparam [7:0] LAST_FRAME_CHUNK = 8'd127;

    // ============================================================
    // Synchronize SPI signals into FPGA 12 MHz clock domain
    // ============================================================

    reg sclk_meta;
    reg sclk_sync;
    reg sclk_prev;

    reg cs_meta;
    reg cs_sync;
    reg cs_prev;

    reg mosi_meta;
    reg mosi_sync;

    always @(posedge clk12) begin
        sclk_meta <= spi_sclk;
        sclk_sync <= sclk_meta;
        sclk_prev <= sclk_sync;

        cs_meta <= spi_cs_n;
        cs_sync <= cs_meta;
        cs_prev <= cs_sync;

        mosi_meta <= spi_mosi;
        mosi_sync <= mosi_meta;
    end

    wire cs_start;
    wire cs_end;
    wire sclk_rise;
    wire sclk_fall;

    assign cs_start  =  cs_prev && !cs_sync;
    assign cs_end    = !cs_prev &&  cs_sync;
    assign sclk_rise = !sclk_prev && sclk_sync && !cs_sync;
    assign sclk_fall =  sclk_prev && !sclk_sync && !cs_sync;

    // ============================================================
    // SPI packet receiver registers
    // ============================================================

    reg [2:0] parser_state;

    reg [7:0] rx_shift;
    reg [2:0] rx_bit_count;

    reg [5:0] payload_index;
    reg [7:0] xor_sum;

    reg [7:0] frame_id;
    reg [7:0] chunk_id;
    reg [7:0] payload_length;

    reg [15:0] edge_count;

    wire [7:0] received_byte;
    assign received_byte = {rx_shift[6:0], mosi_sync};

    // ============================================================
    // Streaming RGB565 feature extraction
    // ============================================================

    reg [7:0] pixel_high_byte;

    reg [12:0] red_count;
    reg [12:0] green_count;
    reg [12:0] other_count;

    // Current pixel is formed when the low byte arrives.
    wire [5:0] pixel_r6;
    wire [5:0] pixel_g6;
    wire [5:0] pixel_g5;
    wire [5:0] pixel_b6;

    assign pixel_r6 = {1'b0, pixel_high_byte[7:3]};
    assign pixel_g6 = {pixel_high_byte[2:0], received_byte[7:5]};
    assign pixel_g5 = {1'b0, pixel_g6[5:1]};
    assign pixel_b6 = {1'b0, received_byte[4:0]};

    wire pixel_is_red;
    wire pixel_is_green;

    // Same thresholds used in the ESP32 reference calculation.
    assign pixel_is_red =
        (pixel_r6 >= 6'd9) &&
        (pixel_r6 >= pixel_g5 + 6'd4) &&
        (pixel_r6 >= pixel_b6 + 6'd4);

    assign pixel_is_green =
        (pixel_g5 >= 6'd9) &&
        (pixel_g5 >= pixel_r6 + 6'd4) &&
        (pixel_g5 >= pixel_b6 + 6'd4);

    // ============================================================
    // Parallel weighted feature classifier
    //
    // Red score   = 3*red_count - green_count
    // Green score = 3*green_count - red_count
    //
    // 3*x is calculated with shift-and-add:
    // 3*x = 2*x + x
    // ============================================================

    wire [13:0] colored_count;

    wire signed [15:0] red_score;
    wire signed [15:0] green_score;

    assign colored_count =
        {1'b0, red_count} +
        {1'b0, green_count};

    assign red_score =
        $signed({2'b00, red_count, 1'b0}) +
        $signed({3'b000, red_count}) -
        $signed({3'b000, green_count});

    assign green_score =
        $signed({2'b00, green_count, 1'b0}) +
        $signed({3'b000, green_count}) -
        $signed({3'b000, red_count});

    // Percentage multiplied by 10.
    // Example: 625 means 62.5%.
    //
    // percentage_x10 = count * 1000 / 4096
    // 1000*x = 1024*x - 16*x - 8*x

    wire [23:0] red_extended;
    wire [23:0] green_extended;

    wire [23:0] red_times_1000;
    wire [23:0] green_times_1000;

    wire [15:0] red_percent_x10;
    wire [15:0] green_percent_x10;

    assign red_extended = {11'd0, red_count};
    assign green_extended = {11'd0, green_count};

    assign red_times_1000 =
        (red_extended << 10) -
        (red_extended << 4) -
        (red_extended << 3);

    assign green_times_1000 =
        (green_extended << 10) -
        (green_extended << 4) -
        (green_extended << 3);

    assign red_percent_x10 =
        (red_times_1000 + 24'd2048) >> 12;

    assign green_percent_x10 =
        (green_times_1000 + 24'd2048) >> 12;

    // Class codes:
    // 0 = unknown / not enough color
    // 1 = red dominant
    // 2 = green dominant

    wire [7:0] class_code;

    assign class_code =
        (colored_count < 14'd64) ? 8'd0 :
        (red_score > green_score) ? 8'd1 :
        (green_score > red_score) ? 8'd2 :
        8'd0;

    // ============================================================
    // FPGA response packet
    //
    // Bytes 0-7 are the normal ACK response.
    // Bytes 8-27 contain the final frame result.
    //
    // ESP32 sends a second SPI read transaction after all 128 chunks.
    // ============================================================

    reg [7:0] response_status;
    reg [7:0] response_frame;
    reg [7:0] response_chunk;
    reg [7:0] response_length;
    reg [7:0] response_xor;
    reg [15:0] response_edges;

    reg response_result_valid;
    reg [7:0] response_class;

    reg [15:0] response_red_count;
    reg [15:0] response_green_count;
    reg [15:0] response_other_count;

    reg [15:0] response_red_percent_x10;
    reg [15:0] response_green_percent_x10;

    reg signed [15:0] response_red_score;
    reg signed [15:0] response_green_score;

    reg [15:0] response_colored_count;
    reg [15:0] response_pixels_processed;

    function [7:0] response_byte;
        input [4:0] index;

        begin
            case (index)
                5'd0:  response_byte = 8'hC3;
                5'd1:  response_byte = response_status;
                5'd2:  response_byte = response_frame;
                5'd3:  response_byte = response_chunk;
                5'd4:  response_byte = response_length;
                5'd5:  response_byte = response_xor;
                5'd6:  response_byte = response_edges[15:8];
                5'd7:  response_byte = response_edges[7:0];

                5'd8:  response_byte = {7'd0, response_result_valid};
                5'd9:  response_byte = response_class;

                5'd10: response_byte = response_red_count[15:8];
                5'd11: response_byte = response_red_count[7:0];

                5'd12: response_byte = response_green_count[15:8];
                5'd13: response_byte = response_green_count[7:0];

                5'd14: response_byte = response_other_count[15:8];
                5'd15: response_byte = response_other_count[7:0];

                5'd16: response_byte = response_red_percent_x10[15:8];
                5'd17: response_byte = response_red_percent_x10[7:0];

                5'd18: response_byte = response_green_percent_x10[15:8];
                5'd19: response_byte = response_green_percent_x10[7:0];

                5'd20: response_byte = response_red_score[15:8];
                5'd21: response_byte = response_red_score[7:0];

                5'd22: response_byte = response_green_score[15:8];
                5'd23: response_byte = response_green_score[7:0];

                5'd24: response_byte = response_colored_count[15:8];
                5'd25: response_byte = response_colored_count[7:0];

                5'd26: response_byte = response_pixels_processed[15:8];
                5'd27: response_byte = response_pixels_processed[7:0];

                default: response_byte = 8'h00;
            endcase
        end
    endfunction

    function [0:0] response_msb;
        input [4:0] index;

        reg [7:0] temp;

        begin
            temp = response_byte(index);
            response_msb = temp[7];
        end
    endfunction

    // ============================================================
    // MISO transmitter
    // ============================================================

    reg [7:0] tx_shift;
    reg [2:0] tx_bit_count;
    reg [4:0] tx_byte_index;
    reg miso_reg;

    assign spi_miso = spi_cs_n ? 1'b0 : miso_reg;

    // ============================================================
    // Initial values
    // ============================================================

    initial begin
        sclk_meta = 1'b0;
        sclk_sync = 1'b0;
        sclk_prev = 1'b0;

        cs_meta = 1'b1;
        cs_sync = 1'b1;
        cs_prev = 1'b1;

        mosi_meta = 1'b0;
        mosi_sync = 1'b0;

        parser_state = WAIT_HEADER_1;

        rx_shift = 8'h00;
        rx_bit_count = 3'd0;

        payload_index = 6'd0;
        xor_sum = 8'h00;

        frame_id = 8'h00;
        chunk_id = 8'h00;
        payload_length = 8'h00;

        edge_count = 16'd0;

        pixel_high_byte = 8'h00;

        red_count = 13'd0;
        green_count = 13'd0;
        other_count = 13'd0;

        response_status = 8'h00;
        response_frame = 8'h00;
        response_chunk = 8'h00;
        response_length = 8'h00;
        response_xor = 8'h00;
        response_edges = 16'd0;

        response_result_valid = 1'b0;
        response_class = 8'd0;

        response_red_count = 16'd0;
        response_green_count = 16'd0;
        response_other_count = 16'd0;

        response_red_percent_x10 = 16'd0;
        response_green_percent_x10 = 16'd0;

        response_red_score = 16'sd0;
        response_green_score = 16'sd0;

        response_colored_count = 16'd0;
        response_pixels_processed = 16'd0;

        tx_shift = 8'hC3;
        tx_bit_count = 3'd0;
        tx_byte_index = 5'd0;
        miso_reg = 1'b0;

        led0 = 1'b0;
        led1 = 1'b0;
    end

    // ============================================================
    // SPI receiver and streaming feature calculation
    // ============================================================

    always @(posedge clk12) begin
        if (cs_start) begin
            parser_state <= WAIT_HEADER_1;
            rx_shift <= 8'h00;
            rx_bit_count <= 3'd0;

            payload_index <= 6'd0;
            xor_sum <= 8'h00;
            edge_count <= 16'd0;
        end
        else if (sclk_rise) begin
            edge_count <= edge_count + 16'd1;
            rx_shift <= received_byte;

            if (rx_bit_count == 3'd7) begin
                rx_bit_count <= 3'd0;

                case (parser_state)

                    WAIT_HEADER_1: begin
                        if (received_byte == 8'hA5)
                            parser_state <= WAIT_HEADER_2;
                    end

                    WAIT_HEADER_2: begin
                        if (received_byte == 8'h5A)
                            parser_state <= GET_FRAME;
                        else if (received_byte == 8'hA5)
                            parser_state <= WAIT_HEADER_2;
                        else
                            parser_state <= WAIT_HEADER_1;
                    end

                    GET_FRAME: begin
                        frame_id <= received_byte;
                        xor_sum <= received_byte;
                        parser_state <= GET_CHUNK;
                    end

                    GET_CHUNK: begin
                        chunk_id <= received_byte;
                        xor_sum <= xor_sum ^ received_byte;
                        parser_state <= GET_LENGTH;
                    end

                    GET_LENGTH: begin
                        payload_length <= received_byte;
                        xor_sum <= xor_sum ^ received_byte;
                        payload_index <= 6'd0;

                        if (received_byte == 8'd64) begin

                            // First packet begins a new 64x64 image frame.
                            if (chunk_id == 8'd0) begin
                                red_count <= 13'd0;
                                green_count <= 13'd0;
                                other_count <= 13'd0;

                                response_result_valid <= 1'b0;
                                led1 <= 1'b0;
                            end

                            parser_state <= GET_PAYLOAD;
                        end
                        else begin
                            response_status <= 8'hE1;
                            response_frame <= frame_id;
                            response_chunk <= chunk_id;
                            response_length <= received_byte;
                            response_xor <= xor_sum ^ received_byte;
                            response_edges <= edge_count + 16'd1;

                            response_result_valid <= 1'b0;

                            led0 <= ~led0;
                            led1 <= 1'b0;

                            parser_state <= WAIT_HEADER_1;
                        end
                    end

                    GET_PAYLOAD: begin
                        xor_sum <= xor_sum ^ received_byte;

                        // Even index = RGB565 high byte.
                        if (payload_index[0] == 1'b0) begin
                            pixel_high_byte <= received_byte;
                        end
                        // Odd index = RGB565 low byte.
                        else begin
                            if (pixel_is_red) begin
                                red_count <= red_count + 13'd1;
                            end
                            else if (pixel_is_green) begin
                                green_count <= green_count + 13'd1;
                            end
                            else begin
                                other_count <= other_count + 13'd1;
                            end
                        end

                        if (payload_index == 6'd63) begin
                            parser_state <= GET_CHECKSUM;
                        end
                        else begin
                            payload_index <= payload_index + 6'd1;
                        end
                    end

                    GET_CHECKSUM: begin
                        response_frame <= frame_id;
                        response_chunk <= chunk_id;
                        response_length <= payload_length;
                        response_xor <= xor_sum;
                        response_edges <= edge_count + 16'd1;

                        if (received_byte == xor_sum) begin
                            response_status <= 8'h06;
                            led0 <= ~led0;

                            // Final packet of a 64x64 RGB565 image.
                            if (chunk_id == LAST_FRAME_CHUNK) begin
                                response_result_valid <= 1'b1;
                                response_class <= class_code;

                                response_red_count <=
                                    {3'd0, red_count};

                                response_green_count <=
                                    {3'd0, green_count};

                                response_other_count <=
                                    {3'd0, other_count};

                                response_red_percent_x10 <=
                                    red_percent_x10;

                                response_green_percent_x10 <=
                                    green_percent_x10;

                                response_red_score <= red_score;
                                response_green_score <= green_score;

                                response_colored_count <=
                                    {2'd0, colored_count};

                                response_pixels_processed <=
                                    16'd4096;

                                led1 <= 1'b1;
                            end
                            else begin
                                response_result_valid <= 1'b0;
                            end
                        end
                        else begin
                            response_status <= 8'h15;
                            response_result_valid <= 1'b0;

                            led0 <= ~led0;
                            led1 <= 1'b0;
                        end

                        parser_state <= WAIT_HEADER_1;
                    end

                    default: begin
                        parser_state <= WAIT_HEADER_1;
                    end

                endcase
            end
            else begin
                rx_bit_count <= rx_bit_count + 3'd1;
            end
        end
    end

    // ============================================================
    // SPI mode 0 MISO response transmitter
    // ============================================================

    always @(posedge clk12) begin
        if (cs_start) begin
            tx_byte_index <= 5'd0;
            tx_bit_count <= 3'd0;

            tx_shift <= response_byte(5'd0);
            miso_reg <= response_msb(5'd0);
        end
        else if (cs_end) begin
            miso_reg <= 1'b0;
        end
        else if (sclk_fall) begin
            if (tx_bit_count == 3'd7) begin
                tx_bit_count <= 3'd0;

                if (tx_byte_index == 5'd27) begin
                    tx_byte_index <= 5'd0;

                    tx_shift <= response_byte(5'd0);
                    miso_reg <= response_msb(5'd0);
                end
                else begin
                    tx_byte_index <= tx_byte_index + 5'd1;

                    tx_shift <= response_byte(
                        tx_byte_index + 5'd1
                    );

                    miso_reg <= response_msb(
                        tx_byte_index + 5'd1
                    );
                end
            end
            else begin
                tx_bit_count <= tx_bit_count + 3'd1;
                tx_shift <= {tx_shift[6:0], 1'b0};
                miso_reg <= tx_shift[6];
            end
        end
    end

endmodule