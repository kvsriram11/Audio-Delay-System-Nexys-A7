# Software

This folder contains the bare-metal C firmware that runs on the **RISC-V core** of the VeeRwolfX SoC. It controls the audio delay parameters in real time by reading the PMOD rotary encoder and writing to the hardware delay line via MMIO registers.

---

## File

**`main.c`** — The entire firmware in a single file. Runs as a polling loop with no OS or RTOS. Peripheral access is done through `READ_REG` and `WRITE_REG` macros that dereference volatile pointers to the correct MMIO addresses, ensuring the compiler does not optimize away hardware-critical reads and writes.

---

## Architecture

The firmware is organized around three responsibilities:

### 1. State Machine

The system is modeled as a **6-state FSM** — two states per parameter (a CTRL state and a SEL state):

```
typedef enum {
    CTRL_DRY_WET = 0,   SEL_DRY_WET  = 1,
    SEL_DELAY    = 2,   CTRL_DELAY   = 3,
    SEL_FEEDBACK = 4,   CTRL_FEEDBACK = 5
} state_t;
```

**CTRL state** — rotating the encoder increments or decrements the active parameter value and immediately writes it to the delay core's MMIO register.

**SEL state** — rotating the encoder cycles between parameters (DRY_WET ↔ DELAY ↔ FEEDBACK). Pressing the button transitions into the corresponding CTRL state. Pressing the button in a CTRL state transitions back to its SEL state.

This gives a single encoder full control over three independent parameters.

```
[reset] ──► CTRL_DRY_WET ◄──btn──► SEL_DRY_WET
                                        │  ▲
                                   enc_CW  enc_CCW
                                        ▼  │
                                     SEL_DELAY ◄──btn──► CTRL_DELAY
                                        │  ▲
                                   enc_CW  enc_CCW
                                        ▼  │
                                   SEL_FEEDBACK ◄──btn──► CTRL_FEEDBACK
```

---

### 2. Encoder Input Decoding

The PMOD rotary encoder outputs a quadrature signal on Channel A and Channel B.

- **Rising edge of Channel A** is detected in the polling loop
- **Channel B is sampled** on that edge to determine rotation direction:
  - `A ≠ B` → Counter-clockwise → increment value (or navigate right in SEL mode)
  - `A = B` → Clockwise → decrement value (or navigate left in SEL mode)
- A **~8000 NOP-cycle debounce delay** is applied after each detected edge before re-reading the encoder

---

### 3. Parameter Representation and MMIO Writes

All three parameters are stored internally as **display-domain integers in the range [0, 100]** in steps of 5, giving 21 discrete positions. Before writing to hardware, values are scaled to the register domain:

| Parameter | Display Domain | Hardware Register | Scale Factor |
|---|---|---|---|
| Dry/Wet Mix | 0 – 100 | 0 – 255 | `hw = display × 255 / 100` |
| Feedback Amount | 0 – 100 | 0 – 255 | `hw = display × 255 / 100` |
| Delay Length | 0 – 100 | 0 – 32700 samples | `hw = display × 327` |

After every parameter write, the `DELAY_UPDATE_EN` register is **pulsed high then low**. This triggers the two-flip-flop synchronizer in the hardware to latch the new values into the MCLK clock domain safely.

---

### 4. LED and Seven-Segment Display Feedback

**LEDs** indicate which parameter is active and what mode it's in:

| LED | CTRL Mode (solid) | SEL Mode (blinking ~4 Hz) |
|---|---|---|
| LED0 | Dry/Wet active | Dry/Wet navigable |
| LED1 | Delay Length active | Delay Length navigable |
| LED2 | Feedback active | Feedback navigable |

Blinking is implemented via a software counter that toggles the LED every `BLINK_HALF_PERIOD` loop iterations — no hardware timer is needed.

**Seven-segment display** shows the current parameter's display-domain value (0–100) in BCD format, updated on every iteration of the main loop.

---

## MMIO Register Map

| Register | Description |
|---|---|
| `DELAY_LEN` | Delay length in samples |
| `FEEDBACK` | Feedback gain (0–255) |
| `DRY_WET` | Dry/wet mix (0–255) |
| `DELAY_UPDATE_EN` | Pulse high to latch new values into MCLK domain |
| `ENC_A` / `ENC_B` / `ENC_BTN` | Rotary encoder GPIO inputs |
| `LED` | LED output register |
| `SEG` | Seven-segment display register |

---

## Building

Compile with a RISC-V RV32IMC cross-compiler. Example using the RVfpga toolchain:

```bash
riscv32-unknown-elf-gcc -march=rv32imc -mabi=ilp32 -O1 -o main.elf main.c
```

Load the resulting ELF onto the RISC-V core via OpenOCD/JTAG as part of the RVfpga workflow.
