# Constraints

This folder contains the Vivado XDC pin constraints file for the Nexys A7 board.

## File

**`rvfpganexys.xdc`** — Defines pin assignments and I/O standards for all top-level ports in `rvfpganexys.sv`, including:

- **Clock**: 100 MHz system clock input
- **PMOD I2S2**: MCLK, SCLK, LRCLK, SDIN (RX), SDOUT (TX)
- **PMOD Rotary Encoder**: Channel A, Channel B, Button
- **LEDs**: LED0–LED2 (parameter selection feedback)
- **7-Segment Display**: Cathodes and anodes for all 8 digits
- **PLL constraints**: Timing constraints for the MCLK (22.579 MHz) and SoC clock (12.5 MHz) generated via PLLE

## Usage

In Vivado, add `rvfpganexys.xdc` as a constraint source alongside the HDL files. No modifications should be needed if the top-level port names in `rvfpganexys.sv` are unchanged.
