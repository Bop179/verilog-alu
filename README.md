# verilog-alu

A width-parameterised arithmetic logic unit in Verilog, with a self-checking
testbench that proves it correct by brute force at small widths.

One parameter, `WIDTH`, sets the operand size. The same source elaborates to a
1-bit ALU or a 32-bit one; nothing in the design hard-codes a width.

```verilog
alu #(.WIDTH(32)) u_alu (
    .a(a), .b(b), .op(op),
    .y(y), .zero(z), .negative(n), .carry(c), .overflow(v)
);
```

## Quick start

```bash
make test     # every width: exhaustive at 1-5, random at 8/16/32  (~1.5 s)
make synth    # push through Yosys, print gate count vs WIDTH
make wave     # run at WIDTH=8 and open the VCD in Surfer
make lint     # Verible style check
```

Needs [Icarus Verilog](https://steveicarus.github.io/iverilog/) for `test`,
[Yosys](https://yosyshq.net/yosys/) for `synth`, and
[Surfer](https://surfer-project.org/) for `wave`.

## Operations

`op` is 3 bits, so there are eight of them.

| `op` | Name | Result | `carry` | `overflow` |
|:---:|:---|:---|:---|:---|
| `000` | ADD | `y = a + b` | carry out of the MSB | signed overflow |
| `001` | SUB | `y = a - b` | **not** borrow | signed overflow |
| `010` | AND | `y = a & b` | `0` | `0` |
| `011` | OR  | `y = a \| b` | `0` | `0` |
| `100` | XOR | `y = a ^ b` | `0` | `0` |
| `101` | NOT | `y = ~a` (`b` unused) | `0` | `0` |
| `110` | SLL | `y = a << shamt` | `0` | `0` |
| `111` | SRL | `y = a >> shamt` | `0` | `0` |

`zero` is `y == 0` and `negative` is `y[WIDTH-1]`. Both are meaningful for every
operation — they are just properties of the result.

The ALU is purely combinational. There is no clock and no state: change the
inputs and the outputs settle.

## Three things worth understanding

### 1. `carry` on SUB means "no borrow"

There is no separate subtractor. `SUB` reuses the adder, because

```
a - b  ==  a + (~b) + 1
```

so the design feeds `~b` and a carry-in of 1 into the same adder `ADD` uses:

```verilog
wire             subtract = (op == OP_SUB);
wire [WIDTH-1:0] addend   = subtract ? ~b : b;
wire [WIDTH:0]   sum      = {1'b0, a} + {1'b0, addend} + subtract;
```

That falls out of two's complement, and it is why one adder can do both jobs.

The consequence is the flag convention. The carry out of `a + ~b + 1` is 1
exactly when `a >= b`, so on a subtraction `carry == 1` means *no borrow
happened*. ARM and RISC-V read it this way; x86's `CF` is the opposite. Neither
is more correct, but mixing them up is a classic source of wrong branches, so
this ALU picks one and states it:

| `a` | `b` | `a - b` | `carry` | meaning |
|:---:|:---:|:---:|:---:|:---|
| 5 | 3 | 2 | 1 | no borrow |
| 3 | 5 | −2 | 0 | borrowed |
| 4 | 4 | 0 | 1 | no borrow |

### 2. `overflow` is about signed range, `carry` is about unsigned range

They answer different questions, and only one of them is usually the one you
want:

- `carry` — did the result fall outside `0 .. 2^WIDTH − 1`?
- `overflow` — did the result fall outside `−2^(WIDTH−1) .. 2^(WIDTH−1) − 1`?

At `WIDTH=4`, `0111 + 0001` is `1000`. As unsigned that is 7 + 1 = 8, which fits
in 4 bits, so `carry = 0`. As signed it is 7 + 1 = −8, which does not fit, so
`overflow = 1`. The hardware does not know whether you meant the bits to be
signed; it computes both flags and lets you read the one that matches your
interpretation.

The detection rule is that overflow happened when **the operands agreed on a
sign and the result disagreed**:

```verilog
wire sum_v = (a[WIDTH-1] == addend[WIDTH-1]) && (sum[WIDTH-1] != a[WIDTH-1]);
```

Note it tests `addend`, not `b`. Since `addend` is `~b` on a subtraction, that
one substitution makes the same line correct for SUB as well.

### 3. Only the low bits of `b` reach the shifter

The shift amount is not all of `b`:

```verilog
localparam SHAMT_W = (WIDTH > 1) ? $clog2(WIDTH) : 1;
wire [SHAMT_W-1:0] shamt = b[SHAMT_W-1:0];
```

At `WIDTH=8` only `b[2:0]` is wired to the barrel shifter, so **`a << 8` gives
back `a`, not `0`** — the shift amount wraps. This is deliberate and it is what
real hardware does: RV32I and x86 both mask the shift amount the same way,
because building a shifter that accepts amounts it can only answer `0` to is
paying gates for nothing.

Non-power-of-two widths are where this gets interesting: at `WIDTH=3`,
`$clog2(3)` is 2, so `shamt` can reach 3 — one more than any useful shift. The
testbench checks widths 1, 2, 3, 5 and 6 exhaustively for exactly this reason.

## Verification

`make test` runs 49,768 checks in about 1.5 seconds.

| WIDTH | Mode | Checks |
|---:|:---|---:|
| 1, 2, 3, 4, 5 | exhaustive — every `(op, a, b)` triple | 10,912 |
| 8, 16, 32 | corner cross-product + 10,000 random vectors | 38,856 |

Corner values are `0`, `1`, all-ones, signed min, signed max, `WIDTH-1`,
`WIDTH`, `0x5555…` and `0xAAAA…`, crossed against each other and against noise
in both operand positions.

**The reference model is written differently from the design on purpose.** The
ALU decides overflow with the sign-bit rule above; the model computes the true
mathematical result in 64-bit space and asks whether it still fits in `WIDTH`
bits. The ALU shifts with `<<`; the model rebuilds the result one bit at a time.
A golden model that mirrors the design agrees with its bugs and proves nothing.

To confirm the testbench can actually fail, eight deliberate bugs were injected
into the ALU one at a time. All eight were caught:

| Injected bug | Caught |
|:---|:---:|
| overflow tests `b` instead of `~b` on SUB | yes |
| overflow sign comparison inverted | yes |
| shift-amount mask one bit too wide | yes |
| SUB drops the `+1` (computes `a + ~b`) | yes |
| carry on SUB reported as borrow (x86 convention) | yes |
| carry left set on logic and shift ops | yes |
| `negative` taken from `a` instead of the result | yes |
| SRL implemented as an arithmetic shift | yes |

A test suite that has only ever been green is not evidence that it works.

## Synthesis

`make synth` elaborates through Yosys and reports the cell count:

| WIDTH | Cells | Cells/bit |
|---:|---:|---:|
| 4 | 119 | 29.8 |
| 8 | 244 | 30.5 |
| 16 | 511 | 31.9 |
| 32 | 1087 | 34.0 |

Cost is close to linear in `WIDTH`, which is what you would expect from a ripple
adder and eight bitwise operations. The slow climb in cells per bit — 29.8 up to
34.0 — is the barrel shifter, which grows as O(*W* log *W*) rather than O(*W*):
a 32-bit shifter needs five mux stages where a 4-bit one needs two.

## Layout

```
rtl/alu.v                 the ALU (62 lines of module, plus a header comment)
tb/tb_alu.v               self-checking testbench
Makefile                  test / quick / synth / wave / lint / clean
.rules.verible_lint       lint rules, each disabled one with its reason
.github/workflows/ci.yml  runs simulation and synthesis on every push
```

## Notes on style

This is plain Verilog-2001, not SystemVerilog: `always @(*)` rather than
`always_comb`, `reg`/`wire` rather than `logic`. That is a deliberate choice for
a learning project — it matches how ALUs are written in textbooks and course
material, and it elaborates in every tool without a language-version flag.

`$clog2` is the one exception. It is Verilog-2005, and it is what makes the
shift-amount width follow `WIDTH` automatically.
