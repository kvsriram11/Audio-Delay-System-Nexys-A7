# HDL

This folder contains all SystemVerilog hardware design files for the FPGA-Based Audio Delay System. The design targets the **Nexys A7 (Artix-7 XC7A100T)** board and is integrated into the **VeeRwolfX RISC-V SoC** via the Wishbone interconnect.

---

## File Overview

```
HDL/
├── rvfpganexys.sv        # Top-level SoC wrapper
├── veerwolf_core.v       # VeeRwolfX RISC-V SoC core (unmodified)
└── I2S2/
    ├── i2s2_top.sv       # I2S2 Wishbone peripheral top
    ├── i2s2.sv           # I2S receive/transmit logic
    ├── delay_line_top.sv # Stereo delay line top
    ├── delay_line.sv     # Mono delay line (circular buffer, feedback, mix)
    └── bram.sv           # Synchronous BRAM wrapper
```

---

## Module Descriptions

### `rvfpganexys.sv` — Top-Level SoC Wrapper

The top-level module for the entire system. Instantiates the VeeRwolfX SoC core and connects all custom peripherals to it. Responsibilities include:

- Generating MCLK (22.579 MHz) and the SoC clock (12.5 MHz) from the 100 MHz board clock using the PLLE2_BASE primitive
- Wiring the PMOD I2S2 and PMOD Rotary Encoder pins to their respective peripheral modules
- Connecting the I2S2 Wishbone peripheral and GPIO encoder peripheral to the SoC's Wishbone bus
- Routing LED and seven-segment display signals from the SoC to the board I/O

---

### `veerwolf_core.v` — VeeRwolfX RISC-V SoC Core

The unmodified VeeRwolfX SoC core. Contains the SweRV EH1 RISC-V pipeline, Wishbone interconnect, GPIO peripheral, UART, and other standard SoC components. The RISC-V core runs the firmware from `Software/main.c` which controls the delay parameters via MMIO writes.

This file is included as-is from the RVfpga platform and is not modified by this project.

---

### `i2s2_top.sv` — I2S2 Wishbone Peripheral Top

The top-level wrapper that integrates the I2S2 audio interface into the VeeRwolfX Wishbone bus. Responsibilities include:

- Accepting the MCLK input and distributing it to the PMOD I2S2 codec pins and the delay line
- Instantiating `i2s2.sv` and `delay_line_top.sv` and wiring them together
- Exposing MMIO registers (delay length, feedback, dry/wet, update enable) to the Wishbone bus for software access
- Implementing the two-flip-flop synchronizer that safely transfers MMIO register values from the SoC clock domain (12.5 MHz) to the MCLK domain (22.579 MHz) using a software-pulsed enable bit

---

### `i2s2.sv` — I2S Receive/Transmit Logic

Implements the I2S audio receive and transmit protocols for the PMOD I2S2 peripheral. Based on Digilent's AXI-stream I2S2 reference design, adapted for Wishbone compliance and direct delay line interfacing. Key details:

- SCLK (~2.822 MHz) and LRCLK (~44.1 kHz) are generated internally via counter-based clock dividers off MCLK
- Audio samples are **24-bit**, streamed continuously with no flow control
- Separate RX and TX logic sections share the same clock signals; signals are prefixed `rx_` and `tx_` respectively
- Interfaces with `delay_line_top.sv` using a `valid/ready/last` handshake:
  - `rx_valid` / `rx_ready` / `rx_last` — signals a new received sample is available
  - `tx_valid` / `tx_ready` / `tx_last` — signals the delay line output is ready to transmit

---

### `delay_line_top.sv` — Stereo Delay Line Top

Integration layer between the I2S interface and the mono delay processing core. Handles stereo decomposition and reassembly:

- Captures the interleaved stereo stream from I2S RX into separate left (`in_L`) and right (`in_R`) registers based on the `rx_last` channel flag
- Introduces a **one-cycle pipeline register stage** (`in_L_r`, `in_R_r`, `s_new_packet_r`) to ensure stable inputs to the delay modules
- Instantiates **two instances of `delay_line.sv`** running in lockstep — one for the left channel, one for the right — sharing the same clock, valid signal, and control parameters
- Serializes the processed stereo outputs back to the I2S TX interface (left channel first, then right), preserving the original stereo frame format
- Continuously asserts RX ready to prevent deadlock during buffer initialization startup

**Control parameters passed to both instances:**
| Parameter | Width | Description |
|---|---|---|
| `delay_len` | 15-bit | Number of samples of delay (max ~32k) |
| `feedback` | 8-bit | Feedback gain (0–255, scaled from 0–100%) |
| `dry_wet` | 8-bit | Dry/wet mix (0 = fully dry, 255 = fully wet) |

---

### `delay_line.sv` — Mono Delay Line (Core DSP Module)

The heart of the audio effect — a single-channel delay line with feedback and dry/wet mixing, implemented as a BRAM circular buffer. This is the primary RTL contribution of this project.

#### Signal Processing Pipeline

```
Audio In (24-bit)
      │
      ▼
  Truncate to 16-bit
      │
      ├─────────────────────────────────────┐
      ▼                                     │ dry path (pipelined)
  Add feedback ◄── scale(delayed, feedback) │
      │                                     │
      ▼                                     │
   BRAM Write (write_ptr)                   │
      │                                     │
      ▼                                     │
   BRAM Read  (write_ptr − delay_clamped)   │
      │                                     │
      ▼                                     │
  delayed sample (16-bit → 24-bit)          │
      │                                     │
      ▼                                     ▼
     wet mix ──────────────────────── dry mix
      │
      ▼
  Audio Out (24-bit)
```

#### Key Implementation Details

**Circular Buffer Addressing**
- `write_ptr` increments on every valid sample and wraps automatically by its fixed bit width — no explicit modulo needed
- `read_ptr = write_ptr − delay_clamped` — delay length is clamped to prevent reads beyond the buffer capacity
- Simultaneous read and write are supported each clock cycle for uninterrupted streaming

**BRAM Latency Compensation**
- BRAM read has a one-cycle registered latency (`read_addr_reg` is registered before the BRAM read)
- The dry signal path is pipelined by one cycle (`dry_pipe1`) to maintain temporal alignment between dry and wet signals at the mixer

**Feedback Path**
- The delayed output is scaled by `feedback` (8-bit fixed-point) using a DSP multiplier
- The scaled result is summed with the current input sample before being written back into the BRAM, creating recursive echo

**Dry/Wet Mixing**
- Both dry and wet signals are scaled using fixed-point multiply (DSP blocks) and summed to produce the final output
- Each channel uses **4 DSP slices** (feedback multiply + wet multiply + associated arithmetic)

**Startup Mute**
- A `samples_written` counter tracks how many samples have been stored since reset
- Output is suppressed (muted) until `samples_written >= delay_clamped`, preventing invalid data from an unfilled buffer from reaching the output

**Bit-Width Optimization**
- 24-bit input samples are truncated to **16-bit** before BRAM storage, halving memory usage
- On readback, 16-bit samples are sign-extended back to 24-bit for processing and output

---

### `bram.sv` — Synchronous BRAM Wrapper

A simple synchronous single-port BRAM wrapper inferred for Xilinx Block RAM primitives. Provides:

- Configurable data width (16-bit) and address width (matching delay buffer depth)
- Synchronous write on clock edge when write enable is asserted
- Registered read output (one-cycle read latency), consistent with standard BRAM timing

Instantiated once per `delay_line.sv` instance (i.e., twice total — one per stereo channel).

---

## Design Hierarchy

```
rvfpganexys (top)
├── veerwolf_core           (RISC-V SoC)
└── i2s2_top                (I2S2 Wishbone peripheral)
    ├── i2s2                (I2S RX/TX protocol)
    └── delay_line_top      (Stereo delay integration)
        ├── delay_line [L]  (Left channel mono delay)
        │   └── bram        (Left channel BRAM buffer)
        └── delay_line [R]  (Right channel mono delay)
            └── bram        (Right channel BRAM buffer)
```

---

## Clock Domain Summary

| Module | Clock Domain | Frequency |
|---|---|---|
| `veerwolf_core` | SoC Clock | 12.5 MHz |
| `i2s2_top` (MMIO registers) | SoC Clock | 12.5 MHz |
| `i2s2_top` (synchronizer) | MCLK | 22.579 MHz |
| `i2s2` | MCLK | 22.579 MHz |
| `delay_line_top` | MCLK | 22.579 MHz |
| `delay_line` | MCLK | 22.579 MHz |
| `bram` | MCLK | 22.579 MHz |

Cross-domain crossing between the SoC clock and MCLK is handled entirely within `i2s2_top.sv` using a two-flip-flop synchronizer on the `update_en` bit.
