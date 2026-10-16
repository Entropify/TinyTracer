`default_nettype wire
/* verilator lint_off IMPORTSTAR */
import tinytracer_pkg::*;
/* verilator lint_on IMPORTSTAR */

// Intersection Unit: finds the closest thing that one ray segment hits.
module intersection_unit #(
    parameter ADDR_WIDTH = 9,
    parameter WLEN       = 16,
    parameter DATA_WIDTH = 16
) (
    input  logic                   clk,
    input  logic                   rst_n,       // global reset, active low

    // RTU FSM <-> Intersection Unit
    input  logic                   start,       // 1-cycle pulse: search one segment
    output logic                   done,        // 1-cycle pulse: the hit outputs are valid
    output logic                   hit,         // 1 = object or ground hit, 0 = sky
    output logic                   hit_ground,  // 1 = the hit is the ground (only with hit = 1)
    output logic [WLEN-1:0]        hit_t,       // distance to the hit, POS (Q9.7)
    output logic [ADDR_WIDTH-1:0]  hit_addr,    // SRAM address of the hit object's w0
    output logic                   hit_flip,    // sphere: ray started inside; triangle: back side

    // Ray and scene, from RTU registers (must not change from start to done)
    input  logic [47:0]            ray_origin,  // O, POS (Q9.7): z [47:32], y [31:16], x [15:0]
    input  logic [47:0]            ray_dir,     // D, DIR (Q2.14), length 1: z [47:32], y [31:16], x [15:0]
    input  logic [4:0]             bv_count,    // number of BVs, 0 to 16 (header w15[7:3])

    // SRAM reads (the RTU passes them on to the SRAM Controller)
    output logic [ADDR_WIDTH-1:0]  sram_addr,   // register: address of the word to read
    output logic                   sram_rd,     // 1-cycle pulse: read the word at sram_addr
    input  logic [DATA_WIDTH-1:0]  sram_data,   // SRAM word, shared by all RTU sub-blocks
    input  logic                   sram_valid,  // 1 = sram_data holds the word asked for

    // Macro-ops (the RTU passes them on to the Decode Unit; the macro_if client signals)
    output logic                   req_valid,   // 1 = req_op holds a macro-op
    output logic [101:0]           req_op,      // fmt [101], u [100:53], v [52:5], opcode [4:0]
    input  logic                   req_ready,   // 1 = the Decode Unit takes req_op in this cycle
    input  logic                   resp_valid,  // 1 = resp_result holds the result
    input  logic [3*WLEN-1:0]      resp_result, // z [47:32], y [31:16], x [15:0]; a compare gives 1 or 0 in x
    output logic                   resp_ready   // 1 = the IU takes resp_result in this cycle
);

    // Assumption:
    // input ray_origin, ray_dir, bv_count stay same in between start 1-cycle pulse
    // input resp_valid, resp_result stay same until resp_ready and req_valid(?)

    // FSM States
    typedef enum logic [1:0] {
        S_IDLE       = 2'd0,
        S_RTU_LOAD   = 2'd1,
        S_PROCESS_BV = 2'd2,
        S_CHECKOUT   = 2'd3
    } state_t;

    typedef enum logic [1:0] {
        S_SRAM_IDLE = 2'd0,
        S_SRAM_SEND = 2'd1,
        S_SRAM_WAIT = 2'd2,
        S_SRAM_NEXT = 2'd3
    } sram_state_t;

    typedef enum logic [1:0] {
        S_DEC_IDLE = 2'd0,
        S_DEC_SEND = 2'd1,
        S_DEC_WAIT = 2'd2,
        S_DEC_DONE = 2'd3
    } dec_state_t;

    typedef enum logic [3:0] {
        CALC_A,
        CALC_R2,
        CALC_OC,
        CALC_OC_DOT,
        CALC_C,
        CALC_DIR_OC_DOT,
        CALC_B,
        CALC_DISCRIMINANT,
        CALC_T
    } calc_stage_t;

    state_t state_q, state_d;
    sram_state_t sram_state_q, sram_state_d;
    dec_state_t dec_state_q, dec_state_d;
    calc_stage_t calc_stage_q;

    // Next-State Combinational Logic
    // Main State Machine
    always_comb begin
        state_d = state_q;
        case (state_q)
            S_IDLE: begin
                // Boot system after start signal
                if (start) state_d = S_RTU_LOAD;
            end
            S_RTU_LOAD: begin
                // Routing check for bv_count
                if (bv_count == 0) state_d = S_CHECKOUT;
                else state_d = S_PROCESS_BV;
            end
            S_PROCESS_BV: begin
                // Checkout after computed intersection result
                if (dec_state_q == S_DEC_DONE) state_d = S_CHECKOUT;
            end
            S_CHECKOUT: begin
                if (dec_state_q == S_DEC_IDLE) begin
                    // Skip and reset to idle if bv_count is invalid
                    if (bv_count == 0) state_d = S_IDLE;
                    // Reset to idle if after finished all SRAM BV
                    else if (bv_index == bv_count - 5'd1) state_d = S_IDLE;
                    // Iterate next BV object
                    else state_d = S_PROCESS_BV;
                end
            end

            default: state_d = S_IDLE;
        endcase
    end

    // SRAM State Machine
    always_comb begin
        sram_state_d = sram_state_q;
        case (sram_state_q)
            S_SRAM_IDLE: begin
                // Load 1st Address and send only if bv_count is valid
                if (state_q == S_RTU_LOAD) sram_state_d = S_SRAM_SEND;
            end
            S_SRAM_SEND: begin
                sram_state_d = S_SRAM_WAIT;
            end
            S_SRAM_WAIT: begin
                // Radius: Decoder available
                if (!bv_r_ready)
                    if (req_ready) sram_state_d = S_SRAM_NEXT;
                    else sram_state_d = S_SRAM_WAIT;
                // Origin: Latched bv_r^2 and Decoder available
                else if (bv_origin_ready)
                    if (bv_r2_ready && req_ready) sram_state_d = S_SRAM_NEXT;
                    else sram_state_d = S_SRAM_WAIT;
                else sram_state_d = S_SRAM_NEXT;
            end
            S_SRAM_NEXT: begin
                // Finished all SRAM BV
                if (sram_read) sram_state_d = S_SRAM_IDLE;
                // Iterate next BV object
                else sram_state_d = S_SRAM_SEND;
            end

            default: sram_state_d = S_SRAM_IDLE;
        endcase
    end
    
    // Decoder State Machine
    always_comb begin
        dec_state_d = dec_state_q;

        case (dec_state_q)
            S_DEC_IDLE: begin
                // Construct the next request when its operands are ready.
                case (calc_stage_q)
                    CALC_A:
                        if (state_q == S_PROCESS_BV && !a_ready) dec_state_d = S_DEC_SEND;
                    CALC_R2:
                        if (a_ready && bv_r_ready && !bv_r2_ready) dec_state_d = S_DEC_SEND;
                    CALC_OC:
                        if (bv_origin_ready && bv_r2_ready && !oc_ready) dec_state_d = S_DEC_SEND;
                    CALC_OC_DOT:
                        if (oc_ready && !oc_dot_ready) dec_state_d = S_DEC_SEND;
                    CALC_C:
                        if (oc_dot_ready && bv_r2_ready && !c_ready) dec_state_d = S_DEC_SEND;
                    CALC_DIR_OC_DOT:
                        if (oc_ready && !dir_oc_dot_ready) dec_state_d = S_DEC_SEND;
                    CALC_B:
                        if (dir_oc_dot_ready && !b_ready) dec_state_d = S_DEC_SEND;
                    CALC_DISCRIMINANT:
                        if (a_ready && b_ready && c_ready && !discriminant_ready) dec_state_d = S_DEC_SEND;
                    CALC_T:
                        if (discriminant_ready && !t_ready) dec_state_d = S_DEC_SEND;

                    default: ;
                endcase
            end
            S_DEC_SEND: begin
                // Send after constructed Decoder req_op and Decoder available
                if (req_valid && req_ready) dec_state_d = S_DEC_WAIT;
            end
            S_DEC_WAIT: begin
                // Response queue: Latched response and Decoder available
                if (resp_valid && req_ready) begin
                    // Last Decoder request
                    if (calc_stage_q == CALC_T) dec_state_d = S_DEC_DONE;
                    // Iterate next Decoder request
                    else dec_state_d = S_DEC_IDLE;
                end
            end
            S_DEC_DONE: begin
                // Reset after S_CHECKOUT in main state machine
                if (state_q == S_CHECKOUT) dec_state_d = S_DEC_IDLE;
            end

            default: dec_state_d = S_DEC_IDLE;
        endcase
    end

    // Internal tracking
    // SRAM read progress
    logic [4:0]  bv_index;
    logic [2:0]  sram_w_index; // BV Address: w0-w4
    logic        sram_read;
    // SRAM data
    logic [15:0] bv_r, bv_x, bv_y, bv_z;
    logic        bv_r_ready, bv_origin_ready;
    // Decoder status
    logic a_ready;
    logic bv_r2_ready, oc_ready, oc_dot_ready, c_ready;
    logic dir_oc_dot_ready, b_ready;
    logic discriminant_ready, t_ready;

    // FSM Sequential Iteration
    // Main State Machine
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q    <= S_IDLE;
            done       <= 1'b0;
            hit        <= 1'b0;
            hit_ground <= 1'b0;
            hit_t      <= 16'd0;
            hit_addr   <= 16'd0;
            hit_flip   <= 1'b0;
        end else begin
            state_q <= state_d;
            // WiP
            case (state_q)
                S_IDLE: begin
                end

                S_RTU_LOAD: begin
                end

                S_PROCESS_BV: begin
                end

                S_CHECKOUT: begin
                end

                default: ;
            endcase
        end
    end

    // SRAM State Machine
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_state_q  <= S_SRAM_IDLE;
            bv_index      <= 5'd0;
            sram_addr     <= 9'd17; // BV Address = 17 + 5 * i + word
            sram_w_index  <= 3'd0;  // BV word: w0-w4
            sram_rd       <= 1'b0;
            sram_read     <= 1'b0;
            bv_r          <= 16'd0;
            bv_x          <= 16'd0;
            bv_y          <= 16'd0;
            bv_z          <= 16'd0;
            bv_r_ready      <= 1'b0;
            bv_origin_ready <= 1'b0;

        end else begin
            sram_state_q <= sram_state_d;

            // 1-cycle pulse
            sram_rd <= 1'b0;

            case (sram_state_q)
                // Start at Address 17
                S_SRAM_IDLE: begin
                    bv_index      <= 5'd0;
                    sram_addr     <= 9'd17; // 1st BV Address start at 17
                    sram_w_index  <= 3'd0; // BV word reset to w0
                    sram_rd       <= 1'b0;
                    sram_read     <= 1'b0;
                end

                // Read SRAM
                S_SRAM_SEND: begin
                    sram_rd <= 1'b1; // Override global sram_rd <= 1'b0 for 1-cycle
                end

                // Process SRAM data
                S_SRAM_WAIT: begin
                    if (sram_valid) begin
                        case (sram_w_index)
                            3'd0: hit_addr  <= sram_data[15:7];
                            3'd1: begin
                                bv_r        <= sram_data;
                                bv_r_ready  <= 1'b1;
                            end
                            3'd2: bv_x      <= sram_data;
                            3'd3: bv_y      <= sram_data;
                            3'd4: begin
                                bv_z            <= sram_data;
                                bv_origin_ready <= 1'b1;
                            end
                            default: ;
                        endcase
                    end
                end

                S_SRAM_NEXT: begin
                    // Iterative SRAM word Read (w0 -> w4)
                    if (sram_w_index != 3'd4) begin
                        sram_addr    <= sram_addr + 9'd1;    // Increment to next word address (BV Address = 17 + 5 * i + word (16 bit))
                        sram_w_index <= sram_w_index + 3'd1; // Increment to next word (w0 -> w4)
                    end else begin
                        // Iterative SRAM object Read (i increment)

                        // Last BV word
                        if (bv_index == bv_count - 5'd1) begin
                            sram_read <= 1'b1;
                        
                        // move to next object
                        end else begin
                            bv_index     <= bv_index + 5'd1;  // i
                            sram_addr    <= sram_addr + 9'd1; // BV Address = 17 + 5 * i + word (16 bit)
                            sram_w_index <= 3'd0;             // BV Address reset to w0
                            // Reset for next object
                            bv_r_ready      <= 1'b0;
                            bv_origin_ready <= 1'b0;
                        end
                    end
                end

                default: ;
            endcase
        end
    end

    // Decoder State Machine
    // Decoder Math
    // hit == (b*b - 4*a*c !< 0)
    // oc = bv_origin - ray_origin
    // a = dot(ray_dir, ray_dir)
    // b = -2.0 * dot(ray_dir, oc)
    // c = dot(oc, oc) - bv_r * bv_r
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            calc_stage_q <= CALC_A;
            req_valid    <= 1'b0;
            req_op       <= 102'd0;
            resp_ready   <= 1'b0;

            a_ready            <= 1'b0;
            bv_r2_ready        <= 1'b0;
            oc_ready           <= 1'b0;
            oc_dot_ready       <= 1'b0;
            c_ready            <= 1'b0;
            dir_oc_dot_ready   <= 1'b0;
            b_ready            <= 1'b0;
            discriminant_ready <= 1'b0;
            t_ready            <= 1'b0;
        end else begin
            // Reset take response from Decoder
            resp_ready <= 1'b0;

            case (dec_state_q)
                S_DEC_IDLE: begin
                    req_valid <= 1'b0;
                end

                S_DEC_SEND: begin
                    case (calc_stage_q)
                        // 1. a = dot(ray_dir, ray_dir)
                        CALC_A: begin
                            // S_RTU_LOAD -> S_BV_PROCESS
                            if (state_q == S_PROCESS_BV && state_d == S_PROCESS_BV && calc_stage_q == CALC_A && !a_ready) begin
                                req_op[4:0]   <= 5'b01111;           // Vector dot product u · v
                                req_op[100:5] <= {ray_dir, ray_dir}; // u, v Ray direction
                                req_op[101]   <= 1'b0;               // Return position
                                req_valid     <= 1'b1;
                            end
                        end
                        // 2. r^2 (c = dot(oc, oc) - bv_r * bv_r)
                        CALC_R2: begin
                            req_op[4:0]                   <= 5'b00110; // Scalar multiplication ux × vx
                            req_op[20:5], req_op[68:53]   <= bv_r;     // Scalar x
                            req_op[52:21], req_op[100:69] <= 32'b0;    // Disable y, z
                            req_op[101]                   <= 1'b0;     // Return position
                            req_valid                     <= 1'b1;
                        end
                        // 3. oc = bv_origin - ray_origin (c = dot(oc, oc) - bv_r * bv_r)
                        CALC_OC: begin
                            req_op[4:0]    <= 5'b01101;           // Vector subtraction u - v
                            req_op[52:5]   <= ray_origin;         // v ray_origin
                            req_op[100:69] <= {bv_z, bv_y, bv_x}; // u bv_origin
                            req_op[101]    <= 1'b0;               // Return position
                            req_valid      <= 1'b1;
                        end
                        // WiP
                        CALC_OC_DOT: begin
                        end

                        CALC_C: begin
                        end

                        CALC_DIR_OC_DOT: begin
                        end

                        CALC_B: begin
                        end

                        CALC_DISCRIMINANT: begin
                        end

                        CALC_T: begin
                        end

                        default: ;
                    endcase
                    // Reset send Decoder request only on sent/Decoder-available handshake.
                    if (req_valid && req_ready) begin
                        req_valid <= 1'b0;
                    end
                end

                S_DEC_WAIT: begin
                    // Reset send Decoder request
                    req_valid <= 1'b0;
                    // Accept Decoder response
                    if (resp_valid) begin
                        resp_ready <= 1'b1;

                        // Latch resp_result
                        // register for calc_stage_q.
                        // WiP
                        case (calc_stage_q)
                            CALC_A: begin
                                a_ready      <= 1'b1;
                                calc_stage_q <= CALC_R2;
                            end

                            CALC_R2: begin
                                bv_r2_ready  <= 1'b1;
                                calc_stage_q <= CALC_OC;
                            end

                            CALC_OC: begin
                                oc_ready     <= 1'b1;
                                calc_stage_q <= CALC_OC_DOT;
                            end

                            CALC_OC_DOT: begin
                                oc_dot_ready <= 1'b1;
                                calc_stage_q <= CALC_C;
                            end

                            CALC_C: begin
                                c_ready      <= 1'b1;
                                calc_stage_q <= CALC_DIR_OC_DOT;
                            end

                            CALC_DIR_OC_DOT: begin
                                dir_oc_dot_ready <= 1'b1;
                                calc_stage_q <= CALC_B;
                            end

                            CALC_B: begin
                                b_ready      <= 1'b1;
                                calc_stage_q <= CALC_DISCRIMINANT;
                            end

                            CALC_DISCRIMINANT: begin
                                discriminant_ready <= 1'b1;
                                calc_stage_q <= CALC_T;
                            end

                            CALC_T: begin
                                t_ready <= 1'b1;
                            end

                            default: ;
                        endcase
                    end
                end

                S_DEC_DONE: begin
                    // Reset send Decoder request
                    req_valid <= 1'b0;
                end

                default: ;
            endcase
        end
    end

endmodule