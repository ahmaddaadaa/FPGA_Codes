#pragma once

#if defined(VAKILI_R1_USE_AP_INT) || defined(__SYNTHESIS__)
#define VAKILI_R1_AP_INT 1
#elif defined(__has_include)
#if __has_include(<ap_int.h>)
#define VAKILI_R1_AP_INT 1
#endif
#endif

#ifdef VAKILI_R1_AP_INT
#include <ap_int.h>
#else
#include <cstdint>
#endif

namespace vakili_r1_p16 {

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

// These values belong to the frozen exact-INT8 development baseline.  This
// experiment changes only the multiplier, not quantization or requantization.
constexpr int HIDDEN1_SHIFT = 9;
constexpr int HIDDEN2_SHIFT = 9;

#ifdef VAKILI_R1_AP_INT
using data_t = ap_int<8>;
using product_t = ap_int<16>;
using accum_t = ap_int<32>;
#else
using data_t = std::int8_t;
using product_t = std::int16_t;
using accum_t = std::int32_t;
#endif

static_assert(PARALLEL_LANES == 16, "The controlled experiment is P16.");
static_assert(WEIGHT_BANK_DEPTH == 3296, "Unexpected P16 bank depth.");
static_assert(HIDDEN1_SHIFT == 9, "Frozen hidden-1 shift changed.");
static_assert(HIDDEN2_SHIFT == 9, "Frozen hidden-2 shift changed.");

// Operand order is part of the contract: R1(weight, activation).
product_t vakili_r1_mul8s(data_t weight, data_t activation);

void vakili_r1_mul8s_top(
    data_t weight,
    data_t activation,
    product_t& product
);

void vakili_r1_p16(
    const data_t input[NUM_INPUTS],
    const data_t weights[PARALLEL_LANES][WEIGHT_BANK_DEPTH],
    const accum_t biases[NUM_BIASES],
    accum_t outputs[NUM_OUTPUTS]
);

}  // namespace vakili_r1_p16

void vakili_r1_p16_top(
    const vakili_r1_p16::data_t input[vakili_r1_p16::NUM_INPUTS],
    const vakili_r1_p16::data_t
        weights[vakili_r1_p16::PARALLEL_LANES]
               [vakili_r1_p16::WEIGHT_BANK_DEPTH],
    const vakili_r1_p16::accum_t biases[vakili_r1_p16::NUM_BIASES],
    vakili_r1_p16::accum_t outputs[vakili_r1_p16::NUM_OUTPUTS]
);

