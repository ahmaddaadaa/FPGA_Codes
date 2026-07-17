#pragma once

#if defined(HARDWARE_EXACT_USE_AP_INT) || defined(__SYNTHESIS__)
#define HARDWARE_EXACT_AP_INT 1
#elif defined(__has_include)
#if __has_include(<ap_int.h>)
#define HARDWARE_EXACT_AP_INT 1
#endif
#endif

#ifdef HARDWARE_EXACT_AP_INT
#include <ap_int.h>
#else
#include <cstdint>
#endif

namespace hardware_exact_p16 {

constexpr int NUM_INPUTS = 784;
constexpr int NUM_HIDDEN1 = 64;
constexpr int NUM_HIDDEN2 = 32;
constexpr int NUM_OUTPUTS = 10;
constexpr int NUM_BIASES = NUM_HIDDEN1 + NUM_HIDDEN2 + NUM_OUTPUTS;

constexpr int PARALLEL_LANES = 16;
constexpr int LAYER1_GROUPS = 4;
constexpr int LAYER2_GROUPS = 2;
constexpr int LAYER3_GROUPS = 1;
constexpr int W1_BANK_BASE = 0;
constexpr int W2_BANK_BASE = W1_BANK_BASE + LAYER1_GROUPS * NUM_INPUTS;
constexpr int W3_BANK_BASE = W2_BANK_BASE + LAYER2_GROUPS * NUM_HIDDEN1;
constexpr int WEIGHT_BANK_DEPTH = W3_BANK_BASE + LAYER3_GROUPS * NUM_HIDDEN2;

constexpr int B1_BASE = 0;
constexpr int B2_BASE = B1_BASE + NUM_HIDDEN1;
constexpr int B3_BASE = B2_BASE + NUM_HIDDEN2;

// Frozen development configuration h1_9_h2_9. Any change requires a new
// manifest/model ID rather than an edit to this baseline.
constexpr int HIDDEN1_SHIFT = 9;
constexpr int HIDDEN2_SHIFT = 9;

#ifdef HARDWARE_EXACT_AP_INT
using data_t = ap_int<8>;
using product_t = ap_int<16>;
using accum_t = ap_int<32>;
#else
using data_t = std::int8_t;
using product_t = std::int16_t;
using accum_t = std::int32_t;
#endif

static_assert(PARALLEL_LANES == 16, "The frozen accelerator is P16.");
static_assert(WEIGHT_BANK_DEPTH == 3296, "Unexpected P16 bank depth.");
static_assert(HIDDEN1_SHIFT == 9, "Frozen hidden-1 shift changed.");
static_assert(HIDDEN2_SHIFT == 9, "Frozen hidden-2 shift changed.");

product_t exact_mul8s(data_t lhs, data_t rhs);

void exact_mul8s_top(data_t lhs, data_t rhs, product_t& product);

void hardware_exact_p16(
    const data_t input[NUM_INPUTS],
    const data_t weights[PARALLEL_LANES][WEIGHT_BANK_DEPTH],
    const accum_t biases[NUM_BIASES],
    accum_t outputs[NUM_OUTPUTS]
);

}  // namespace hardware_exact_p16

void hardware_exact_p16_top(
    const hardware_exact_p16::data_t input[hardware_exact_p16::NUM_INPUTS],
    const hardware_exact_p16::data_t
        weights[hardware_exact_p16::PARALLEL_LANES]
               [hardware_exact_p16::WEIGHT_BANK_DEPTH],
    const hardware_exact_p16::accum_t
        biases[hardware_exact_p16::NUM_BIASES],
    hardware_exact_p16::accum_t
        outputs[hardware_exact_p16::NUM_OUTPUTS]
);


// Board-comparison drop-in.  Keeping the generated top-level name identical
// to the Vakili implementation lets Vivado reuse the exact same P16 memories,
// transport shells, and constraints so the post-route resource delta isolates
// the multiplier implementation.
void vakili_r1_p16_top(
    const hardware_exact_p16::data_t input[hardware_exact_p16::NUM_INPUTS],
    const hardware_exact_p16::data_t
        weights[hardware_exact_p16::PARALLEL_LANES]
               [hardware_exact_p16::WEIGHT_BANK_DEPTH],
    const hardware_exact_p16::accum_t
        biases[hardware_exact_p16::NUM_BIASES],
    hardware_exact_p16::accum_t
        outputs[hardware_exact_p16::NUM_OUTPUTS]
);
