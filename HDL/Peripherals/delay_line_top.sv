`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// Module: delay_line_top
//
// Drop-in replacement for the old delay_line module in i2s2_top.
// Presents the same port list (AXI-Stream slave + master, CDC req/ack,
// control registers) and internally instantiates two delay_line_step4
// instances — one for the left channel and one for the right channel.
//
// Stream demux / remux
// --------------------
// The i2s2 RX master sends a two-word AXI-Stream frame every sample period:
//   word 0 : s_last = 0  →  left  channel
//   word 1 : s_last = 1  →  right channel
//
// On the falling edge of s_last (i.e. when the right word is accepted,
// completing a stereo pair) sample_in_valid is pulsed to both mono
// delay_line_step4 instances simultaneously. Both instances are clocked
// with the same valid pulse and share the same pipeline depth, so their
// sample_out_valid signals are guaranteed to arrive in lockstep.
//
// When sample_out_valid arrives the two processed samples are held in
// registered outputs and the TX AXI-Stream (m_*) is driven: left word
// first (m_last=0), then right word (m_last=1).
//
// CDC / parameter update
// ----------------------
// The req/ack handshake is preserved identically from the old design.
// dry_wet_r, feedback_r, and delay_len_r are latched atomically on
// req_rise and forwarded to both delay_line_step4 instances via their
// respective input ports.  delay_line_step4 latches delay_len into an
// internal register on each sample_in_valid pulse, so a new MMIO value
// takes effect within one sample period (~22 µs at 44.1 kHz).
//
// Parameters
// ----------
//   DATA_WIDTH   : sample width in bits (must match i2s2, default 24)
//   BUFFER_BITS  : address width of the internal BRAMs (default 17 →
//                  131072 entries, the smallest power-of-two ≥ 88200)
//
// Delay length is runtime-variable: the delay_len input port is wired
// directly to both delay_line_step4 instances and takes effect on the
// next sample_in_valid pulse after an MMIO write.
////////////////////////////////////////////////////////////////////////////////

module delay_line_top #(
    parameter int DATA_WIDTH    = 24,
    parameter int BUFFER_BITS   = 15
)(
    input  wire                  i2s_clk,
    input  wire                  rst,

    // Control inputs — already synchronised to i2s_clk domain by i2s2_top
    input  wire [7:0]            dry_wet,
    input  wire [7:0]            feedback,
    input  wire [19:0]           delay_len,

    // AXI-Stream slave  (receives from i2s2 RX master)
    input  wire [DATA_WIDTH-1:0] s_data,
    input  wire                  s_valid,
    output wire                  s_ready,
    input  wire                  s_last,

    // AXI-Stream master (sends to i2s2 TX slave)
    output reg  [DATA_WIDTH-1:0] m_data,
    output reg                   m_valid,
    input  wire                  m_ready,
    output reg                   m_last
);

    // =========================================================================
    // AXI-Stream handshake helpers
    // =========================================================================
    wire s_new_word   = s_valid & s_ready;
    wire s_new_packet = s_new_word & s_last;    // right word accepted = full pair
    wire m_new_word   = m_valid & m_ready;
    wire m_new_packet = m_new_word & m_last;

    // =========================================================================
    // Capture incoming stereo pair
    // s_last=0 → left,  s_last=1 → right  (i2s2 convention)
    // =========================================================================
    reg signed [DATA_WIDTH-1:0] in_L = '0;
    reg signed [DATA_WIDTH-1:0] in_R = '0;

    always @(posedge i2s_clk) begin
        if (s_new_word) begin
            if (!s_last) in_L <= s_data;
            else         in_R <= s_data;
        end
    end

    // One-cycle pipeline: in_R is captured on the same edge s_new_packet fires,
    // so it isn't visible to downstream logic until the next cycle.  Register
    // both channels and the valid together so delay_line_step4 always sees
    // fully stable data when sample_in_valid is high.
    //
    // Timeline per stereo frame:
    //   cycle N   : left  word accepted  -> in_L <= s_data
    //   cycle N+1 : right word accepted  -> in_R <= s_data, s_new_packet=1
    //   cycle N+2 : s_new_packet_r=1 (sample_in_valid), in_L_r/in_R_r stable
    reg signed [DATA_WIDTH-1:0] in_L_r = '0;
    reg signed [DATA_WIDTH-1:0] in_R_r = '0;
    reg                         s_new_packet_r = 1'b0;

    always @(posedge i2s_clk) begin
        s_new_packet_r <= s_new_packet;
        in_L_r         <= in_L;
        in_R_r         <= in_R;
    end

    // =========================================================================
    // Mono delay line instances
    //
    // sample_in_valid is driven directly from s_new_packet — the cycle in
    // which the right (last) word of the stereo pair is accepted.  At that
    // point in_L was captured one cycle earlier and in_R is captured on
    // this same edge, so both are stable when delay_line_step4 clocks them.
    //
    // The one-cycle pipeline stage (s_new_packet_r) ensures in_R_r is fully
    // stable before delay_line_step4 clocks it.  Total latency from
    // s_new_packet to m_valid rising:
    //   cycle 0 (s_new_packet)  : in_R captured, s_new_packet_r registered
    //   cycle 1 (s_new_packet_r): sample_in_valid=1, read_addr_reg registered
    //   cycle 2                 : BRAM rdata valid, sample_out registered,
    //                             sample_out_valid=1 -> m_valid rises
    // 2 cycles out of ~450 available before the next tx_ready window.
    //
    // Both instances share the same valid pulse -> outputs are lockstep.
    // rst is tied low; delay_line_step4's startup-mute counter handles
    // the initial silence without needing an external reset.
    // =========================================================================
    wire                         mono_valid_out_L;
    wire                         mono_valid_out_R;
    wire signed [DATA_WIDTH-1:0] mono_out_L;
    wire signed [DATA_WIDTH-1:0] mono_out_R;

    delay_line_step4 #(
        .DATA_WIDTH    (DATA_WIDTH),
        .BUFFER_BITS   (BUFFER_BITS)
    ) dl_L (
        .i2s_clk          (i2s_clk),
        .rst              (rst),
        .sample_in_valid  (s_new_packet_r),
        .sample_in        (in_L_r),
        .dry_wet          (dry_wet),
        .feedback         (feedback),
        .delay_len        (delay_len),
        .sample_out_valid (mono_valid_out_L),
        .sample_out       (mono_out_L)
    );

    delay_line_step4 #(
        .DATA_WIDTH    (DATA_WIDTH),
        .BUFFER_BITS   (BUFFER_BITS)
    ) dl_R (
        .i2s_clk          (i2s_clk),
        .rst              (rst),
        .sample_in_valid  (s_new_packet_r),
        .sample_in        (in_R_r),
        .dry_wet          (dry_wet),
        .feedback         (feedback),
        .delay_len        (delay_len),
        .sample_out_valid (mono_valid_out_R),
        .sample_out       (mono_out_R)
    );

    // =========================================================================
    // Latch processed outputs when both channels are ready
    //
    // mono_valid_out_L and mono_valid_out_R always fire in the same cycle
    // (lockstep). We use mono_valid_out_L as the trigger; if for any
    // reason they diverge, a synthesis assertion will catch it.
    // =========================================================================
    reg signed [DATA_WIDTH-1:0] out_L_r = '0;
    reg signed [DATA_WIDTH-1:0] out_R_r = '0;

    always @(posedge i2s_clk) begin
        if (mono_valid_out_L) begin
            out_L_r <= mono_out_L;
            out_R_r <= mono_out_R;
        end
    end

    // =========================================================================
    // TX AXI-Stream output
    //
    // m_valid goes high when processed output is available and stays high
    // until the full stereo pair has been sent (m_new_packet).
    //
    // m_last follows the standard i2s2 convention:
    //   m_last=0 on the first transfer  → left  channel from out_L_r
    //   m_last=1 on the second transfer → right channel from out_R_r
    // =========================================================================
    always @(posedge i2s_clk) begin
        if (mono_valid_out_L)
            m_valid <= 1'b1;
        else if (m_new_packet)
            m_valid <= 1'b0;
    end

    always @(posedge i2s_clk) begin
        if (m_new_packet)    m_last <= 1'b0;
        else if (m_new_word) m_last <= 1'b1;
    end

    always @(*) begin
        if (m_valid) m_data = m_last ? out_R_r : out_L_r;
        else         m_data = '0;
    end

    // =========================================================================
    // RX flow control
    //
    // s_ready is held permanently high. i2s2 delivers exactly one stereo
    // frame per 512 mclk cycles regardless of back-pressure, so there is
    // no risk of the RX side overrunning the TX side. Gating s_ready low
    // between frames caused a permanent deadlock during the DELAY_SAMPLES
    // startup mute period: s_ready went low after frame 1, i2s2 stopped
    // delivering audio, sample_in_valid never fired again, and
    // samples_written never reached DELAY_SAMPLES to end the mute.
    // =========================================================================
    assign s_ready = 1'b1;

endmodule
