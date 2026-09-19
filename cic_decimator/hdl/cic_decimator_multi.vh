// Helpers for cic_decimator_multi.

// G(M) = ceil(M*log2(R)): the bit growth of an order-M CIC decimating by R.
// Beware: Lattice LSE evaluates $clog2(x) given x>=2**32 as 0, so there R^M must stay below.
`define CIC_DECIMATOR_MULTI_GROWTH(R, M) $clog2((1000'd0 + (R)) ** (M))

// The default (lossless) WOUT of an instance.
`define CIC_DECIMATOR_MULTI_WOUT(WIN, RMAX, N) ((WIN) + `CIC_DECIMATOR_MULTI_GROWTH(RMAX, N))

// Order m (1..N) of channel k (0..KCOMB-1) in the out_data bundle, given bit width WOUT and order N of the instance.
// The part-select is unsigned; wrap it in $signed() where the sign matters.
`define CIC_DECIMATOR_MULTI_DATA(out_data, WOUT, N, k, m) out_data[(WOUT)*((N)*(k)+(m)-1) +: (WOUT)]

// The valid strobe of channel k; all orders of the channel (1..N) update with it, simultaneously.
`define CIC_DECIMATOR_MULTI_VALID(out_valid, k) out_valid[(k)]
