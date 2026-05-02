
module bram #(
    parameter int DATA_WIDTH  = 16,
    parameter int BUFFER_BITS = 16,
    parameter int BUFFER_DEPTH = (1 << BUFFER_BITS)  // must be a power of two
)(
    input  logic                          clk,
    input  logic                          rst,
    input  logic                          we,
    input  logic [BUFFER_BITS-1:0]        waddr,
    input  logic signed [DATA_WIDTH-1:0]  wdata,
    input  logic [BUFFER_BITS-1:0]        raddr,
    output logic signed [DATA_WIDTH-1:0]  rdata
);

    (* ram_style = "block" *)
    logic signed [DATA_WIDTH-1:0] mem [0:BUFFER_DEPTH-1];

    // Write port — separate always_ff required for Vivado BRAM inference.
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
    end

    // Read port — separate always_ff gives READ_FIRST behaviour when
    // waddr == raddr, which is correct for a delay line (read the old
    // sample, then overwrite with the new one).
    always_ff @(posedge clk or posedge rst) begin
        if (rst) rdata <= '0;
        else rdata <= mem[raddr];
    end

endmodule

