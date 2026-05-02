module delay_line_step4 #(
    parameter int DATA_WIDTH    = 24,
    parameter int STORE_WIDTH   = 16,
    parameter int BUFFER_BITS   = 15,
    parameter int BUFFER_DEPTH  = (1 << BUFFER_BITS)
)(
    input  logic                         i2s_clk,
    input  logic                         rst,

    input  logic                         sample_in_valid,
    input  logic signed [DATA_WIDTH-1:0] sample_in,
    input  logic [7:0]                   dry_wet,
    input  logic [7:0]                   feedback,
    input  logic [19:0]                  delay_len,
    output logic                         sample_out_valid,
    output logic signed [DATA_WIDTH-1:0] sample_out
);

    // ------------------------------------------------
    // Pointer and address control
    // ------------------------------------------------
    logic [BUFFER_BITS-1:0] write_ptr;
    logic [BUFFER_BITS-1:0] read_ptr;
    logic [BUFFER_BITS-1:0] read_addr_reg;

    logic signed [STORE_WIDTH-1:0] delayed_sample_16;
    logic signed [STORE_WIDTH-1:0] sample_in_16;

    logic [BUFFER_BITS:0] samples_written;

    bram #(
        .DATA_WIDTH(STORE_WIDTH),
        .BUFFER_BITS(BUFFER_BITS)
    ) bram_inst (
        .clk(i2s_clk),
        .rst(rst),
        .we(sample_in_valid),
        .waddr(write_ptr),
        .wdata(store_sample_16),
        .raddr(read_addr_reg),
        .rdata(delayed_sample_16)
    );

    assign sample_in_16 = sample_in[DATA_WIDTH-1 -: STORE_WIDTH];

    // Clamp delay_len to BUFFER_DEPTH-1 and compute read_ptr directly from
    // the input port.  read_addr_reg (registered below on sample_in_valid)
    // provides the single register stage that Vivado requires between any
    // combinatorial fanin and a BRAM read address — delay_len_r is not needed
    // and was causing a one-sample-period lag: it updated on the same clock
    // edge that read_addr_reg was computed from it, so read_ptr always used
    // the previous update's value.
    wire [BUFFER_BITS-1:0] delay_clamped =
        (delay_len[BUFFER_BITS-1:0] >= BUFFER_DEPTH[BUFFER_BITS:0])
            ? {BUFFER_BITS{1'b1}}
            : delay_len[BUFFER_BITS-1:0];
    assign read_ptr = write_ptr - delay_clamped;

    // ------------------------------------------------
    // Dry path: 1-cycle pipeline to align with BRAM read latency
    // ------------------------------------------------
    logic signed [STORE_WIDTH-1:0] dry_pipe1;

    // ------------------------------------------------
    // Fixed-point arithmetic
    // ------------------------------------------------
    logic signed [31:0] feedback_term_full;
    logic signed [31:0] store_full;
    logic signed [STORE_WIDTH-1:0] store_sample_16;

    logic signed [31:0] mix_full;
    logic signed [STORE_WIDTH-1:0] mix_16;

    assign feedback_term_full =
        ($signed({1'b0, feedback}) * $signed(delayed_sample_16)) / 32'sd255;

    assign store_full =
        $signed(sample_in_16) + feedback_term_full;

    assign store_sample_16 =
        store_full[STORE_WIDTH-1:0];

    assign mix_full =
        ($signed({1'b0, dry_wet}) * $signed(delayed_sample_16)) +
        ($signed({1'b0, (8'd255 - dry_wet)}) * $signed(dry_pipe1));

    assign mix_16 =
        mix_full / 32'sd255;

    // ------------------------------------------------
    // Sequential logic
    // ------------------------------------------------
    always_ff @(posedge i2s_clk or posedge rst) begin
        if (rst) begin
            write_ptr         <= '0;
            read_addr_reg     <= '0;

            dry_pipe1         <= '0;
            sample_out        <= '0;
            sample_out_valid  <= 1'b0;
            samples_written   <= '0;
        end
        else begin
            sample_out_valid <= 1'b0;

            if (sample_in_valid) begin
                // ----------------------------------------
                // Register read address
                // ----------------------------------------
                read_addr_reg <= read_ptr;

                // ----------------------------------------
                // Synchronous BRAM write
                // ----------------------------------------
                write_ptr            <= write_ptr + 1'b1;

                // ----------------------------------------
                // Dry path pipeline
                // ----------------------------------------
                dry_pipe1 <= sample_in_16;

                // ----------------------------------------
                // Startup mute: suppress output until the buffer has been
                // filled to at least the current delay depth.
                // delay_clamped derives directly from the delay_len input
                // port (no registered intermediate), so this comparison
                // always reflects the current MMIO value.
                // ----------------------------------------
                if (samples_written < delay_clamped) begin
                    samples_written <= samples_written + 1'b1;
                    sample_out      <= '0;
                end
                else begin
                    sample_out <= {mix_16, {(DATA_WIDTH - STORE_WIDTH){1'b0}}};
                end

                sample_out_valid <= 1'b1;
            end
        end
    end

endmodule
