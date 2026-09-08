// alu.v -- a width-parameterised arithmetic logic unit.
//
// Purely combinational: there is no clock and no state.  Change A, B or OP and
// the outputs settle to the new answer after one gate-delay chain.
//
//   WIDTH   operand width in bits.  Any value >= 1; tested 1..6 exhaustively
//           and 8/16/32 randomly.
//
//   op[2:0]                       carry              overflow
//   ---------------------------   ----------------   ----------------------
//   000 ADD  y = a + b            carry out          signed overflow
//   001 SUB  y = a - b            NOT borrow         signed overflow
//   010 AND  y = a & b            0                  0
//   011 OR   y = a | b            0                  0
//   100 XOR  y = a ^ b            0                  0
//   101 NOT  y = ~a   (b unused)  0                  0
//   110 SLL  y = a << shamt       0                  0
//   111 SRL  y = a >> shamt       0                  0
//
//   zero      y == 0          (all ops)
//   negative  y[WIDTH-1]      (all ops -- the sign bit, if you read y as signed)
//
// shamt is the low $clog2(WIDTH) bits of b, not all of b.  See README.

`timescale 1ns / 1ps
`default_nettype none

module alu #(
    parameter WIDTH = 8
) (
    input  wire [WIDTH-1:0] a,
    input  wire [WIDTH-1:0] b,
    input  wire [2:0]       op,
    output reg  [WIDTH-1:0] y,
    output wire             zero,
    output wire             negative,
    output reg              carry,
    output reg              overflow
);

  localparam OP_ADD = 3'd0;
  localparam OP_SUB = 3'd1;
  localparam OP_AND = 3'd2;
  localparam OP_OR  = 3'd3;
  localparam OP_XOR = 3'd4;
  localparam OP_NOT = 3'd5;
  localparam OP_SLL = 3'd6;
  localparam OP_SRL = 3'd7;

  // Real hardware wires only the low log2(WIDTH) bits of B into the barrel
  // shifter, so a shift amount of WIDTH wraps around to 0.  Matches RV32I/x86.
  localparam SHAMT_W = (WIDTH > 1) ? $clog2(WIDTH) : 1;
  wire [SHAMT_W-1:0] shamt = b[SHAMT_W-1:0];

  // One adder serves both ADD and SUB, because A - B == A + ~B + 1.
  // Everything is done one bit wider so the carry out falls into sum[WIDTH].
  wire             subtract = (op == OP_SUB);
  wire [WIDTH-1:0] addend   = subtract ? ~b : b;
  wire [WIDTH:0]   sum      = {1'b0, a} + {1'b0, addend} + subtract;

  // Signed overflow: the operands agreed on a sign and the result disagreed.
  // Testing ADDEND rather than B makes this correct for SUB too, since
  // (a[msb] == ~b[msb]) is exactly the condition (a[msb] != b[msb]).
  wire sum_v = (a[WIDTH-1] == addend[WIDTH-1]) && (sum[WIDTH-1] != a[WIDTH-1]);

  always @(*) begin
    y        = {WIDTH{1'b0}};
    carry    = 1'b0;
    overflow = 1'b0;
    case (op)
      OP_ADD, OP_SUB: begin
        y        = sum[WIDTH-1:0];
        carry    = sum[WIDTH];   // for SUB this is the NOT-borrow flag
        overflow = sum_v;
      end
      OP_AND: y = a & b;
      OP_OR : y = a | b;
      OP_XOR: y = a ^ b;
      OP_NOT: y = ~a;
      OP_SLL: y = a << shamt;
      OP_SRL: y = a >> shamt;
      default: ;
    endcase
  end

  assign zero     = (y == {WIDTH{1'b0}});
  assign negative = y[WIDTH-1];

endmodule

`default_nettype wire
