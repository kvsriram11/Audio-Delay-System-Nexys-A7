// top level module handles wishbone logic and instantiates i2s receive and transmit

`define I2S2_DRY_WET	        4'h0	// Address 0x00
`define I2S2_FEEDBACK	        4'h1	// Address 0x04
`define I2S2_DELAY_LEN          4'h2	// Address 0x08
`define I2S2_UPDATE_EN          4'h3    // wb_adr_i[5:2]==3  offset 0x0C  write any value to latch


module i2s2_top #(
    parameter dw             = 32,
    parameter aw             = 8,
    parameter max_bit_res    = 24,
    parameter bit_res        = 24,
    parameter RESET_POLARITY = 0
)(
    // Wishbone signals
    input  logic          wb_clk_i,
    input  logic          wb_rst_i,
    input  logic [aw-1:0] wb_adr_i,
    input  logic [dw-1:0] wb_dat_i,
    output logic [dw-1:0] wb_dat_o,
    input  logic          wb_we_i,
    input  logic          wb_stb_i,
    input  logic          wb_cyc_i,
    output logic          wb_ack_o,

    // Audio clocks and I/O
    input  logic          i2s_mclk_in,   // ~22.579 MHz
    output logic          i2s_sclk_out,   // mclk/8   (~2.822 MHz)
    output logic          i2s_lrclk_out,  // mclk/512 (~44.1 kHz)
    input  logic          i2s_rx_sdin,
    output logic          i2s_tx_sdout
);

    // rx and tx signals
    // RX path
    logic [31:0] rx_stream_data;
    logic        rx_stream_valid;
    logic        rx_stream_ready;
    logic        rx_stream_last;

    // TX path
    logic [23:0] tx_stream_data;
    logic        tx_stream_valid;
    logic        tx_stream_ready;
    logic        tx_stream_last;

    // wishbone control signals
    logic [dw-1:0] wb_dat;
    
    // wishbone ack
    logic wb_ack;
    assign wb_ack = wb_cyc_i & wb_stb_i;
    always_ff @(posedge wb_clk_i or posedge wb_rst_i) begin
        if (wb_rst_i)
            wb_ack_o <= 1'b0;
        else
            wb_ack_o <= wb_ack & ~wb_ack_o; 
    end

    // internal registers
    logic [7:0]  dry_wet_ctrl;
    logic [7:0]  feedback_ctrl;
    logic [19:0] delay_len_ctrl;

    // address decoder
    logic dry_wet_sel;
    logic feedback_sel;
    logic delay_len_sel;
    logic update_en_sel;
    logic full_decoding;

    // address decoding
    // 0000 0000 0x00 - dry_wet
    // 0000 0100 0x04 - feedback
    // 0000 1000 0x08 - delay_len
    // 0000 1100 0x0C - delay_update

    assign full_decoding    = wb_cyc_i & wb_stb_i;
    assign dry_wet_sel      = full_decoding & (wb_adr_i[5:2] == `I2S2_DRY_WET     );
    assign feedback_sel     = full_decoding & (wb_adr_i[5:2] == `I2S2_FEEDBACK    );
    assign delay_len_sel    = full_decoding & (wb_adr_i[5:2] == `I2S2_DELAY_LEN   );
    assign update_en_sel    = full_decoding & (wb_adr_i[5:2] == `I2S2_UPDATE_EN  );


    // Write to selected control registers
    always_ff @(posedge wb_clk_i or posedge wb_rst_i) begin
        if (wb_rst_i) begin
            dry_wet_ctrl   <= '0;
            feedback_ctrl  <= '0;
            delay_len_ctrl <= '0;
        end else begin 
            if (dry_wet_sel   && wb_we_i) dry_wet_ctrl   <= wb_dat_i[7:0];
            if (feedback_sel  && wb_we_i) feedback_ctrl  <= wb_dat_i[7:0];
            if (delay_len_sel && wb_we_i) delay_len_ctrl <= wb_dat_i[19:0]; 
        end
    end

    // -------------------------------------------------------------------------
    // CDC: stretched update_en pulse (wb_clk) → i2s_mclk shadow registers
    //
    // CPU writes any value to UPDATE_EN. update_en is held high for 4
    // wb_clk cycles (~320 ns = ~7 i2s_clk cycles) so the 2-FF synchroniser
    // in the i2s domain reliably captures it regardless of phase.
    // A single wb_clk pulse (~80 ns) would only span ~1.8 i2s_clk cycles —
    // not enough for guaranteed capture.
    // -------------------------------------------------------------------------
    logic        update_en     = 1'b0;
    logic [2:0]  update_en_cntr = 3'd0;

    always_ff @(posedge wb_clk_i or posedge wb_rst_i) begin
        if (wb_rst_i) begin
            update_en     <= 1'b0;
            update_en_cntr <= 3'd0;
        end else if (update_en_sel & wb_we_i) begin
            update_en     <= 1'b1;
            update_en_cntr <= 3'd4;
        end else if (update_en_cntr > 0) begin
            update_en_cntr <= update_en_cntr - 1;
            update_en     <= 1'b1;
        end else begin
            update_en     <= 1'b0;
        end
    end


    // read mux for wishbone data out
    always_comb begin
        case (wb_adr_i[5:2])
            `I2S2_DRY_WET  : wb_dat = {24'h0, dry_wet_ctrl  };
            `I2S2_FEEDBACK : wb_dat = {24'h0, feedback_ctrl };
            `I2S2_DELAY_LEN: wb_dat = {12'h0, delay_len_ctrl};
            `I2S2_UPDATE_EN: wb_dat = {31'h0, update_en     };
            default:         wb_dat = '0;
        endcase
    end

    // register wb_dat_o
    logic [dw-1:0] wb_dat_o_r;
    always_ff @(posedge wb_clk_i or posedge wb_rst_i) begin
        if (wb_rst_i) wb_dat_o_r <= '0;
        else          wb_dat_o_r <= wb_dat; 
    end
    assign wb_dat_o = wb_dat_o_r;
    
    // Synchronize wb_rst_i to the i2s_mclk_in domain
    (* ASYNC_REG = "TRUE" *) logic i2s_rst_sync_0 = 1'b1;
    (* ASYNC_REG = "TRUE" *) logic i2s_rst_sync_1 = 1'b1;
    logic i2s_resetn;
    always_ff @(posedge i2s_mclk_in) begin
        i2s_rst_sync_0 <= wb_rst_i;   
        i2s_rst_sync_1 <= i2s_rst_sync_0; 
    end

    // Create active-low reset for submodules
    assign i2s_resetn = ~i2s_rst_sync_1;

    // -------------------------------------------------------------------------
    // Synchronise update_en into i2s_mclk domain and latch shadow registers
    // -------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) logic en_sync0 = 1'b0;
    (* ASYNC_REG = "TRUE" *) logic en_sync1 = 1'b0;
    logic en_prev = 1'b0;

    always_ff @(posedge i2s_mclk_in) begin
        en_sync0 <= update_en;
        en_sync1 <= en_sync0;
        en_prev  <= en_sync1;
    end

    wire en_rise = en_sync1 & ~en_prev;

    logic [7:0]  dry_wet_i2s   = 8'd0;
    logic [7:0]  feedback_i2s  = 8'd0;
    logic [19:0] delay_len_i2s = 20'd0;

    always_ff @(posedge i2s_mclk_in) begin
        if (en_rise) begin
            dry_wet_i2s   <= dry_wet_ctrl;
            feedback_i2s  <= feedback_ctrl;
            delay_len_i2s <= delay_len_ctrl;
        end
    end

    // i2s2 instantiation
    i2s2 m_i2s2 (
        .resetn   (i2s_resetn),

        // TX slave (receives from delay line)
        .tx_data  ({8'b0, tx_stream_data}),
        .tx_valid (tx_stream_valid),
        .tx_ready (tx_stream_ready),
        .tx_last  (tx_stream_last),

        // RX master (sends to delay line)
        .rx_data  (rx_stream_data),
        .rx_valid (rx_stream_valid),
        .rx_ready (rx_stream_ready),
        .rx_last  (rx_stream_last),

        // I2S2 pins
        .mclk_in  (i2s_mclk_in),
        .lrclk_out(i2s_lrclk_out),
        .sclk_out (i2s_sclk_out),
        .tx_sdout (i2s_tx_sdout),
        .rx_sdin  (i2s_rx_sdin)
    );

/*
PMOD pin -> rx_sdin -> rx_data -> s_data (delay_line) -> m_data -> m_data -> tx_data (i2s2 module) -> tx_sdout (headphone/speakers)
*/


  delay_line_top #(
        .DATA_WIDTH(24)
  ) dl_top (
        .i2s_clk  (i2s_mclk_in),
        .rst      (!i2s_resetn),
        // Control registers already synchronised to i2s_mclk domain
        .dry_wet  (dry_wet_i2s),
        .feedback (feedback_i2s),
        .delay_len(delay_len_i2s),


        // Stream slave (receives from i2s2 module)
        .s_data  (rx_stream_data[23:0]),
        .s_valid (rx_stream_valid),
        .s_ready (rx_stream_ready),
        .s_last  (rx_stream_last),

        // Stream master (sends to i2s2 module)
        .m_data  (tx_stream_data),
        .m_valid (tx_stream_valid),
        .m_ready (tx_stream_ready),
        .m_last  (tx_stream_last)
    );
  

endmodule

