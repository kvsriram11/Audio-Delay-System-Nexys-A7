`timescale 1ns / 1ps
`default_nettype none
////////////////////////////////////////////////////////////////////////////////
// Module: wb_i2s2
// Description:
//   I2S controller for the Pmod I2S2, adapted from Digilent's axis_i2s2.sv.
//   The AXI-Stream master/slave ports are preserved as the inter-module
//   streaming interface so the volume controller can be connected directly,
//   exactly as in the original top.sv.  The only changes from axis_i2s2 are:
//     - Clock port renamed  axis_clk   -> mclk_in  (22.591 MHz, from clk_wiz_0)
//     - Reset port renamed  axis_resetn -> resetn   (active-low, same polarity)
//     - Stream ports renamed to drop the "axis_" prefix on the port names
//       (signal names inside the module are unchanged)
//     - Reset is now active-low synchronous (matching Wishbone rst_n convention)
//       rather than the original's asynchronous style
//
// Streaming interface (internal – driven by wb_i2s2_top):
//   TX slave  : tx_data, tx_valid, tx_ready, tx_last
//   RX master : rx_data, rx_valid, rx_ready, rx_last
//
// I2S timing (identical to axis_i2s2):
//   count[8] = LRCLK, period = 512 mclk_in cycles (~44.1 kHz)
//   count[2] = SCLK, period = 8   mclk_in cycles
//   Data: 24-bit, MSB-first, one SCLK after LRCLK edge.
//   RX input synchronised with 3-stage synchroniser.
////////////////////////////////////////////////////////////////////////////////

module i2s2 (
    input  wire        mclk_in,   // 22.591 MHz from clk_wiz_0
    input  wire        resetn,    // active-low synchronous reset

    // TX stream slave (receives audio from volume controller)
    input  wire [31:0] tx_data,
    input  wire        tx_valid,
    output reg         tx_ready,
    input  wire        tx_last,

    // RX stream master (sends captured audio to volume controller)
    output wire [31:0] rx_data,
    output reg         rx_valid,
    input  wire        rx_ready,
    output reg         rx_last,

    // Pmod I2S2 physical pins
    output wire        lrclk_out, // lrclk = 1 -> left audio lrclk = 0 -> right audio
    output wire        sclk_out,
    output reg         tx_sdout,
    input  wire        rx_sdin
);

    // =========================================================================
    // Frame counter and I2S clock generation (identical to axis_i2s2)
    // =========================================================================
    reg [8:0] count = 9'd0;
    localparam EOF_COUNT = 9'd455;

    always @(posedge mclk_in) begin
        if (!resetn) count <= 9'd0;
        else count <= count + 1'b1;
    end

    assign lrclk_out = count[8];
    assign sclk_out  = count[2];


    // =========================================================================
    // TX stream slave controller (identical logic to axis_i2s2)
    // =========================================================================
    reg [31:0] tx_data_l = 32'b0;
    reg [31:0] tx_data_r = 32'b0;

    always @(posedge mclk_in) begin
        if (tx_ready && tx_valid && tx_last)
            tx_ready <= 1'b0;
        else if (count == 9'b0)
            tx_ready <= 1'b0;
        else if (count == EOF_COUNT)
            tx_ready <= 1'b1;
    end

    always @(posedge mclk_in) begin
        if (tx_valid && tx_ready) begin
            if (tx_last)
                tx_data_r <= tx_data;
            else
                tx_data_l <= tx_data;
        end
    end

    // =========================================================================
    // TX shift registers (identical to axis_i2s2)
    // =========================================================================
    reg [23:0] tx_data_l_shift = 24'b0;
    reg [23:0] tx_data_r_shift = 24'b0;

    always @(posedge mclk_in) begin
        if (count == 9'd7) begin
            tx_data_l_shift <= tx_data_l[23:0];
            tx_data_r_shift <= tx_data_r[23:0];
        end else if (count[2:0] == 3'b111 && count[7:3] >= 5'd1 && count[7:3] <= 5'd24) begin
            if (count[8])
                tx_data_r_shift <= {tx_data_r_shift[22:0], 1'b0};
            else
                tx_data_l_shift <= {tx_data_l_shift[22:0], 1'b0};
        end
    end

    always @(count, tx_data_l_shift, tx_data_r_shift) begin
        if (count[7:3] >= 5'd1 && count[7:3] <= 5'd24)
            tx_sdout = count[8] ? tx_data_r_shift[23] : tx_data_l_shift[23];
        else
            tx_sdout = 1'b0;
    end

    // =========================================================================
    // RX input synchroniser (identical to axis_i2s2)
    // =========================================================================
    reg [2:0] din_sync_shift = 3'd0;
    wire      din_sync = din_sync_shift[2];

    always @(posedge mclk_in)
        din_sync_shift <= {din_sync_shift[1:0], rx_sdin};

    // =========================================================================
    // RX shift registers (identical to axis_i2s2)
    // =========================================================================
    reg [23:0] rx_data_l_shift = 24'b0;
    reg [23:0] rx_data_r_shift = 24'b0;

    always @(posedge mclk_in) begin
        if (count[2:0] == 3'b011 && count[7:3] >= 5'd1 && count[7:3] <= 5'd24) begin
            if (count[8])
                rx_data_r_shift <= {rx_data_r_shift[22:0], din_sync};
            else
                rx_data_l_shift <= {rx_data_l_shift[22:0], din_sync};
        end
    end

    // =========================================================================
    // RX stream master controller (identical logic to axis_i2s2)
    // =========================================================================
    reg [31:0] rx_data_l = 32'b0;
    reg [31:0] rx_data_r = 32'b0;

    always @(posedge mclk_in) begin
        if (count == EOF_COUNT && !rx_valid) begin
            rx_data_l <= {8'b0, rx_data_l_shift};
            rx_data_r <= {8'b0, rx_data_r_shift};
        end
    end

    assign rx_data = rx_last ? rx_data_r : rx_data_l;

    always @(posedge mclk_in) begin
        if (count == EOF_COUNT && !rx_valid)
            rx_valid <= 1'b1;
        else if (rx_valid && rx_ready && rx_last)
            rx_valid <= 1'b0;
    end

    always @(posedge mclk_in) begin
        if (count == EOF_COUNT && !rx_valid)
            rx_last <= 1'b0;
        else if (rx_valid && rx_ready)
            rx_last <= ~rx_last;
    end

endmodule
`default_nettype wire