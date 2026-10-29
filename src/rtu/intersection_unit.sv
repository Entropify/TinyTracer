`default_nettype wire
/* verilator lint_off IMPORTSTAR */
import tinytracer_pkg::*;
/* verilator lint_on IMPORTSTAR */

// Debug export intermediate for FSM
package iu_types_pkg;
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
    
    // WiP not implemented
    // p = ray * t
    // outward_normal = (p - bv_origin) / bv_r
    // front_face = (dot(ray_dir, normal) < 0)
    // normal = front_face ? outward_normal : -outward_normal;
    // hit_flip =
    typedef enum logic [3:0] {
        CALC_A            = 4'd0,
        CALC_OC           = 4'd1,
        CALC_OC_DOT       = 4'd2,
        CALC_H            = 4'd3,
        CALC_R2           = 4'd4,
        CALC_C            = 4'd5,
        CALC_AC           = 4'd6,
        CALC_H2           = 4'd7,
        CALC_DISCRIMINANT = 4'd8,
        CALC_HIT          = 4'd9,
        CALC_SQRTD        = 4'd10,
        CALC_NUMERATOR    = 4'd11,
        CALC_T            = 4'd12
        // WiP for hit_flip

    } calc_stage_t;
endpackage

import iu_types_pkg::*;

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
    output logic                   resp_ready,  // 1 = the IU takes resp_result in this cycle

    // Debug
    output state_t                 state_q,
    output state_t                 state_d,
    output sram_state_t            sram_state_q,
    output sram_state_t            sram_state_d,
    output dec_state_t             dec_state_q,
    output dec_state_t             dec_state_d,
    output calc_stage_t            calc_stage_q,
    output calc_stage_t            calc_stage_d
);

    // Assumption:
    // input ray_origin, ray_dir, bv_count stay same in between start 1-cycle pulse
    // input resp_valid, resp_result stay same until resp_ready and req_valid(?)

    // FSM States
    // Disable for the debug build
    //typedef enum logic [1:0] {
    //    S_IDLE       = 2'd0,
    //    S_RTU_LOAD   = 2'd1,
    //    S_PROCESS_BV = 2'd2,
    //    S_CHECKOUT   = 2'd3
    //} state_t;

    //typedef enum logic [1:0] {
    //    S_SRAM_IDLE = 2'd0,
    //    S_SRAM_SEND = 2'd1,
    //    S_SRAM_WAIT = 2'd2,
    //    S_SRAM_NEXT = 2'd3
    //} sram_state_t;

    //typedef enum logic [1:0] {
    //    S_DEC_IDLE = 2'd0,
    //    S_DEC_SEND = 2'd1,
    //    S_DEC_WAIT = 2'd2,
    //    S_DEC_DONE = 2'd3
    //} dec_state_t;
    
    // WiP not implemented
    // p = ray * t
    // outward_normal = (p - bv_origin) / bv_r
    // front_face = (dot(ray_dir, normal) < 0)
    // normal = front_face ? outward_normal : -outward_normal;
    // hit_flip =
    //typedef enum logic [3:0] {
    //    CALC_A            = 4'd0,
    //    CALC_OC           = 4'd1,
    //    CALC_OC_DOT       = 4'd2,
    //    CALC_H            = 4'd3,
    //    CALC_R2           = 4'd4,
    //    CALC_C            = 4'd5,
    //    CALC_AC           = 4'd6,
    //    CALC_H2           = 4'd7,
    //    CALC_DISCRIMINANT = 4'd8,
    //    CALC_HIT          = 4'd9,
    //    CALC_SQRTD        = 4'd10,
    //    CALC_NUMERATOR    = 4'd11,
    //    CALC_T            = 4'd12
    // WiP for hit_flip

    //} calc_stage_t;

    //state_t state_q, state_d;
    //sram_state_t sram_state_q, sram_state_d;
    //dec_state_t dec_state_q, dec_state_d;
    //calc_stage_t calc_stage_q;

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
                // Checkout after computed all bv object intersection
                if (dec_state_q == S_DEC_DONE) begin 
                    if (bv_index == bv_count - 5'd1) state_d = S_CHECKOUT;
                end
            end
            S_CHECKOUT: begin
                if (dec_state_q == S_DEC_IDLE) begin
                    // Return to IDLE state after reporting
                    if (done) state_d = S_IDLE;
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
                // Move to WAIT state after setting sram_rd
                if (sram_rd) sram_state_d = S_SRAM_WAIT;
            end
            S_SRAM_WAIT: begin
                // Move to next SRAM BV object after all calculation (i increment)
                if (bv_origin_ready)
                    if (dec_state_q == S_DEC_DONE) sram_state_d = S_SRAM_NEXT;
                else if (sram_latch) sram_state_d = S_SRAM_NEXT;
                
                // Scrapped Version
                // Move to next word after latch and hold until all calculation to move to next SRAM BV object (i increment)
                // Radius: w0 -> w1 condition: Latched and Decoder available
                //if (!bv_r_ready)
                //    if (sram_latch && dec_state_q == S_DEC_IDLE) sram_state_d = S_SRAM_NEXT;
                // Origin: w1 -> w2 condition: Latched and Decoder available (Noted: Removed wait for bv_r2 latching as the calculation sequence optimized to local register reduction)
                //else if (calc_stage_q == CALC_OC)
                    // w2 -> w4 condition: Latched 
                //    if (sram_latch && dec_state_q == S_DEC_IDLE) sram_state_d = S_SRAM_NEXT; // Removed (&& bv_r_ready &&) as the calculation sequence optimized to local register reduction
                    // Move to next SRAM BV object (i increment) condition: after all calculation
                //    else if (bv_origin_ready)
                //        if (dec_state_q == S_DEC_DONE) sram_state_d = S_SRAM_NEXT;

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
            
                // Move to SEND state when operand of corresponding steps ready for req_op construction and Decoder available
                
                // WiP not implemented
                // p = ray * t
                // outward_normal = (p - bv_origin) / bv_r
                // front_face = (dot(ray_dir, normal) < 0)
                // normal = front_face ? outward_normal : -outward_normal;
                // hit_flip =
                case (calc_stage_q)
                    CALC_A:
                        if (state_q == S_PROCESS_BV && req_ready) dec_state_d = S_DEC_SEND;
                    CALC_OC:
                        if (bv_origin_ready && bv_r2_ready && req_ready) dec_state_d = S_DEC_SEND;
                    CALC_OC_DOT:
                        if (oc_ready && req_ready) dec_state_d = S_DEC_SEND;
                    CALC_H:
                        if (oc_ready && req_ready) dec_state_d = S_DEC_SEND;
                    CALC_R2:
                        if (a_ready && bv_r_ready && req_ready) dec_state_d = S_DEC_SEND;
                    CALC_C:
                        if (oc_dot_ready && bv_r2_ready && req_ready) dec_state_d = S_DEC_SEND;
                    CALC_AC:
                        if (a_ready && c_ready && req_ready) dec_state_d = S_DEC_SEND;
                    CALC_H2:
                        if (h_ready && req_ready) dec_state_d = S_DEC_SEND;
                    CALC_DISCRIMINANT:
                        if (h2_ready && ac_ready && req_ready) dec_state_d = S_DEC_SEND;
                    CALC_HIT:
                        if (discriminant_ready && req_ready) dec_state_d = S_DEC_SEND;
                    CALC_SQRTD:
                        if (discriminant_ready && req_ready) dec_state_d = S_DEC_SEND;
                    CALC_NUMERATOR:
                        if (sqrtd_ready && req_ready) dec_state_d = S_DEC_SEND;
                    CALC_T:
                        if (numerator_ready && a_ready && req_ready) dec_state_d = S_DEC_SEND;
                    // WiP for hit_flip

                    default: ;
                endcase
            end
            S_DEC_SEND: begin
                // Move to WAIT state for holding req_op and processing latched response after setting req_valid
                if (req_valid) dec_state_d = S_DEC_WAIT;
            end
            S_DEC_WAIT: begin
                // Response queue: Latched response and Decoder available
                if (!req_valid && req_ready) begin
                    // Last Decoder request
                    if (calc_stage_q == CALC_T) dec_state_d = S_DEC_DONE;
                    // Iterate next Decoder request
                    else dec_state_d = S_DEC_IDLE;
                end
            end
            S_DEC_DONE: begin
                // Reset after resetting calc_stage_q
                if (calc_stage_q == CALC_OC) dec_state_d = S_DEC_IDLE;
            end

            default: dec_state_d = S_DEC_IDLE;
        endcase
    end

    // Internal tracking
    // SRAM read progress
    logic [4:0]  bv_index;
    logic [2:0]  sram_w_index; // BV Address: w0-w4
    logic        sram_latch;
    logic        sram_read;
    // SRAM data
    logic        bv_r_ready, bv_origin_ready;
    // Decoder status
    logic a_ready;
    logic oc_ready, oc_dot_ready, h_ready, bv_r2_ready, c_ready, ac_ready, h2_ready;
    logic discriminant_ready, hit_ready, sqrtd_ready, numerator_ready, t_ready;
    // Local register storage for intermediates (144 bit)
    logic [15:0] slot_a; // one-time local register for each ray processes
    logic [15:0] slot_b, slot_c, slot_d, slot_e, slot_f, slot_g, slot_h, slot_i; // local register for intermediate refresh irregularly throughout the local sram bv item cycle

    // FSM Sequential Iteration
    // Main State Machine
    // WiP
    // PROCESS_BV Handle all of the decision for determining hit and its hittable address, and its shortest t and flipped
    // It should do the reporting at CHECKOUT state after looping all SRAM BV items
    // handshake with SRAM and Decoder module to retrieve the correct hit_addr and hit_t
    // hit_flip, hit_ground should be computed in CHECKOUT state
    // p = ray_origin + ray_dir * hit_t
    // outward_normal = (p - center) / radius
    // front_face = (dot(ray_dir, normal) < 0)
    // normal = front_face ? outward_normal : -outward_normal;
    // hit_flip =
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q    <= S_IDLE;
            done       <= 1'b0;
            hit_ground <= 1'b0;
        end else begin
            state_q <= state_d;
            
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
            sram_latch    <= 1'b0;
            sram_read     <= 1'b0;
            bv_r          <= 16'd0;
            bv_x          <= 16'd0;
            bv_y          <= 16'd0;
            bv_z          <= 16'd0;
            bv_r_ready      <= 1'b0;
            bv_origin_ready <= 1'b0;

        end else if (start) begin
            sram_state_q  <= S_SRAM_IDLE;
            bv_index      <= 5'd0;
            sram_addr     <= 9'd17; // BV Address = 17 + 5 * i + word
            sram_w_index  <= 3'd0;  // BV word: w0-w4
            sram_rd       <= 1'b0;
            sram_latch    <= 1'b0;
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
                    sram_rd    <= 1'b1; // Override global sram_rd <= 1'b0 for 1-cycle
                    sram_latch <= 1'b0;
                end

                // Process SRAM data
                S_SRAM_WAIT: begin
                    if (sram_valid) begin
                        // BV dimensional property for calculation latch on S_DEC_IDLE
                        case (sram_w_index)
                            3'd0: begin
                                hit_addr    <= sram_data[15:7];
                                sram_latch  <= 1'b1;
                            end
                            3'd1: begin
                                sram_latch  <= 1'b1;
                            end
                            3'd2: begin
                                sram_latch  <= 1'b1;
                            end
                            3'd3: begin
                                sram_latch  <= 1'b1;
                            end
                            3'd4: begin
                                sram_latch  <= 1'b1;
                            end
                            default: ;
                        endcase
                    end
                end

                S_SRAM_NEXT: begin
                    sram_latch <= 1'b0;
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
                            // Reset for next object after all calculation
                            if (dec_state_q == S_DEC_DONE) begin
                                bv_r_ready      <= 1'b0;
                                bv_origin_ready <= 1'b0;
                            end
                        end
                    end
                end

                default: ;
            endcase
        end
    end

    // Decoder State Machine
    // Decoder Math
    // hit == (h*h - a*c !< 0)
    // oc = bv_origin - ray_origin
    // a = dot(ray_dir, ray_dir)
    // b = -2.0 * dot(ray_dir, oc)
    // c = dot(oc, oc) - bv_r * bv_r
    // h = dot(ray_dir, oc)
    // t = (h + sqrt(h*h - a*c) ) / a
    // WiP not implemented
    // p = ray * t
    // outward_normal = (p - bv_origin) / bv_r
    // front_face = (dot(ray_dir, normal) < 0)
    // normal = front_face ? outward_normal : -outward_normal;
    // hit_flip =
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dec_state_q  <= S_DEC_IDLE;
            calc_stage_q <= CALC_A;
            req_valid    <= 1'b0;
            req_op       <= 102'd0;
            resp_ready   <= 1'b0;

            a_ready            <= 1'b0;
            oc_ready           <= 1'b0;
            oc_dot_ready       <= 1'b0;
            h_ready            <= 1'b0;
            bv_r2_ready        <= 1'b0;
            c_ready            <= 1'b0;
            ac_ready           <= 1'b0;
            h2_ready           <= 1'b0;
            discriminant_ready <= 1'b0;
            hit_ready          <= 1'b0;
            sqrtd_ready        <= 1'b0;
            numerator_ready    <= 1'b0;
            t_ready            <= 1'b0;
            
        end else if (start) begin
            // Reset a for new ray
            dec_state_q        <= S_DEC_IDLE;
            calc_stage_q       <= CALC_A;
            req_valid          <= 1'b0;
            resp_ready         <= 1'b0;

            a_ready            <= 1'b0;
            oc_ready           <= 1'b0;
            oc_dot_ready       <= 1'b0;
            h_ready            <= 1'b0;
            bv_r2_ready        <= 1'b0;
            c_ready            <= 1'b0;
            ac_ready           <= 1'b0;
            h2_ready           <= 1'b0;
            discriminant_ready <= 1'b0;
            hit_ready          <= 1'b0;
            sqrtd_ready        <= 1'b0;
            numerator_ready    <= 1'b0;
            t_ready            <= 1'b0;

        end else begin
            dec_state_q <= dec_state_d;
            
            // 1-cycle pulse
            resp_ready <= 1'b0;

            // WiP for hit_flip
            // if (state_q == S_CHECKOUT) begin
            //    calc_stage_q       <= CALC_;
            //end

            case (dec_state_q)
                S_DEC_IDLE: begin
                    req_valid <= 1'b0;
                    
                    // BV hit address latch on S_SRAM_WAIT
                    if (sram_state_q == S_SRAM_WAIT && sram_valid)
                        case (sram_w_index)
                            3'd1: begin
                                slot_b     <= sram_data; // bv_r
                                // local register
                                // slot_a: a
                                // slot_b: bv_r
                                // slot_c: null
                                // slot_d: null
                                // slot_e: null
                                // slot_f: null
                                // slot_g: null
                                // slot_h: null
                                // slot_i: null

                                bv_r_ready <= 1'b1;

                            end
                            3'd2: begin
                                slot_c          <= sram_data; // bv_z
                                // local register
                                // slot_a: a
                                // slot_b: bv_r
                                // slot_c: bv_z
                                // slot_d: null
                                // slot_e: null
                                // slot_f: null
                                // slot_g: null
                                // slot_h: null
                                // slot_i: null
                            end
                            3'd3: begin
                                slot_d          <= sram_data; // bv_y
                                // local register
                                // slot_a: a
                                // slot_b: bv_r
                                // slot_c: bv_z
                                // slot_d: bv_y
                                // slot_e: null
                                // slot_f: null
                                // slot_g: null
                                // slot_h: null
                                // slot_i: null
                            end
                            3'd4: begin
                                slot_e          <= sram_data; // bv_x
                                // slot_a: a
                                // slot_b: bv_r
                                // slot_c: bv_z
                                // slot_d: bv_y
                                // slot_e: bv_x
                                // slot_f: null
                                // slot_g: null
                                // slot_h: null
                                // slot_i: null

                                bv_origin_ready <= 1'b1;
                            end
                            default: ;
                        endcase
                    end

                end

                S_DEC_SEND: begin
                    case (calc_stage_q)
                        // 1. a = dot(ray_dir, ray_dir)
                        // one-time calculation per ray iteration (start)
                        CALC_A: begin
                            // S_RTU_LOAD -> S_BV_PROCESS
                            if (state_q == S_PROCESS_BV && state_d == S_PROCESS_BV && calc_stage_q == CALC_A && !a_ready) begin
                                req_op[4:0]   <= 5'b01111;           // Vector dot product u · v
                                req_op[100:5] <= {ray_dir, ray_dir}; // u, v Ray direction
                                req_op[101]   <= 1'b0;               // Return position
                                req_valid     <= 1'b1;
                            end
                        end
                        // 2. oc = bv_origin - ray_origin (c = dot(oc, oc) - bv_r * bv_r)
                        CALC_OC: begin
                            req_op[4:0]    <= 5'b01101;                 // Vector subtraction u - v
                            req_op[52:5]   <= ray_origin;               // v ray_origin
                            req_op[100:69] <= {slot_c, slot_d, slot_e}; // u bv_origin: {bv_z, bv_y, bv_x}
                            req_op[101]    <= 1'b0;                     // Return position
                            req_valid      <= 1'b1;
                        end
                        // WiP
                        // For constructing the req_op
                        // Check out: https://uw-asic.github.io/TinyTracer/encoding/instruction/
                        // 3. oc_dot = dot(oc, oc) (c = dot(oc, oc) - bv_r * bv_r)
                        CALC_OC_DOT: begin
                        end

                        // 4. h = dot(ray_dir, oc)
                        CALC_H: begin
                        end

                        // 5. r^2 (c = dot(oc, oc) - bv_r * bv_r)
                        CALC_R2: begin
                            req_op[4:0]                   <= 5'b00110; // Scalar multiplication ux × vx
                            req_op[20:5], req_op[68:53]   <= slot_b;   // Scalar x: bv_r
                            req_op[52:21], req_op[100:69] <= 32'b0;    // Disable y, z
                            req_op[101]                   <= 1'b0;     // Return position
                            req_valid                     <= 1'b1;
                        end

                        // 6. c = dot(oc, oc) - bv_r * bv_r
                        CALC_C: begin
                        end

                        // 7. ac = a*c (hit == (h*h - a*c !< 0) )
                        CALC_AC: begin
                        end

                        // 8. h2 = h*h (hit == (h*h - a*c !< 0) )
                        CALC_H2: begin
                        end

                        // 9. hit == (h*h - a*c !< 0)
                        CALC_DISCRIMINANT: begin
                        end

                        // 10. hit == (h*h - a*c !< 0)
                        CALC_HIT: begin
                        end

                        // 11. sqrtd = sqrt(h*h - a*c) (t = (h + sqrt(h*h - a*c) ) / a)
                        CALC_SQRTD: begin
                        end

                        // 12. numerator = h + sqrt(h*h - a*c) (t = (h + sqrt(h*h - a*c) ) / a)
                        CALC_NUMERATOR: begin
                        end

                        // 13. t = (h + sqrt(h*h - a*c) ) / a
                        CALC_T: begin
                        end

                        // WiP for hit_flip

                        default: ;
                    endcase
                end

                S_DEC_WAIT: begin
                    // Accept Decoder response
                    if (resp_valid) begin
                        resp_ready <= 1'b1; // Override global resp_ready <= 1'b0 for 1-cycle

                        // Latch resp_result
                        // Note: not sure how to deal with 2 root, in the document at
                        // https://uw-asic.github.io/TinyTracer/encoding/instruction/
                        // it is said that in Functional Units
                        // DIV, SQRT, COS, MAG map to CORDIC. RS1 is the CORDIC operand and RS2 is (see CORDIC)
                        // However, it also noted that in Micro-Op Semantics
                        // U_SQRT	RD <- SQRT(RS1), POS or DIR (FMT); RS2 not used	CORDIC	23
                        case (calc_stage_q)
                            CALC_A: begin
                                // Latch result (Scalar)
                                slot_a       <= resp_result [15:0];
                                // local register
                                // slot_a: a
                                // slot_b: null
                                // slot_c: null
                                // slot_d: null
                                // slot_e: null
                                // slot_f: null
                                // slot_g: null
                                // slot_h: null
                                // slot_i: null
                                
                                // Internal tracking
                                a_ready      <= 1'b1;
                                calc_stage_q <= CALC_R2;
                                
                                // Reset send Decoder request after latching
                                req_valid <= 1'b0;
                            end

                            CALC_OC: begin
                                // Latch result (Vector 3)
                                {slot_f, slot_g, slot_h} <= resp_result;
                                // local register
                                // slot_a: a
                                // slot_b: bv_r
                                // slot_c: bv_z
                                // slot_d: bv_y
                                // slot_e: bv_x
                                // slot_f: oc_z
                                // slot_g: oc_y
                                // slot_h: oc_x
                                // slot_i: null

                                // Internal tracking
                                oc_ready     <= 1'b1;
                                calc_stage_q <= CALC_OC_DOT;
                                
                                // Reset send Decoder request after latching
                                req_valid <= 1'b0;
                            end

                            CALC_OC_DOT: begin
                                // Latch result (Scalar)
                                slot_i       <= resp_result [15:0];
                                // local register
                                // slot_a: a
                                // slot_b: bv_r
                                // slot_c: bv_z
                                // slot_d: bv_y
                                // slot_e: bv_x
                                // slot_f: oc_z
                                // slot_g: oc_y
                                // slot_h: oc_x
                                // slot_i: oc_dot

                                // Internal tracking
                                oc_dot_ready <= 1'b1;
                                calc_stage_q <= CALC_H;
                                
                                // Reset send Decoder request after latching
                                req_valid <= 1'b0;
                            end

                            CALC_H: begin
                                // Latch result (Scalar)
                                slot_h       <= resp_result [15:0];
                                // local register
                                // slot_a: a
                                // slot_b: bv_r
                                // slot_c: bv_z
                                // slot_d: bv_y
                                // slot_e: bv_x
                                // slot_f: oc_z
                                // slot_g: oc_y
                                // slot_h: h
                                // slot_i: oc_dot

                                // Internal tracking
                                oc_ready     <= 1'b0;
                                h_ready      <= 1'b1;
                                calc_stage_q <= CALC_R2;
                                
                                // Reset send Decoder request after latching
                                req_valid <= 1'b0;
                            end

                            CALC_R2: begin
                                // Latch result (Scalar)
                                slot_f       <= resp_result [15:0];
                                // local register
                                // slot_a: a
                                // slot_b: bv_r
                                // slot_c: bv_z
                                // slot_d: bv_y
                                // slot_e: bv_x
                                // slot_f: bv_r2
                                // slot_g: oc_y
                                // slot_h: h
                                // slot_i: oc_dot

                                // Internal tracking
                                bv_r2_ready  <= 1'b1;
                                calc_stage_q <= CALC_C;
                                
                                // Reset send Decoder request after latching
                                req_valid <= 1'b0;
                            end

                            CALC_C: begin
                                // Latch result (Scalar)
                                slot_g       <= resp_result [15:0];
                                // local register
                                // slot_a: a
                                // slot_b: bv_r
                                // slot_c: bv_z
                                // slot_d: bv_y
                                // slot_e: bv_x
                                // slot_f: bv_r2
                                // slot_g: c
                                // slot_h: h
                                // slot_i: oc_dot

                                // Internal tracking
                                c_ready      <= 1'b1;
                                calc_stage_q <= CALC_AC;
                                
                                // Reset send Decoder request after latching
                                req_valid <= 1'b0;
                            end

                            CALC_AC: begin
                                // Latch result (Scalar)
                                slot_g       <= resp_result [15:0];
                                // local register
                                // slot_a: a
                                // slot_b: bv_r
                                // slot_c: bv_z
                                // slot_d: bv_y
                                // slot_e: bv_x
                                // slot_f: bv_r2
                                // slot_g: ac
                                // slot_h: h
                                // slot_i: oc_dot
                                
                                // Internal tracking
                                ac_ready     <= 1'b1;
                                calc_stage_q <= CALC_H2;
                                
                                // Reset send Decoder request after latching
                                req_valid <= 1'b0;
                            end

                            CALC_H2: begin
                                // Latch result (Scalar)
                                slot_f       <= resp_result [15:0];
                                // local register
                                // slot_a: a
                                // slot_b: bv_r
                                // slot_c: bv_z
                                // slot_d: bv_y
                                // slot_e: bv_x
                                // slot_f: h2
                                // slot_g: ac
                                // slot_h: h
                                // slot_i: oc_dot
                                
                                // Internal tracking
                                bv_r2_ready  <= 1'b0;
                                h2_ready     <= 1'b1;
                                calc_stage_q <= CALC_DISCRIMINANT;
                                
                                // Reset send Decoder request after latching
                                req_valid <= 1'b0;
                            end

                            CALC_DISCRIMINANT: begin
                                // Latch result (Scalar)
                                slot_g       <= resp_result [15:0];
                                // local register
                                // slot_a: a
                                // slot_b: bv_r
                                // slot_c: bv_z
                                // slot_d: bv_y
                                // slot_e: bv_x
                                // slot_f: h2
                                // slot_g: discriminant
                                // slot_h: h
                                // slot_i: oc_dot
                                
                                // Internal tracking
                                ac_ready           <= 1'b0;
                                discriminant_ready <= 1'b1;
                                calc_stage_q       <= CALC_HIT;
                                
                                // Reset send Decoder request after latching
                                req_valid <= 1'b0;
                            end

                            CALC_HIT: begin
                                // Latch result (Compare)
                                if (!hit) hit <= resp_result[0]; // One-way toggle until next start signal
                                
                                // Internal tracking
                                hit_ready    <= 1'b1;
                                calc_stage_q <= CALC_SQRTD;
                                
                                // Reset send Decoder request after latching
                                req_valid <= 1'b0;
                            end

                            CALC_SQRTD: begin
                                // Latch result (Scalar)
                                slot_f       <= resp_result [15:0];
                                // local register
                                // slot_a: a
                                // slot_b: bv_r
                                // slot_c: bv_z
                                // slot_d: bv_y
                                // slot_e: bv_x
                                // slot_f: sqrtd
                                // slot_g: discriminant
                                // slot_h: h
                                // slot_i: oc_dot
                                
                                // Internal tracking
                                h2_ready     <= 1'b0;
                                sqrtd_ready  <= 1'b1;
                                calc_stage_q <= CALC_NUMERATOR;
                                
                                // Reset send Decoder request after latching
                                req_valid <= 1'b0;
                            end

                            CALC_NUMERATOR: begin
                                // Latch result (Scalar)
                                slot_f       <= resp_result [15:0];
                                // local register
                                // slot_a: a
                                // slot_b: bv_r
                                // slot_c: bv_z
                                // slot_d: bv_y
                                // slot_e: bv_x
                                // slot_f: numerator
                                // slot_g: discriminant
                                // slot_h: h
                                // slot_i: oc_dot
                                
                                // Internal tracking
                                sqrtd_ready     <= 1'b0;
                                numerator_ready <= 1'b1;
                                calc_stage_q    <= CALC_T;
                                
                                // Reset send Decoder request after latching
                                req_valid <= 1'b0;
                            end

                            CALC_T: begin
                                // Latch result (Scalar)
                                // if () begin // Handshake with main FSM to determine shortest t
                                //    hit_t  <= resp_result [15:0];
                                    // not declare and not sure how to optimize the local register reduction
                                //    center <= {slot_c, slot_d, slot_e};
                                //    radius <= slot_b;
                                
                                // Internal tracking
                                t_ready   <= 1'b1;
                                
                                // Reset send Decoder request after latching
                                req_valid <= 1'b0;
                            end

                            // WiP for hit_flip

                            default: ;
                        endcase
                    end
                end

                S_DEC_DONE: begin
                    req_valid          <= 1'b0;
                    resp_ready         <= 1'b0;
                    // Reset for next BV object
                    calc_stage_q       <= CALC_OC;
                    oc_ready           <= 1'b0;
                    oc_dot_ready       <= 1'b0;
                    h_ready            <= 1'b0;
                    bv_r2_ready        <= 1'b0;
                    c_ready            <= 1'b0;
                    ac_ready           <= 1'b0;
                    h2_ready           <= 1'b0;
                    discriminant_ready <= 1'b0;
                    hit_ready          <= 1'b0;
                    sqrtd_ready        <= 1'b0;
                    numerator_ready    <= 1'b0;
                    t_ready            <= 1'b0;
                end

                default: ;
            endcase
        end
    end

endmodule
