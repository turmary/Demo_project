////////////////////////////////////////////////////////////////////////////////
/// \file i2crepeater.v
/// \brief I2C Repeater module
///
/// \author Eric Gallimore <egallimore@whoi.edu>
///
///
/// Incorporates a start/stop detection technique by gszakacs found on Xilinx forums.
///
////////////////////////////////////////////////////////////////////////////////

module i2crepeater
(
	input reset,
	input system_clk,
	input master_scl,
	input  i_master_sda,
	/* output o_master_sda, */
	output slave_scl,
	input  i_slave_sda,
	/* output o_slave_sda, */
	output sda_direction_tap	// For probing
);

	// Direction of SDA signal
	parameter MOSI = 0,
	          MISO = 1;
	reg sda_direction;
	assign sda_direction_tap = (sda_direction == MISO) ? 1 : 0;

	// States
	parameter
	  IDLE         = 8'b0000_0001,
	  ADDRESS      = 8'b0000_0010,
	  RWBIT        = 8'b0000_0100,
	  SLAVEACK     = 8'b0000_1000,
	  MASTERACK    = 8'b0001_0000,
	  DATATOSLAVE  = 8'b0010_0000,
	  DATAFROMSLAVE= 8'b0100_0000;
	reg [6:0] State;

	// Just pass the clock through from master to slave.
	assign slave_scl = master_scl? 1'bz: 0;


	// Assignment of I/O.
	/*
	assign o_slave_sda = (sda_direction == MOSI) ? (i_master_sda? 1'bz: 0) : 1'bz;
	assign o_master_sda = (sda_direction == MISO) ? i_slave_sda : 1'bz;
	*/


	// Sample the SDA and SCL lines to do start and stop detection
	// Only the master can generate start and stop signals.
	reg [4:0] scl_samples; // Multiple samples used to debounce signal.
	reg [4:0] sda_samples;
	reg scl_new;
	reg scl_old;
	reg sda_new;
	reg sda_old;
	reg got_start;
	reg got_stop;
	always @(posedge system_clk or posedge reset) begin
		if (reset) begin
			scl_samples <= 5'b11111;  // I2C signals are pulled up by default
			sda_samples <= 5'b11111;
			scl_new <= 1;
			scl_old <= 1;
			sda_new <= 1;
			sda_old <= 1;
			got_start <= 0;
			got_stop <= 0;

		end else begin
			// Sample the signals and store them
			// Shift the old samples left by one bit to make room for the new ones.
			scl_samples <= {scl_samples[3:0], master_scl};
			sda_samples <= {sda_samples[3:0], i_master_sda};
			// Keep track of previous values
			scl_old <= scl_new;
			sda_old <= sda_new;
			// Turn samples into scl and sda values.
			if (scl_samples == 5'b11111)
				scl_new <= 1;
			else if (scl_samples == 5'b00000)
				scl_new <= 0;

			if (sda_samples == 5'b11111)
				sda_new <= 1;
			else if (sda_samples == 5'b00000)
				sda_new <= 0;

			// Do edge detection to find start and stop values.
			// If SCL remained high while SDA fell, we have a a start.
			if (scl_new & scl_old & !sda_new & sda_old)
				got_start <= 1;
			else if (!scl_new & !scl_old)	// clear got_start when SCL falls.
				got_start <= 0;

			// If SCL remained high while SDA rose, we have a stop.
			// will clear on next clock edge
			got_stop <= scl_new & scl_old & sda_new & !sda_old;
		end
	end


	// Sample the data bits on the positive edge of each clock cycle
	// Get both and decide what to do with them later.
	reg master_sda_bit;
	reg slave_sda_bit;
	always @(posedge master_scl) begin
		master_sda_bit <= i_master_sda;
		slave_sda_bit <= i_slave_sda;
	end


	// Bit counter with state tracking
	reg [3:0] bitcount;	// Counts 8 bits of data plus the ACK
	reg isread;	// Is this packet a read request?
	reg newcycle;

	always @(negedge master_scl or posedge reset or posedge got_start or posedge got_stop) begin
		if (reset || got_start || got_stop) begin
			State <= IDLE;
			sda_direction <= MOSI;
			bitcount <= 4'h7;
			isread <= 0;
		end else begin
			case (State)
			IDLE: begin
				// We are not idle any more, and are now waiting for an address
				State <= ADDRESS;
				bitcount <= 4'h6; // We miss an edge at the start.
			end

			ADDRESS: begin
				// We need to keep track of what bit we are on
				if (bitcount == 4'h1) // We have finished the 7 bit address, so the next bit is R/W
					State <= RWBIT;
				else
					bitcount <= bitcount - 4'h1;
			end

			RWBIT: begin
				isread <= master_sda_bit;
				sda_direction <= MISO;
				State <= SLAVEACK;
			end

			SLAVEACK: begin
				bitcount <= 4'h7;	// We will be waiting for a byte of data in one direction or the other
				if (isread) begin
					sda_direction <= MISO;
					State <= DATAFROMSLAVE;
				end else begin
					sda_direction <= MOSI;
					State <= DATATOSLAVE;
				end
			end

			DATAFROMSLAVE: begin
				// We need to keep track of what bit we're on, again.
				if (bitcount == 4'h0) begin // We just finished this byte.
					sda_direction <= MOSI;
					State <= MASTERACK;
				end else
					bitcount <= bitcount - 4'h1;
			end

			MASTERACK: begin
				// At this point, we will either get a start/stop or start on the next byte
				// Start/stop conditions dump us back to the beginning
				if (master_sda_bit == 1) begin	// NACK
					sda_direction <= MOSI;	// We will send a STOP next.
					State <= IDLE;
				end else begin
					bitcount <= 4'h7;	// We will be waiting for a byte of data
					sda_direction <= MISO;
					State <= DATAFROMSLAVE;
				end
			end

			DATATOSLAVE: begin
				// We need to keep track of what bit we're on, again.
				if (bitcount == 4'h0) begin // We just finished this byte.
					sda_direction <= MISO;
					State <= SLAVEACK;
				end else
					bitcount <= bitcount - 4'h1;
			end
			endcase
		end
	end
endmodule
