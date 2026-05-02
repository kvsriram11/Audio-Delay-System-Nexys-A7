// ============================================================
//  FILENAME: statemachine_led_test.c
//  Author: Aravindh Nanjaiya Latha [aravindh@pdx.edu] and Claude 4.0
//  Created: March 8th, 2026
//  Last Modified: March 18th, 2026
//  DESCRIPTION:
//  PMOD rotary encoder test with:
//    - LEDs indicating current state
//    - 8-digit 7-segment display showing current parameter value (0-100)
//    - Delay line register writes from CTRL states
//    - I2S2 initialization at startup
//
//  Parameters stored in display domain (0-100, step 5 = 21 positions).
//  Hardware values derived at write time:
//    dry/wet  : hw = disp * 255 / 100
//    feedback : hw = disp * 255 / 100
//    delay    : hw = disp * 441  (samples)
//
//  7-seg hardware (from veerwolf_syscon.v):
//    SEVEN_SEG_EN  0x80001038  active-LOW: 0x00 = all digits ON
//    SEVEN_SEG_DIG 0x8000103C  packed BCD nibbles [3:0]=digit0(ones)
//
//  State behavior:
//    CTRL_DRY_WET   : LED0 solid, encoder changes dry_wet_level → writes DELAY_DRY_WET
//    SEL_DRY_WET    : LED0 blink, encoder navigates states
//    SEL_DELAY      : LED1 blink, encoder navigates states
//    CTRL_DELAY     : LED1 solid, encoder changes delay_level   → writes DELAY_LENGTH
//    SEL_FEEDBACK   : LED2 blink, encoder navigates states
//    CTRL_FEEDBACK  : LED2 solid, encoder changes feedback_level → writes DELAY_FEEDBACK
//
//  Full state transition table (CW = clockwise, CCW = counter-clockwise):
//  In SEL states CW moves LED right (higher index), CCW moves LED left.
//
//    State           | btn_press         | enc_CW            | enc_CCW
//    ----------------+-------------------+-------------------+-------------------
//    CTRL_DRY_WET    | → SEL_DRY_WET     | dry_wet+=5        | dry_wet-=5
//    SEL_DRY_WET     | → CTRL_DRY_WET    | → SEL_FEEDBACK    | → SEL_DELAY
//    SEL_DELAY       | → CTRL_DELAY      | → SEL_DRY_WET     | → SEL_FEEDBACK
//    CTRL_DELAY      | → SEL_DELAY       | delay+=5          | delay-=5
//    SEL_FEEDBACK    | → CTRL_FEEDBACK   | → SEL_DELAY       | → SEL_DRY_WET
//    CTRL_FEEDBACK   | → SEL_FEEDBACK    | feedback+=5       | feedback-=5
// ============================================================

// ============================================================
//  MMIO addresses
// ============================================================
#define GPIO_LED_SW     0x80001404
#define GPIO_INOUT      0x80001408
#define GPIO_ENCODER    0x80001600

#define SEVEN_SEG_EN    0x80001038
#define SEVEN_SEG_DIG   0x8000103C

#define DELAY_DRY_WET   0x80003000
#define DELAY_FEEDBACK  0x80003004
#define DELAY_LENGTH    0x80003008
#define DELAY_UPDATE_EN 0x8000300C

#define READ_REG(addr)         (*(volatile unsigned int *)(addr))
#define WRITE_REG(addr, value) (*(volatile unsigned int *)(addr) = (value))

// ---- Encoder bits ----
#define ENC_A_MASK    0x01
#define ENC_B_MASK    0x02
#define ENC_BTN_MASK  0x04

// ---- LED bits ----
#define LED0 (1u << 0)
#define LED1 (1u << 1)
#define LED2 (1u << 2)

// ============================================================
//  All parameters are stored as display-domain values (0-100)
//  in steps of 5, giving exactly 21 positions (0,5,10,...,100).
//  Hardware registers receive values scaled from the display value:
//    dry/wet  : hw = disp * 255 / 100
//    feedback : hw = disp * 255 / 100
//    delay    : hw = disp * 441          (441 samples per 1% of 44100)
// ============================================================
#define DISP_MIN   0u
#define DISP_MAX   100u
#define DISP_STEP  5u           // 5% per encoder click → 21 positions

#define BLINK_HALF_PERIOD 120000u

// ============================================================
//  Display → hardware conversion
// ============================================================
#define HW_DRY_WET(disp)   ((disp) * 255u / 100u)
#define HW_FEEDBACK(disp)  ((disp) * 255u / 100u)
#define HW_DELAY(disp)     ((disp) * 327u)

// ============================================================
//  State definitions
// ============================================================
typedef enum {
    CTRL_DRY_WET  = 0,
    SEL_DRY_WET   = 1,
    SEL_DELAY     = 2,
    CTRL_DELAY    = 3,
    SEL_FEEDBACK  = 4,
    CTRL_FEEDBACK = 5
} state_t;

// ============================================================
//  Debounce helpers
// ============================================================
static void short_delay(unsigned int n)
{
    volatile unsigned int i;
    for (i = 0; i < n; i++) {
        __asm__("nop");
    }
}

static void debounce_delay(void)
{
    short_delay(8000);
}

// ============================================================
//  LED helpers
// ============================================================
static void set_leds(unsigned int mask)
{
    WRITE_REG(GPIO_LED_SW, mask);
}

static void blink_reset(unsigned int led_bit,
                        unsigned int *blink_counter,
                        unsigned int *blink_state)
{
    *blink_counter = 0;
    *blink_state   = 1;
    set_leds(led_bit);
}

static void blink_tick(unsigned int led_bit,
                       unsigned int *blink_counter,
                       unsigned int *blink_state)
{
    (*blink_counter)++;
    if (*blink_counter >= BLINK_HALF_PERIOD) {
        *blink_counter = 0;
        *blink_state = !(*blink_state);
        set_leds((*blink_state) ? led_bit : 0u);
    }
}

static void wait_for_button_release(void)
{
    while (READ_REG(GPIO_ENCODER) & ENC_BTN_MASK) {
        __asm__("nop");
    }
    debounce_delay();
}

// ============================================================
//  7-segment helpers
//
//  to_bcd   : decimal value → packed BCD nibbles for Digits_Reg
//  sevenseg_show : drives EN (active-low) and DIG every call
// ============================================================
static unsigned int to_bcd(unsigned int val)
{
    unsigned int bcd   = 0;
    unsigned int shift = 0;
    while (shift < 32) {
        bcd |= ((val % 10u) << shift);
        val /= 10u;
        shift += 4;
        if (val == 0u) break;
    }
    return bcd;
}

static void sevenseg_show(unsigned int value)
{
    WRITE_REG(SEVEN_SEG_EN,  0x00);           // active-LOW: 0x00 = all digits ON
    WRITE_REG(SEVEN_SEG_DIG, to_bcd(value));  // packed BCD
}

// ============================================================
//  Return the display value (0-100) for the current state.
//  Levels are already stored in display domain so no scaling needed.
// ============================================================
static unsigned int current_display_value(state_t state,
                                          unsigned int dry_wet_level,
                                          unsigned int delay_level,
                                          unsigned int feedback_level)
{
    switch (state) {
        case CTRL_DRY_WET:  case SEL_DRY_WET:   return dry_wet_level;
        case CTRL_DELAY:    case SEL_DELAY:       return delay_level;
        case CTRL_FEEDBACK: case SEL_FEEDBACK:    return feedback_level;
        default:                                  return 0;
    }
}

// ============================================================
//  Write all three delay params to hardware and latch.
//  Levels are in display domain (0-100); convert to hardware units.
// ============================================================
static void write_delay_params(unsigned int dry_wet_level,
                               unsigned int delay_level,
                               unsigned int feedback_level)
{
    WRITE_REG(DELAY_DRY_WET,   HW_DRY_WET(dry_wet_level));
    WRITE_REG(DELAY_FEEDBACK,  HW_FEEDBACK(feedback_level));
    WRITE_REG(DELAY_LENGTH,    HW_DELAY(delay_level));
    WRITE_REG(DELAY_UPDATE_EN, 1u);
}

// (encoder logic inlined in main loop, see below)

// ============================================================
//  Main
// ============================================================
int main(void)
{
    state_t state = CTRL_DRY_WET;

    unsigned int blink_counter = 0;
    unsigned int blink_state   = 1;

    // Levels stored in display domain (0-100, multiples of 5)
    unsigned int dry_wet_level  = 50;
    unsigned int delay_level    = 50;
    unsigned int feedback_level = 0;

    // ----------------------------------------------------------
    //  Hardware init
    // ----------------------------------------------------------
    WRITE_REG(GPIO_INOUT, 0x0000FFFF);
    write_delay_params(dry_wet_level, delay_level, feedback_level);
    set_leds(LED0);

    /* Seed a_last so the first loop iteration doesn't misfire */
    unsigned int a_last = READ_REG(GPIO_ENCODER) & ENC_A_MASK;

    // ----------------------------------------------------------
    //  Main poll loop
    // ----------------------------------------------------------
    while (1) {
        unsigned int current_read = READ_REG(GPIO_ENCODER);
        unsigned int a_now  = current_read & ENC_A_MASK;
        unsigned int b_now  = (current_read >> 1) & 0x01;
        unsigned int btn_now = (current_read & ENC_BTN_MASK) >> 2;

        // Drive 7-seg with scaled 0-100 value every loop
        sevenseg_show(current_display_value(state,
                                            dry_wet_level,
                                            delay_level,
                                            feedback_level));

        // ------------------------------------------------
        //  Encoder rotation: rising-edge-of-A (from main.c)
        // ------------------------------------------------
        if (a_now == 1 && a_last == 0) {
            debounce_delay();

            if (READ_REG(GPIO_ENCODER) & ENC_A_MASK) {
                /* a_now != b_now → CCW (+LED index / +value)
                   a_now == b_now → CW  (-LED index / -value)  */
                int ccw = (a_now != b_now);
                int cw  = !ccw;

                switch (state) {

                    // SEL states: navigate between parameters.
                    // CCW → higher LED index (LED0→LED1→LED2).
                    // CW  → lower  LED index (LED2→LED1→LED0).
                    case SEL_DRY_WET:
                        if (ccw)     { state = SEL_DELAY;    blink_reset(LED1, &blink_counter, &blink_state); }
                        else if (cw) { state = SEL_FEEDBACK; blink_reset(LED2, &blink_counter, &blink_state); }
                        break;

                    case SEL_DELAY:
                        if (ccw)     { state = SEL_FEEDBACK; blink_reset(LED2, &blink_counter, &blink_state); }
                        else if (cw) { state = SEL_DRY_WET;  blink_reset(LED0, &blink_counter, &blink_state); }
                        break;

                    case SEL_FEEDBACK:
                        if (ccw)     { state = SEL_DRY_WET;  blink_reset(LED0, &blink_counter, &blink_state); }
                        else if (cw) { state = SEL_DELAY;    blink_reset(LED1, &blink_counter, &blink_state); }
                        break;

                    // CTRL states: adjust display-domain value (0-100, step 5) + write hw
                    case CTRL_DRY_WET:
                        if (ccw && dry_wet_level < DISP_MAX)
                            dry_wet_level += DISP_STEP;
                        else if (cw && dry_wet_level > DISP_MIN)
                            dry_wet_level -= DISP_STEP;
                        WRITE_REG(DELAY_DRY_WET,   HW_DRY_WET(dry_wet_level));
                        WRITE_REG(DELAY_UPDATE_EN, 1u);
                        break;

                    case CTRL_DELAY:
                        if (ccw && delay_level < DISP_MAX)
                            delay_level += DISP_STEP;
                        else if (cw && delay_level > DISP_MIN)
                            delay_level -= DISP_STEP;
                        WRITE_REG(DELAY_LENGTH,    HW_DELAY(delay_level));
                        WRITE_REG(DELAY_UPDATE_EN, 1u);
                        break;

                    case CTRL_FEEDBACK:
                        if (ccw && feedback_level < DISP_MAX)
                            feedback_level += DISP_STEP;
                        else if (cw && feedback_level > DISP_MIN)
                            feedback_level -= DISP_STEP;
                        WRITE_REG(DELAY_FEEDBACK,  HW_FEEDBACK(feedback_level));
                        WRITE_REG(DELAY_UPDATE_EN, 1u);
                        break;

                    default:
                        break;
                }

                debounce_delay();
            }
        }

        a_last = a_now;

        // ------------------------------------------------
        //  Button handling
        // ------------------------------------------------
        if (btn_now) {
            debounce_delay();

            if (READ_REG(GPIO_ENCODER) & ENC_BTN_MASK) {
                switch (state) {
                    case CTRL_DRY_WET:
                        state = SEL_DRY_WET;
                        blink_reset(LED0, &blink_counter, &blink_state);
                        break;
                    case SEL_DRY_WET:
                        state = CTRL_DRY_WET;
                        set_leds(LED0);
                        break;
                    case SEL_DELAY:
                        state = CTRL_DELAY;
                        set_leds(LED1);
                        break;
                    case CTRL_DELAY:
                        state = SEL_DELAY;
                        blink_reset(LED1, &blink_counter, &blink_state);
                        break;
                    case SEL_FEEDBACK:
                        state = CTRL_FEEDBACK;
                        set_leds(LED2);
                        break;
                    case CTRL_FEEDBACK:
                        state = SEL_FEEDBACK;
                        blink_reset(LED2, &blink_counter, &blink_state);
                        break;
                    default:
                        state = CTRL_DRY_WET;
                        set_leds(LED0);
                        break;
                }
                wait_for_button_release();
            }
        }

        // ------------------------------------------------
        //  Blink tick in SEL states
        // ------------------------------------------------
        switch (state) {
            case SEL_DRY_WET:  blink_tick(LED0, &blink_counter, &blink_state); break;
            case SEL_DELAY:    blink_tick(LED1, &blink_counter, &blink_state); break;
            case SEL_FEEDBACK: blink_tick(LED2, &blink_counter, &blink_state); break;
            default: break;
        }
    }

    return 0;
}
