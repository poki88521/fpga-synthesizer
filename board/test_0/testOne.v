// ============================================================
//  PT8211 Audio Test for Tang Mega 138K Pro
//  Target: GW5AST-LV138FPG676A (Device Version B)
//  Function: Output ~440 Hz square wave via PT8211 DAC
//  Clock: 50 MHz on-board oscillator (V22)
// ============================================================

module pt8211_test (
    input  wire       clk,        // 50 MHz system clock (V22)
    output wire       bclk,       // I2S bit clock to PT8211 (E22)
    output wire       lrck,       // I2S word select to PT8211 (F24)
    output wire       din,        // I2S data to PT8211 (G24)
    output wire       pa_en,      // Power amplifier enable (H17)
    output wire       led         // Status LED
);

    // --------------------------------------------------------
    // 1. Parameters
    // --------------------------------------------------------
    localparam  SAMPLE_RATE_DIV = 1024;     // 50MHz / 1024 ≈ 48.83 kHz sample rate
    localparam  BCLK_DIV        = 32;       // 32 BCLK per frame (16-bit x 2 channels)
    localparam  PHASE_INC_440   = 3862365;  // 440 Hz at 50 MHz (freq * 2^32 / 50e6 ≈ 37.8e6... wait, let's compute properly)

    // 440 Hz phase increment at 50 MHz, 32-bit accumulator:
    // phase_inc = f_out * 2^32 / f_clk = 440 * 4294967296 / 50000000 ≈ 37,800,000
    // But we only update phase every SAMPLE_RATE_DIV cycles (48.83 kHz),
    // so effective phase increment per sample = 440 * 2^32 / 48828 ≈ 38,700,000
    // Let's use a simpler approach: accumulate at sample rate, then it's:
    // f_out = f_s * phase_inc / 2^32  =>  phase_inc = f_out * 2^32 / f_s
    //        = 440 * 4294967296 / 48828.125 ≈ 38,700,000
    // Actually let's just compute: f_s = 50e6/1024 = 48828.125 Hz
    // phase_inc = 440 * 2^32 / 48828.125 = 38,696,438 ≈ 38696438
    // For simplicity and to get exact 440 Hz, we can also use a fixed divider approach.
    // Let's use a DDS phase accumulator updated every sample tick.

    localparam  PHASE_INC = 38696438;       // 440 Hz at 48.83 kHz sample rate

    // --------------------------------------------------------
    // 2. Internal signals
    // --------------------------------------------------------
    reg  [15:0] sample_cnt;      // Sample rate counter (÷1024)
    reg  [4:0]  bit_cnt;         // Bit counter within a frame (0..31)
    reg  [31:0] phase_acc;       // DDS phase accumulator
    reg         sample_tick;     // Pulse at sample rate
    reg         bclk_rise;       // BCLK rising edge enable
    reg         bclk_fall;       // BCLK falling edge enable

    reg  [15:0] left_sample;     // Left channel 16-bit sample
    reg  [15:0] right_sample;    // Right channel 16-bit sample
    reg  [15:0] shift_reg;       // Parallel-load shift register
    reg         lrck_reg;        // Registered LRCK (internal)
    reg         din_reg;         // Registered DIN (internal)
    reg         bclk_int;        // Internal BCLK for edge detection
    reg         bclk_prev;       // Previous BCLK state

    wire        bclk_oddr_q0;    // ODDR Q0 output
    wire        bclk_oddr_q1;    // ODDR Q1 output (tristate, unused)

    // --------------------------------------------------------
    // 3. Sample rate generator (÷1024)
    // --------------------------------------------------------
    always @(posedge clk) begin
        if (sample_cnt == SAMPLE_RATE_DIV - 1) begin
            sample_cnt  <= 16'd0;
            sample_tick  <= 1'b1;
        end else begin
            sample_cnt  <= sample_cnt + 1'b1;
            sample_tick  <= 1'b0;
        end
    end

    // --------------------------------------------------------
    // 4. DDS phase accumulator → 440 Hz square wave
    // --------------------------------------------------------
    always @(posedge clk) begin
        if (sample_tick)
            phase_acc <= phase_acc + PHASE_INC;
    end

    // Square wave: MSB of phase accumulator
    wire square_wave = phase_acc[31];

    // Left = Right = square wave (centered, zero DC offset in 16-bit signed)
    // Square wave: 0x7FFF for positive half, 0x8001 for negative half
    always @(posedge clk) begin
        if (sample_tick) begin
            left_sample  <= square_wave ? 16'h7FFF : 16'h8001;
            right_sample <= square_wave ? 16'h7FFF : 16'h8001;
        end
    end

    // --------------------------------------------------------
    // 5. BCLK generation (÷32, 50% duty)
    // --------------------------------------------------------
    always @(posedge clk) begin
        if (sample_tick) begin
            bit_cnt <= 5'd0;
        end else if (bclk_rise) begin
            if (bit_cnt == BCLK_DIV - 1)
                bit_cnt <= 5'd0;
            else
                bit_cnt <= bit_cnt + 1'b1;
        end
    end

    // BCLK internal: toggle every 16 system clocks (50MHz / 32 = 1.5625 MHz)
    // We need BCLK = 1.536 MHz ideally, but with 50 MHz we get 1.5625 MHz
    // This corresponds to sample rate = 1.5625M / 32 = 48.83 kHz
    reg [3:0] bclk_div_cnt;
    always @(posedge clk) begin
        if (sample_tick) begin
            bclk_div_cnt <= 4'd0;
            bclk_int     <= 1'b0;
        end else begin
            if (bclk_div_cnt == 4'd15) begin
                bclk_div_cnt <= 4'd0;
                bclk_int     <= ~bclk_int;
            end else begin
                bclk_div_cnt <= bclk_div_cnt + 1'b1;
            end
        end
    end

    // Edge detection for BCLK
    always @(posedge clk) begin
        bclk_prev <= bclk_int;
        bclk_rise <= (bclk_int & ~bclk_prev);
        bclk_fall <= (~bclk_int & bclk_prev);
    end

    // --------------------------------------------------------
    // 6. LRCK generation (WS: HIGH = Left, LOW = Right)
    //    LRCK toggles every 16 BCLK periods.
    //    LRCK transitions at the BCLK falling edge.
    // --------------------------------------------------------
    always @(posedge clk) begin
        if (sample_tick) begin
            lrck_reg <= 1'b1;  // Start with Left channel
        end else if (bclk_fall) begin
            if (bit_cnt == 5'd15)
                lrck_reg <= 1'b0;  // Switch to Right
            else if (bit_cnt == 5'd31)
                lrck_reg <= 1'b1;  // Switch back to Left
        end
    end

    // --------------------------------------------------------
    // 7. Data shift register and DIN output
    //    LSBJ format: MSB first, shifted out on BCLK falling edge.
    //    Load the sample at the start of each channel period.
    // --------------------------------------------------------
    always @(posedge clk) begin
        if (sample_tick) begin
            shift_reg <= 16'd0;
            din_reg   <= 1'b0;
        end else if (bclk_fall) begin
            if (bit_cnt == 5'd0) begin
                // Start of Left channel: load left sample
                shift_reg <= left_sample;
                din_reg   <= left_sample[15];  // MSB first
            end else if (bit_cnt == 5'd16) begin
                // Start of Right channel: load right sample
                shift_reg <= right_sample;
                din_reg   <= right_sample[15];  // MSB first
            end else begin
                // Shift out next bit
                shift_reg <= {shift_reg[14:0], 1'b0};
                din_reg   <= shift_reg[15];
            end
        end
    end

    // --------------------------------------------------------
    // 8. ODDR instantiation for BCLK
    //    D0 = data on rising edge of clk
    //    D1 = data on falling edge of clk
    //    TX = 1'b1 (output enable)
    //    Q0 → bclk output pin
    //    Q1 → dangling (no tristate needed)
    // --------------------------------------------------------
    ODDR u_bclk_oddr (
        .Q0 (bclk_oddr_q0),
        .Q1 (bclk_oddr_q1),
        .D0 (bclk_int),
        .D1 (bclk_int),
        .TX (1'b1),
        .CLK(clk)
    );
    defparam u_bclk_oddr.INIT      = 1'b0;
    defparam u_bclk_oddr.TXCLK_POL = 1'b0;

    // --------------------------------------------------------
    // 9. Output assignments
    // --------------------------------------------------------
    assign bclk  = bclk_oddr_q0;  // BCLK from ODDR
    assign lrck  = lrck_reg;      // LRCK registered on BCLK falling edge
    assign din   = din_reg;       // DIN registered on BCLK falling edge
    assign pa_en = 1'b1;          // Power amplifier always enabled
    assign led   = phase_acc[31]; // LED follows audio waveform

endmodule