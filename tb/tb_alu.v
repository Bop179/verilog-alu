// tb_alu.v -- self-checking testbench for the parameterised ALU.
//
// Run modes (set with iverilog -P overrides):
//   EXHAUSTIVE=1  every (op, a, b) triple.  Only sane for small WIDTH.
//   EXHAUSTIVE=0  corner cross-product + RANDOM_N pseudo-random vectors.
//
// The reference model below is deliberately NOT written the way the DUT is
// written.  The DUT decides overflow with the classic sign-bit rule and gets
// carry out of a shared adder; the model computes the true mathematical result
// in 64-bit space and asks whether it still fits in WIDTH bits.  A golden model
// that mirrors the design under test agrees with its bugs and proves nothing.

`timescale 1ns / 1ps
`default_nettype none

module tb_alu;

  parameter WIDTH      = 4;
  parameter EXHAUSTIVE = 1;
  parameter RANDOM_N   = 10000;
  parameter SEED       = 32'h5EED0001;
  parameter MAX_SHOW   = 5;   // failures printed per op before going quiet

  localparam OP_ADD = 3'd0;
  localparam OP_SUB = 3'd1;
  localparam OP_AND = 3'd2;
  localparam OP_OR  = 3'd3;
  localparam OP_XOR = 3'd4;
  localparam OP_NOT = 3'd5;
  localparam OP_SLL = 3'd6;
  localparam OP_SRL = 3'd7;

  localparam NOPS    = 8;
  localparam SHAMT_W = (WIDTH > 1) ? $clog2(WIDTH) : 1;

  // ---------------------------------------------------------------- DUT ----
  reg  [WIDTH-1:0] a, b;
  reg  [2:0]       op;
  wire [WIDTH-1:0] y;
  wire             zero, negative, carry, overflow;

  alu #(.WIDTH(WIDTH)) dut (
    .a(a), .b(b), .op(op),
    .y(y), .zero(zero), .negative(negative),
    .carry(carry), .overflow(overflow)
  );

  // ----------------------------------------------------------- bookkeeping --
  integer checks_per_op [0:NOPS-1];
  integer fails_per_op  [0:NOPS-1];
  integer shown_per_op  [0:NOPS-1];
  integer total_checks, total_fails;

  integer i, opi, ai, bi, ci, cj;
  integer k;   // used ONLY inside ref_model, so it cannot clobber a stimulus loop
  integer seed;

  reg [WIDTH-1:0] exp_y;
  reg             exp_z, exp_n, exp_c, exp_v;

  // Widened views of the operands and the true, unclipped results.
  reg [63:0]        za, zb;      // zero-extended
  reg signed [63:0] sa, sb;      // sign-extended
  reg signed [63:0] s_res;
  reg        [63:0] u_res;
  reg signed [63:0] SMAX, SMIN;
  reg        [63:0] UMAX;
  integer           shamt;

  localparam NCORN = 9;
  reg [WIDTH-1:0] corner [0:NCORN-1];

  function [8*4-1:0] opname;
    input [2:0] o;
    begin
      case (o)
        OP_ADD:  opname = "ADD";
        OP_SUB:  opname = "SUB";
        OP_AND:  opname = "AND";
        OP_OR :  opname = "OR";
        OP_XOR:  opname = "XOR";
        OP_NOT:  opname = "NOT";
        OP_SLL:  opname = "SLL";
        OP_SRL:  opname = "SRL";
        default: opname = "???";
      endcase
    end
  endfunction

  // ------------------------------------------------------ reference model --
  task ref_model;
    begin
      za = 64'd0;  za[WIDTH-1:0] = a;
      zb = 64'd0;  zb[WIDTH-1:0] = b;
      sa = {64{a[WIDTH-1]}};  sa[WIDTH-1:0] = a;
      sb = {64{b[WIDTH-1]}};  sb[WIDTH-1:0] = b;

      shamt = b[SHAMT_W-1:0];   // hardware only wires the low log2(WIDTH) bits

      exp_y = {WIDTH{1'b0}};
      exp_c = 1'b0;
      exp_v = 1'b0;

      case (op)
        OP_ADD: begin
          u_res = za + zb;
          s_res = sa + sb;
          exp_y = u_res[WIDTH-1:0];
          exp_c = (u_res > UMAX);                   // unsigned result did not fit
          exp_v = (s_res > SMAX) || (s_res < SMIN); // signed result did not fit
        end
        OP_SUB: begin
          u_res = za - zb;
          s_res = sa - sb;
          exp_y = u_res[WIDTH-1:0];
          exp_c = (za >= zb);                       // carry == NOT borrow (ARM style)
          exp_v = (s_res > SMAX) || (s_res < SMIN);
        end
        OP_AND: exp_y = a & b;
        OP_OR : exp_y = a | b;
        OP_XOR: exp_y = a ^ b;
        OP_NOT: exp_y = ~a;
        // Shifts are rebuilt one bit at a time rather than with << and >>, so a
        // broken shift-amount mask in the DUT cannot hide behind the same operator.
        OP_SLL: for (k = 0; k < WIDTH; k = k + 1)
                  if (k >= shamt) exp_y[k] = a[k - shamt];
        OP_SRL: for (k = 0; k < WIDTH; k = k + 1)
                  if (k + shamt < WIDTH) exp_y[k] = a[k + shamt];
        default: ;   // unreachable: op is 3 bits and all 8 are listed above
      endcase

      exp_z = (exp_y == {WIDTH{1'b0}});
      exp_n = exp_y[WIDTH-1];
    end
  endtask

  // ----------------------------------------------------------- the checker --
  task check;
    begin
      ref_model;
      #1;                       // let the combinational DUT settle
      total_checks           = total_checks + 1;
      checks_per_op[op]      = checks_per_op[op] + 1;
      if (y !== exp_y || zero  !== exp_z || negative !== exp_n ||
          carry !== exp_c || overflow !== exp_v) begin
        total_fails         = total_fails + 1;
        fails_per_op[op]    = fails_per_op[op] + 1;
        if (shown_per_op[op] < MAX_SHOW) begin
          shown_per_op[op] = shown_per_op[op] + 1;
          $display("  FAIL %0s a=%h b=%h | got y=%h z=%b c=%b v=%b n=%b | want y=%h z=%b c=%b v=%b n=%b",
                   opname(op), a, b,
                   y,     zero,  carry, overflow, negative,
                   exp_y, exp_z, exp_c, exp_v,    exp_n);
        end
      end
    end
  endtask

  task drive;
    input [WIDTH-1:0] va, vb;
    input [2:0]       vo;
    begin
      a = va;  b = vb;  op = vo;
      check;
    end
  endtask

  // ----------------------------------------------------------------- main --
  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("build/alu.vcd");
      $dumpvars(0, tb_alu);
    end

    seed         = SEED;
    total_checks = 0;
    total_fails  = 0;
    for (i = 0; i < NOPS; i = i + 1) begin
      checks_per_op[i] = 0;
      fails_per_op[i]  = 0;
      shown_per_op[i]  = 0;
    end

    UMAX = 64'd0;  UMAX[WIDTH-1:0] = {WIDTH{1'b1}};
    SMAX = (64'sd1 <<< (WIDTH - 1)) - 64'sd1;
    SMIN = -(64'sd1 <<< (WIDTH - 1));

    corner[0] = 64'd0;
    corner[1] = 64'd1;
    corner[2] = ~64'd0;                        // all ones  (unsigned max, signed -1)
    corner[3] = (64'd1 << (WIDTH - 1));        // signed min / MSB alone
    corner[4] = (64'd1 << (WIDTH - 1)) - 64'd1;// signed max
    corner[5] = WIDTH - 1;                     // largest shift the mask allows
    corner[6] = WIDTH;                         // shift that wraps back to 0
    corner[7] = 64'h5555555555555555;
    corner[8] = 64'hAAAAAAAAAAAAAAAA;

    $display("--- tb_alu  WIDTH=%0d  SHAMT_W=%0d  mode=%0s ---",
             WIDTH, SHAMT_W, EXHAUSTIVE ? "exhaustive" : "corners+random");

    if (EXHAUSTIVE) begin
      for (opi = 0; opi < NOPS; opi = opi + 1)
        for (ai = 0; ai < (1 << WIDTH); ai = ai + 1)
          for (bi = 0; bi < (1 << WIDTH); bi = bi + 1)
            drive(ai[WIDTH-1:0], bi[WIDTH-1:0], opi[2:0]);
    end else begin
      // every corner against every corner
      for (opi = 0; opi < NOPS; opi = opi + 1)
        for (ci = 0; ci < NCORN; ci = ci + 1)
          for (cj = 0; cj < NCORN; cj = cj + 1)
            drive(corner[ci], corner[cj], opi[2:0]);

      // corners against noise, in both operand positions
      for (opi = 0; opi < NOPS; opi = opi + 1)
        for (ci = 0; ci < NCORN; ci = ci + 1)
          for (i = 0; i < 16; i = i + 1) begin
            drive(corner[ci], $random(seed), opi[2:0]);
            drive($random(seed), corner[ci], opi[2:0]);
          end

      // plain random
      for (i = 0; i < RANDOM_N; i = i + 1)
        drive($random(seed), $random(seed), $random(seed));
    end

    $display("    op   checks   fails");
    for (i = 0; i < NOPS; i = i + 1)
      $display("   %0s %8d %7d", opname(i[2:0]), checks_per_op[i], fails_per_op[i]);

    if (total_fails == 0) begin
      $display("=== WIDTH=%0d: ALL %0d CHECKS PASSED ===", WIDTH, total_checks);
      $finish;
    end else begin
      $display("=== WIDTH=%0d: %0d of %0d CHECKS FAILED ===", WIDTH, total_fails, total_checks);
      $fatal(1);
    end
  end

endmodule

`default_nettype wire
