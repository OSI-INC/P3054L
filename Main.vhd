-- A3054L Long-Life IPT Firmware, Top-Level Unit

-- V2.0 [18-NOV-26] Based upon P3054 V1.9. Creating long-life version. 

-- V2.1 [18-NOV-26] Remove all EBR use, remove OSR8, interrupt timer, 
-- memory management unit. Create Telemetry dispatcher to pass sample 
-- memory values to the Message Transmitter and clear the sample memory 
-- afterwards. With all four analog inputs being sampled, accumulated 
-- four times, and transmitted at 256 SPS, logic consumes 232 LUTs. No 
-- contact with the accelerometer, non-volatile memory, or temperature 
-- sensor yet supported. Re-work state machines to reduce logic footprint 
-- while testing that we have four inputs being digitized, accumulated, 
-- and transmitted. Code fully-functional, 237 LUTs. Because we are not
-- putting the thermometer to sleep, current consumption keeps jumping
-- up to 200 uA. All ADCs have same shift and sample rate, but each
-- can be disabled. Tag and commit, but see no way to fit I2C function
-- into 256 LUTs.

-- V2.2 [22-NOV-26] Our objective now is to fit fully-functional code
-- into 640 LUTs with 2 EBR, as in the LXMCO2-640ZE. Increase length of
-- ring oscillator. Flash LED during power-up sequence.

-- V2.3 [23-NOV-26] Add command receiver from P3054P. Expand Command -- Processor to read and execute op-codes. Add temporary instruction 
-- to set fck_mask. Work on routing priorities and no-merge directives.
-- Hard-code individual transmit periods and shifts. Update comments.

-- V2.4 [24-NOV-26] Rename CMD_FIFO to CMDMEM. Disable transmission
-- while command incoming, allow while executing. Eliminate need to
-- reset the acquisition and dispatch processes called by the Telemetry
-- Manager. In making this improvement, we move the called processes
-- onto the falling edge of FCK. They now reset themselves and turn 
-- off FCK in one setp. Clean up code with subtypes and reduce all 
-- sensitivity lists to "all". Add to Entities a prototype I2
-- Master that consumes 44 LUTs when added to code. Acquisition and
-- transmission tested and working.

-- V2.5 [25-NOV-26] Individual transmit periods and shifts for X1
-- to X4 working. A new I2C Master process in the entities library.
-- Sweep response correct.

-- V2.6 [26-NOV-26] Add Sensor Reader that uses I2C Master to read
-- out thermometer, readout and transmission working. Code size jumps
-- from 378 to 495 LUTs. Decide to abandon LUT-based I2C Master and
-- Sensor Reader and instead try using the RCM5.

-- V2.7 [27-NOV-26] Add RMC5 processor, MMU, and implement program
-- that toggles TP. Working, size is 620 LUTs.

-- V2.8 [27-NOV-26] Delete Telemetry Dispatcher and replace with 
-- microcontroller Software Dispatcher. Add 32-Byte RAM. Have one
-- EBR working as 512-location instruction memory. Transmission 
-- working. Move command interpreter into Software Dispatcher.
-- Make all connections necessary for the dispatcher to interpret
-- commands. All I2C connections to dispatcher in place. Fast 
-- clock enabling set up. Size is 619 LUTs and 2 EBR. Maximum
-- TCK speed 7.5 MHz for VCC = 1.14 V, which is like 4.5 MHz at
-- our VCC = 1.02 V. We see zero-glitches in telemetry signals 
-- after programming, when chip is warm, then they stop.

-- V2.9 [27-NOV-26] Moving the Software Dispatcher to PCK = 2.5 MHz.


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity main is 
	port (
		RP, -- Receive Power
		RCK, -- Reference Clock
		SDO -- Serial Data Out for ADCs
		: in std_logic; 
		LV, -- Lower Logic Core Voltage
		XEN, -- Transmit Enable, for data transmission
		TP, -- Test Point, available on P1-7
		SCL, -- Serial Clock for I2C Bus
		LED, -- Turn On Indicator Lamp
		SCK, -- Serial Clock for ADC Bus
		DC, -- Direct Coupled Amplifiers
		MSR, -- Measure Input Impedance
		NADC1, -- Select ADC1, Negative True
		NADC2, -- Select ADC2, Negative True
		NADC3, -- Select ADC3, Negative True
		NADC4  -- Select ADC4, Negative True
		: out std_logic;
		SDA -- Serial Data Access for I2C Bus
		: inout std_logic;
		xdac -- Transmit DAC Output, to set data transmit frequency
		: out std_logic_vector(4 downto 0));
		
-- Identifier.
	subtype device_id_type is std_logic_vector(15 downto 0);
	constant device_id : device_id_type := x"AA55";
	constant wildcard_id : device_id_type := x"FFFF";
-- Configuration of the Ring Oscillator
	constant fck_num_feeds : natural := 8;
	constant fck_num_gates : natural := 26;
	subtype fck_mask_type is std_logic_vector(fck_num_feeds-1 downto 0);
	constant default_fck_mask : fck_mask_type :=x"10";
	constant fck_i2c_div : natural := 5;

-- Configuration and Calibration of Transmitter.
	constant frequency_step : positive := 1; 
	constant frequency_low : natural := 6;
	
-- Configuration of the Telemetry Manager
	constant TMRUN : boolean := true; -- Run the Telemetry Protocol
	constant tx_period : natural := 4; -- Shortest Period of All Signals
	
-- Sample and Accumulate Constants
	constant smem_addr_len : positive := 4;
	subtype smem_addr_type is std_logic_vector(smem_addr_len-1 downto 0);
	constant x1_addr : smem_addr_type := "0000";
	constant x2_addr : smem_addr_type := "0001";
	constant x3_addr : smem_addr_type := "0010";
	constant x4_addr : smem_addr_type := "0011";
	constant tp_addr : smem_addr_type := "0100";
	constant x1_pd : natural range 0 to 16 := 1;
	constant x2_pd : natural range 0 to 16 := 2;
	constant x3_pd : natural range 0 to 16 := 4;
	constant x4_pd : natural range 0 to 16 := 8;
	constant tp_pd : natural range 0 to 16 := 16;
	constant x1_shift : natural range 0 to 7 := 4;
	constant x2_shift : natural range 0 to 7 := 3;
	constant x3_shift : natural range 0 to 7 := 2;
	constant x4_shift : natural range 0 to 7 := 1;
end;

architecture behavior of main is

-- Generic types.
	subtype byte_type is std_logic_vector(7 downto 0);
	subtype nibble_type is std_logic_vector(3 downto 0);

-- Attributes that request signals to be retained instead of distributed.
	attribute syn_keep : boolean;
	attribute nomerge : string;

-- Power Controller
	signal USERSTDBY, CLRFLAG : std_logic := '0';
	signal RESET : std_logic := '1';
	attribute syn_keep of RESET : signal is true;
	attribute nomerge of RESET : signal is "";
	signal SFLAG, STDBY : std_logic;
	signal SWRST : boolean := false;
	
-- Ring Oscillator, Fast Clock, and Transmit Clock. We want the 
-- compiler to preserve the fck_mask bits or else FCK period will 
-- not be always increasing with mask bit index. We find the period
-- of the ring oscillator is more consistent from one compile to 
-- the next if we preserve the control signals too.
	signal TCK, FCK, PCK, MCK : std_logic;
	signal FCKEN : boolean; 
	signal fck_mask : fck_mask_type := default_fck_mask;
	attribute syn_keep of TCK, FCK, PCK, MCK, FCKEN, fck_mask : signal is true;
	attribute nomerge of TCK, FCK, PCK, MCK, FCKEN, fck_mask : signal is ""; 

-- Sample Memory and Accumulator
	subtype smem_data_type is std_logic_vector(17 downto 0);
	signal smem_data : smem_data_type; -- Sample Memory Output
	signal acc_data : smem_data_type; -- Accumulator Output
	signal sample_data : smem_data_type; -- Accumulator Input
	signal smem_addr : smem_addr_type; -- Sample Memory Addr

-- Telemetry Manager
	signal tm_addr : smem_addr_type; -- Manager Sample Select
	signal adc_shift : natural range 0 to 4; -- ADC sample left shift.
	subtype transmit_shift_type is std_logic_vector(3 downto 0);
	signal transmit_shift : transmit_shift_Type;
		
-- ADC Reader
	signal ADCCAL, -- Calibrate the Selected ADC
		ADCCS, -- ADC Chip Select
		ADCRQ, -- Request ADC Read
		ADCACK, -- Acknowledge ADC Read
		ADCSHSD -- ADC Reader Shifts Sample Data
		: boolean := false;
	signal ADCWRSM, -- ADC Reader Write to Sample Memory
		ADCBIT, -- ADC Bit for Sample Data
		ADCADD -- ADC Reader Requests Addition
		: std_logic;

-- Configuration of RMC5 Microcontroller.
	constant mcu_addr_len : positive := 10;
	constant mcu_sp_len : positive := 4;
	constant mcu_opcode_len : positive := 5;
	constant mcu_instr_len : positive := mcu_addr_len + mcu_opcode_len;

-- Memory Map Constants, sizes and base addresses.
	constant mmu_const_bot : natural := 16#0000#;
	constant mmu_const_top : natural := 16#00FF#;
	constant mmu_ram_bot   : natural := 16#0100#;
	constant mmu_ram_top   : natural := 16#01FF#;
	constant mmu_ctrl_bot  : natural := 16#0200#;
	constant mmu_ctrl_top  : natural := 16#02FF#;
	constant mmu_cmd_bot   : natural := 16#0300#;
	constant mmu_cmd_top   : natural := 16#03FF#;
	constant mmu_ctrl_len : positive := 5; -- Register Address Length
	constant mmu_ram_len : positive := 5; -- Process RAM Address Length
	
-- Register Locations. We specify the offset from the start of the control
-- space. When a location is a control register shadowed in RAM, we say it 
-- is "Write/Readback". When writing to a location stores a value, we say
-- "Write". When a location can be read but not written, we say it is 
-- "Read". When writing or reading initiates a process we say "Strobe". 
	constant mmu_irqb  : natural := 16#00#; -- Interrupt Request Bits (Read)
	constant mmu_irst  : natural := 16#01#; -- Interrupt Reset Bits (Write)
	constant mmu_acfg  : natural := 16#02#; -- Amplifier Configuration (Write)
	constant mmu_led   : natural := 16#03#; -- Lamp Switch (Write)
	constant mmu_rst   : natural := 16#04#; -- Software Reset (Write)
	constant mmu_xch   : natural := 16#05#; -- Transmit Channel Number (Write/Strobe)
	constant mmu_rfc   : natural := 16#06#; -- Radio Frequency Calibration (Write)	
	constant mmu_dfr   : natural := 16#07#; -- Diagnostic Flags (Write)
	constant mmu_sr    : natural := 16#08#; -- Status Register (Read)
	constant mmu_cmp   : natural := 16#09#; -- Command Memory Portal (Read/Write/Strobe)
	constant mmu_fck   : natural := 16#0A#; -- Fast Clock Mask (Write)
	constant mmu_i2c00 : natural := 16#0B#; -- i2c SDA=0 SCL=0 (Write)
	constant mmu_i2c01 : natural := 16#0C#; -- i2c SDA=0 SCL=1 (Write)
	constant mmu_i2cA0 : natural := 16#0D#; -- i2c SDA=A SCL=0 (Write)
	constant mmu_i2cA1 : natural := 16#0E#; -- i2c SDA=A SCL=1 (Write)
	constant mmu_i2cZ0 : natural := 16#0F#; -- i2c SDA=Z SCL=0 (Write)
	constant mmu_i2cZ1 : natural := 16#10#; -- i2c SDA=Z SCL=1 (Write)
	constant mmu_i2cMR : natural := 16#11#; -- i2C Most Recent Eight Bits (Read)
	constant mmu_x1cfg : natural := 16#12#; -- X1 Configuration (Write)
	constant mmu_x2cfg : natural := 16#13#; -- X2 Configuration (Write)
	constant mmu_x3cfg : natural := 16#14#; -- X3 Configuration (Write)
	constant mmu_x4cfg : natural := 16#15#; -- X4 Configuration (Write)
	constant mmu_saddr : natural := 16#16#; -- Sample Memory Addr (Write)
	constant mmu_sacc  : natural := 16#17#; -- Sample Accumulator Control (Write/Strobe)
	
-- Microcontroller Flags, Buses, and Registers
	subtype mcu_addr_type is std_logic_vector(mcu_addr_len-1 downto 0);
	subtype mcu_instr_type is std_logic_vector(mcu_instr_len-1 downto 0);
	signal prog_cntr, mcu_addr : mcu_addr_type;
	signal prog_data : mcu_instr_type;
	signal mcu_data_out, mcu_data_in, ram_data : byte_type;
	signal WDS : boolean;
	signal RAMWR : std_logic;
	signal df_reg : nibble_type;

-- Software Dispatcher.
	signal TDWRSM, -- Telemetry Dispatcher Write to Sample Memory
		TDRSTACC -- Telemetry Dispatcher Resets Accumulator
		: std_logic;
	signal TDRQ, -- Telemetry Dispatcher Request
		TDACK, -- Telemetry Dispatcher Acknowledge
		TDBSY -- Telemetry Dispatcher Busy
		: boolean := false;
	signal sd_addr : smem_addr_type; -- Software Dispatcher Sample Select

-- Message Transmission. The syn_keep and nomerge reduce code size 
-- slightly.
	signal TXI, -- Transmit Initiate
		TXWP, -- Transmit Warmup
		TXA, -- Transmit Active
		TXB, -- Transmit Bit
		FHI -- Frequency High
		: boolean := false;
	attribute syn_keep of TXI, TXA : signal is true;
	attribute nomerge of TXI, TXA : signal is "";  
	constant max_chan_num : positive := 255;
	signal td_chan : natural range 0 to max_chan_num;

-- I2C Bus Controller
	signal i2c_in : std_logic_vector(7 downto 0); -- I2C Serial Byte

-- Byte Receiver
	signal RPS, -- Radio Frequency Power Synchronized
		ICMD, -- Initiate Command Reception
		TCMD, -- Terminate Command Reception
		RCMD, -- Receive Command
		RBI, -- Receive Command Byte Initiate
		RBD, -- Receive Command Byte Done
		CRCERR, -- Checksum Error
		BYTS, -- Command Byte Strobe
		CBS -- Command Bit Strobe (CBS)
		: boolean := false; 
	
-- Command Processor
	subtype cmd_data_type is std_logic_vector(7 downto 0);
	signal cmd_in : cmd_data_type; -- Command Memory Data In
	signal cmd_out : cmd_data_type; -- Command Memory Data Out
	signal CME, -- Command Memory Empty
		CMF, -- Command Memory Full
		CMRST, -- Command Memory Reset
		CMWR,  -- Command Memory Write
		CMRD -- Command Memory Read
		: std_logic; 
	signal CMDRQ, -- Command Processor Request 
		CMDACK, -- Command Processor Acknowledge
		CMDRCV -- Command Processor Receiving
		: boolean := false;
		
-- Functions and Procedures	
	function to_std_logic (v: boolean) return std_ulogic is
	begin if v then return('1'); else return('0'); end if; end function;

begin

-- We turn off the logic chip bandgap references and other power-hungry
-- circuits with the power controller unit (PCU). Within a few milliseconds
-- of power-up, the chip is fully operational, but consuming several 
-- milliamps. We must still wait for RCK to start up, which will take
-- roughly 150 ms. Once we have RCK, we move the chip into standby mode by
-- clearing the standby flag with CLRFLAG and asserting USERSTDBY. This
-- begins the transition to standby mode. The PCU has two outputs: STDBY and 
-- SFLAG. The STDBY signal is intended as a command to put circuits to sleep, 
-- while SFLAG is intended as a signal that the system has entered standby 
-- mode. We return to full-power mode when we program the chip.
	Power_Controller: entity PCU port map (
		CLRFLAG => CLRFLAG,
		USERSTDBY => USERSTDBY, 
		STDBY => STDBY,
		SFLAG => SFLAG);	

-- The Power-Up Process. We have CLRFLAG and USERSTDBY cleared LO on power-up,
-- and RESET set HI. When RCK starts up, we use the falling edge to move the 
-- chip into standby mode, then unassert RESET once we receive SFLAG from the
-- Power Control Unit (PCU).
	PowerUp: process (all) is
		constant end_state : natural := 7;
		constant clr_state : natural := 3;
		constant stdby_state : natural := clr_state + 2;
		variable state : natural range 0 to end_state := 0;
	begin
		if falling_edge(RCK) then
			CLRFLAG <= to_std_logic(state = clr_state);
			USERSTDBY <= to_std_logic(state >= stdby_state);
			RESET <= to_std_logic((state < end_state) or SWRST);
			LV <= to_std_logic(state = end_state);
			LED <= to_std_logic(state < end_state);

			if (state < stdby_state) then state := state + 1;
			elsif (SFLAG = '0') then state := stdby_state;
			elsif (state < end_state) then state := state + 1; 
			else state := end_state; end if;
		end if;
	end process;	

-- The Fast Clock entity produces FCK. The ring oscillator should be 
-- calibrated so that it produces FCK of 10 MHz. The Fast Clock is
-- enabled whenever the request and acknowledgment signals of one of
-- our acquisition or dispatch processes are not equal.
	FCKEN <= (ADCRQ xor ADCACK) or (TDRQ xor TDACK) or (CMDRQ xor CMDACK);
	Fast_Clock : entity ring_oscillator 
		generic map (
			num_gates => fck_num_gates,
			num_feeds => fck_num_feeds
		)	
		port map (
			ENABLE => FCKEN, 
			mask => fck_mask,
			CK => FCK
		);
		
-- The Clock Divider produces the Transmit Clock (TCK) for the-- Message Transmitter, 5 MHz, and the Processor Clock (PCK) for
-- the Software Dispatcher, 2.5 MHz.
	Clock_Divider : process (all) is
	begin
		if falling_edge(FCK) then
			TCK <= not TCK;
			if TCK = '1' then
				PCK <= not PCK;
			end if;
		end if;
	end process;
	
-- The Telemetry Manager cycles through thirty-two states. It runs-- off the rising edge of RCK, and so completes its cycles at 
-- 1024 Hz. In states zero and one, it does nothing, so as to make 
-- sure that the dispatch processes initiated in the previous cycle 
-- have completed their work. In states two to fifteen, it calls 
-- acquisition processes. In states sixteen to thirty-one the 
-- manager picks one of the sixteen states at random in which to 
-- call the Telemetry Dispatcher. The dispatcher's operations may 
-- take up to three RCK cycles to complete, so if the dispatcher is-- called in state thirty-one, its operations may not complete until 
-- the manager is in state one. This overlap into state one is why 
-- the manager does nothing in states zero and one. 
--
-- During the acquisition states two to fifteen, the Telemetry 
-- Manager updates the sample memory as required by the telemetry 
-- protocol. The manager will not aquire or update each sample memory 
-- location on each cycle, but may instead wait for some number of 
-- cycles before updating. Whenever the manager updates the sample 
-- memory, it does so by setting some control signals and calling 
-- an acquisition process that runs off the falling edge of FCK. The 
-- manager and acquisition process x cooperate through the use of
-- two signals xRQ and xACK. The manager toggles xRQ to start 
-- process x. The xRQ and xACK will now be unequal, and this inequality
-- starts FCK. The FCK signal will go HI. On the falling edge of FCK, 
-- process x detects xRQ xor xACK and starts running. When process x 
-- is done, it toggles xACK and returns to its idle state on the same
-- falling edge of FCK. Now that xACK and xRQ are equal, FCK stops 
-- running. It remains LO and process x stays in its idle state. When
-- FCK starts running for another process, process x remains in its
-- idle state. The manager assumes that every acquisition process 
-- will complete within one RCK cycle, so it does not bother to watch 
-- the acquisition busy flag.
--
-- In states sixteen to thirty-one, the Telemetry Manager uses the four
-- transmit_shift bits to pick one of these sixteen states to start the
-- Telemetry Dispatcher. These bits are randomized by the ADC Reader 
-- acquisition process using the least significant bits of ADC samples.
-- The dispatcher runs off the falling edge of FCK and interacts with 
-- the manager in the same way as do acquisition processes: with a 
-- request and acknowledge toggle handshake.--
-- We can disable all acquisition and dispatch by setting the TMRUN 
-- flag to false. The Telemetry Manager will keep running through its
-- cycle, which means it can still provide the millisecond clock (MCK),
-- which is used by other processes for measuring intervals.
	Telemetry_Manager : process (all) is
		constant cycle_len : positive := 32;
		variable state, next_state : natural range 0 to cycle_len-1;
	begin
		if (RESET = '1') then
			ADCRQ <= false;
			ADCCAL <= true;
			TDRQ <= false;
			MCK <= '0';
			state := 0;
			adc_shift <= 0;
			tm_addr <= (others => '0');
		elsif rising_edge(RCK) then
			next_state := (state + 1) mod cycle_len;

			if TMRUN then 
				if (state = 2) then
					tm_addr <= x1_addr;
					adc_shift <= x1_shift;
					if (x1_pd /= 0) then 
						ADCRQ <= not ADCRQ;
					end if;
				elsif (state = 3) then
					tm_addr <= x2_addr;
					adc_shift <= x2_shift;
					if (x2_pd /= 0) then 
						ADCRQ <= not ADCRQ;
					end if;
				elsif (state = 4) then
					tm_addr <= x3_addr;
					adc_shift <= x3_shift;
					if (x3_pd /= 0) then 
						ADCRQ <= not ADCRQ;
					end if;
				elsif (state = 5) then
					tm_addr <= x4_addr;
					adc_shift <= x4_shift;
					if (x4_pd /= 0) then 
						ADCRQ <= not ADCRQ;
					end if;
				elsif (state = 6) then
					ADCCAL <= false;
				elsif (state = to_integer(unsigned(transmit_shift))+16) then
					TDRQ <= not TDRQ;
				end if;
			end if;
			
			if (state <= 15) then
				MCK <= '0';
			else
				MCK <= '1';
			end if;

		state := next_state;
		end if;
	end process;

-- The Sample Memory is eighteen bits wide so as to accommodate
-- the sum of up to sixteen of fourteen-bit ADC samples. The 
-- sample memory runs off the fast clock(FCK) to work well with 
-- the Sample Controller and the Telemetry Dispatcher, which also
-- run on FCK.
	Sample_Memory : entity SMRAM port map (
		Clock => not FCK,
		ClockEn => '1',
 		WE => ADCWRSM or TDWRSM,
		Address => smem_addr, 
		Data => acc_data,
		Q => smem_data);

-- The Sample Register accepts an input value from one of the 
-- sample-generating processes and shifts left in response to 
-- any one of the shift signals provided by those same processes.
	Sample_Register : process (all) is
	begin
		if RESET = '1' then
			sample_data <= (others => '0');
		elsif falling_edge(FCK) then
			if ADCSHSD then
				sample_data(17 downto 1) <= sample_data(16 downto 0);
				sample_data(0) <=
					(ADCBIT and to_std_logic(ADCSHSD));
			end if;
		end if;
	end process;	

-- The Sample Address Multiplexer chooses either the Telemetry-- Dispatcher address or the Telemetry Manager address for the
-- Sample Memory. The Telemetry Dispatcher takes priority.
	Sample_Addr_Mux : process (all) is 
	begin
		if TDBSY then
			smem_addr <= sd_addr;
		else
			smem_addr <= tm_addr;
		end if;
	end process;
		
-- The Sample Accumulator adds the sample data to the output 
-- of the sample memory. We can reset its output to zero with
-- its reset line.
	Sample_Accumulator : entity SMADD port map (
		DataA => sample_data,
		DataB => smem_data,
		Result => acc_data,
		Clock => not FCK,
		ClockEn => ADCADD,
		Reset => TDRSTACC
	);

-- The ADC Reader is an acquisition process called by the Telemetry 
-- Manager. It runs off the falling edge of FCK. It starts up when-- it seesl ADCRQ xor ADCACK. When the ADCCAL flag is set, the reader
-- performs an extra-long read that initiates the ADC self-calibration
-- provided that this is the first ADC read after power-up. At all other
-- times, the reader performs a fourteen-bit sample read. To prepare for
-- these bits, the reader shifts four leading zeros into the sample
-- data register by asserting ADCSHSD and assigning ADCBIT. The 
-- fourteen ADC bits follow, and then zero to four more zeros as 
-- directed by adc_shift. The reader asserts ACCADD and ADCSMWR to
-- accumulate and store.
	ADC_Reader : process (all) is
		variable state, next_state : natural range 0 to 63 := 0;
		constant calib_end : natural := 50;
		constant read_end : natural := 41;
	begin
		-- Upon startup, make sure we are in the idle state and
		-- our flags are disabled.
		if (RESET = '1') then
			state := 0;
			ADCCS <= false;
			ADCADD <= '0';
			ADCWRSM <= '0';
			ADCBIT <= '0';
			ADCSHSD <= false;
			ADCACK <= false;
			transmit_shift <= (others => '1');

		-- The reader loads four leading zeros into the sample data
		-- register. It read one leading zero from the ADC. It reads
		-- fourteen data bits from the converter and shifts these
		-- immediately into the data sample data register. To end 
		-- a standard sample, it reads three trailing zeros before 
		-- releasing the chip select line. In a calibration sample,
		-- the reader reads nine trailing zeros before releasing 
		-- chip select. Whenever chip select is released, the ADC
		-- performs another conversion.
		elsif falling_edge(FCK) then

			-- The state progression logic. The process starts
			-- when it sees ADCRQ xor ADCACK.
			if (state = 0) then
				if (ADCRQ xor ADCACK) then
					next_state := 1;
				else
					next_state := 0;
				end if;
			elsif ((state = read_end) and (not ADCCAL))
				or ((state = calib_end) and ADCCAL) then
				next_state := 0;
				ADCACK <= not ADCACK;
			else
				next_state := state + 1;
			end if;
			
			-- By default, we do not shift the sample data.
			ADCSHSD <= false;
			
			-- Load a zero when moving out of state zero with
			-- the assertion of ADCRD.
			if (state = 0) then
				ADCBIT <= '0';
				if (ADCRQ xor ADCACK) then
					ADCSHSD <= true;
				end if;		
			end if;

			-- Load three more zeros into the sample data word.
			if (state >= 1) and (state <= 3) then
				ADCBIT <= '0';
				ADCSHSD <= true;
			end if;
				
			-- Read fourteen data bits.
			if (state >= 4) and (state <= 30)
				and ((state mod 2) = 0) then
				ADCBIT <= SDO;
				ADCSHSD <= true;
			end if;

			-- Programmable left shift, zero to four places.
			if ((state = 32) and (adc_shift >= 1))
				or ((state = 34) and (adc_shift >= 2))
				or ((state = 36) and (adc_shift >= 3))
				or ((state = 38) and (adc_shift >= 4)) then
				ADCBIT <= '0';
				ADCSHSD <= true;
			end if;

			-- Shared SCK generation for normal and calibration reads.
			SCK <= to_std_logic(
				(state = 0)
				or (
					((state mod 2) = 1)
					and (state < 48)
					and (ADCCAL or (state < 36))
				)
			);

			-- Update the transmit-scatter shift register.
			if (state = 31) then
				transmit_shift(3) <=
					ADCBIT xor transmit_shift(0);
				transmit_shift(2) <=
					transmit_shift(3) xor transmit_shift(0);
				transmit_shift(1) <= transmit_shift(2);
				transmit_shift(0) <= transmit_shift(1);
			end if;

			-- Accumulator and sample-memory control.
			ADCADD <= to_std_logic((state = read_end - 2) and (not ADCCAL));
			ADCWRSM <= to_std_logic((state = read_end - 1) and (not ADCCAL));

			-- Assert the chip select line flag.
			ADCCS <= (state > 0) and (state < calib_end)
				and (ADCCAL or (state < read_end - 2));

			-- Assign new state value.
			state := next_state;
		end if;

		NADC1 <= to_std_logic(not (ADCCS and (tm_addr = x1_addr)));
		NADC2 <= to_std_logic(not (ADCCS and (tm_addr = x2_addr)));
		NADC3 <= to_std_logic(not (ADCCS and (tm_addr = x3_addr)));
		NADC4 <= to_std_logic(not (ADCCS and (tm_addr = x4_addr)));
	end process;

-- Software Dispatcher Instruction Memory. This read-only memory
-- holds the dispatcher's program. The instructions are not
-- bytes, but rather a concatination of a five-bit opcode and an
-- address. With a ten-bit address, the instructions are 15 bits
-- wide and the instruction memory is 1024 instructions deep.
-- The instruction memory must run on the falling edge of the
-- microcontroller clock.
	Dispatcher_ROM : entity ROM
		port map (
			Address => prog_cntr(8 downto 0),
			OutClock => not PCK,
			OutClockEn => '1',
			Reset => '0',
			Q => prog_data
		);
-- The Software Dispatcher Process Memory. This is a single-port 
-- RAM built in LUTs. We write on the rising edge of the
-- microcontroller clock and our reads are asynchronous.
	Dispatcher_RAM : entity RAM
		port map (
			Address => mcu_addr(mmu_ram_len-1 downto 0),
			Clock => PCK,
			ClockEn => '1',
			WE => RAMWR,
			Data => mcu_data_out,
			Q => ram_data
		);
	
-- The Software Dispatcher is a microcontroller that performs several
-- tasks in response to flags set by the Telemetry Manager, Command
-- Receiver, and Power-Up processes. We instantiate an RMC5
-- microcontroller, but we don't use all its port signals, and
-- so obtain some reduction in its size. We do not drive its Interrupt
-- Request (IRQ) or Clock Enable (CKEN) inputs. We do not use its 
-- Interrupt Service (ISRV) or Read Data Strobe (RDS) outputs. The
-- MCU runs of the Processor Clock (TCK), which is one quarter the 
-- Fast Clock (FCK). Because PCK runs off the falling edges of FCK, 
-- a PCK rising edge will occur just after an FCK falling edge.
	Software_Dispatcher : entity RMC5_MCU
		generic map (
			addr_len => mcu_addr_len,
			sp_len => mcu_sp_len
		)
		port map (
			prog_cntr => prog_cntr,
			prog_data => prog_data,
			mcu_data_out => mcu_data_out,
			mcu_data_in => mcu_data_in,
			mcu_addr => mcu_addr,
			WDS => WDS,
			IRQ => false,
			RESET => RESET,
			CK => PCK,
			CKEN => true
		);
	
-- Software Dispatcher Memory Management Unit.
	Dispatcher_MMU : process (all) is 
		variable full_addr : natural range 0 to (2**mcu_addr_len)-1;
		variable low_addr : natural range 0 to (2**mmu_ctrl_len)-1;

	begin
		-- These signals develop after the CPU asserts a new address. 
		-- They will be ready before the falling edge of the CK.
		full_addr := to_integer(unsigned(mcu_addr));
		low_addr := to_integer(unsigned(mcu_addr(mmu_ctrl_len-1 downto 0)));
		
		-- By default, don't write to RAM.
		RAMWR <= '0';
		
		-- Combinatorial memory map, which serves all access except 
		-- for writing to control registers.
		mcu_data_in <= (others => '0');
		case full_addr is
		when mmu_const_bot to mmu_const_top =>
			mcu_data_in <= mcu_addr(7 downto 0);
		when mmu_ram_bot to mmu_ram_top =>
			mcu_data_in <= ram_data;
			RAMWR <= to_std_logic(WDS);
		when mmu_ctrl_bot to mmu_ctrl_top =>
			case low_addr is
			when mmu_sr =>
				mcu_data_in(6) <= CME;
			when mmu_irqb =>
				mcu_data_in(0) <= to_std_logic(TDRQ xor TDACK);
				mcu_data_in(1) <= to_std_logic(CMDRQ xor CMDACK);
			when mmu_cmp =>
				mcu_data_in <= cmd_out;
			when mmu_i2cMR => 
				mcu_data_in <= i2c_in;
			when others =>
				null;
			end case;
		when others =>
			null;
		end case;
		
		-- Control register write access memory map. Writes take place on 
		-- the rising edge of CK. We use RESET to clear some registers and 
		-- signals, but not all. In particular, we do not clear Software 
		-- Reset (SWRST) on RESET because we want SWRST itself to cause 
		-- RESET to be asserted for one full CK period. After a reset, the
		-- cpu address will not select the SWRST location, so SWRST will 
		-- be cleared on the next rising edge of CK.
		if (RESET = '1') then
			df_reg <= (others => '0');
			TXI <= false;
			TDACK <= false;
			TDBSY <= false;
			TDWRSM <= '0';
			TDRSTACC <= '0';
			CMDACK <= false;
			CMRD <= '0';
		elsif rising_edge(PCK) then
			SWRST <= false;
			TXI <= false;
			TDWRSM <= '0';
			TDRSTACC <= '0';
			CMRD <= '0';
			if (full_addr >= mmu_ctrl_bot) and (full_addr <= mmu_ctrl_top) then
				if WDS then
					case low_addr is
					when mmu_irst =>
						if (mcu_data_out(0) = '1') then
							TDACK <= TDRQ;
						end if;
						if (mcu_data_out(1) = '1') then
							CMDACK <= CMDRQ;
						end if;
					when mmu_dfr => 
						df_reg <= mcu_data_out(3 downto 0);
					when mmu_cmp => 
						CMRD <= '1';
					when mmu_xch =>
						td_chan <= to_integer(unsigned(mcu_data_out));
						TXI <= true;
					when mmu_saddr =>
						sd_addr <= mcu_data_out(smem_addr_len-1 downto 0);
					when mmu_sacc =>
						TDRSTACC <= mcu_data_out(0);					
						TDWRSM <= mcu_data_out(1);
						TDBSY <= (mcu_data_out(2) = '1');
					when mmu_i2c00 => 
						SDA <= '0';
						SCL <= '0';
					when mmu_i2c01 =>
						SDA <= '0';
						SCL <= '1';
					when mmu_i2cA0 => 
						if (mcu_data_out(7) = '0') then
							SDA <= '0';
						else
							SDA <= 'Z';
						end if;
						SCL <= '0';
					when mmu_i2cA1 =>
						if (mcu_data_out(7) = '0') then
							SDA <= '0';
						else
							SDA <= 'Z';
						end if;
						SCL <= '1';
					when mmu_i2cZ0 => 
						SDA <= 'Z';
						SCL <= '0';
					when mmu_i2cZ1 => 
						SDA <= 'Z';
						SCL <= '1';
						i2c_in(7 downto 1) <= i2c_in(6 downto 0);
						i2c_in(0) <= SDA;
					when others => 
						null;
					end case;
				end if;
			end if;
		end if;
	end process;

-- The Message Transmitter responds to Transmit Initiate (TXI) by turning on the 
-- radio-frequency oscillator, reading sixteen bits from one of the sensors and
-- transmitting the bits. The process runs off TCK, which is FCK divided by two,-- so FCK must be running.
	Message_Transmitter : process (all) is
		variable chan_num, set_num, completion_code : 
			natural range 0 to 15; -- set number for data
		constant num_sync_bits : natural := 11; -- Num synchronizing bits at start.
		constant num_id_bits : natural := 4; -- Number of ID bits.
		constant num_start_bits : natural := 1; -- Num zero start bits.
		constant num_stop_bits : natural := 2; -- For state machine termination only.
		constant num_data_bits : natural := 16; -- Number of ADC data bits.
		constant num_xmit_bits : natural := -- Number of transmission bit periods.
			num_sync_bits + num_start_bits + num_id_bits + num_data_bits + num_id_bits; 
		constant mt_idle : natural := 0; -- Idle state value.
		constant first_sync_bit : natural := 1; -- First transmit state.
		constant first_start_bit : natural := first_sync_bit + num_sync_bits;
		constant first_id_bit : natural := first_start_bit + num_start_bits;
		constant first_data_bit : natural := first_id_bit + num_id_bits;
		constant first_cc_bit : natural := first_data_bit + num_data_bits;
		constant mt_done : natural := -- Final state of sample transmit machine.
			num_xmit_bits + num_stop_bits; 
		variable chan_bits : nibble_type;
		variable cc_bits : nibble_type;
		variable state, next_state : natural range 0 to 63; -- Stample Transmit State
	begin
		-- The channel number, set number, and completion code are a function of the 
		-- device id and the channel offset, which we calculate here.
		chan_num := td_chan mod 16;
		set_num := td_chan / 16;
		completion_code := (15 - chan_num + set_num) mod 16;
		chan_bits := nibble_type(to_unsigned(chan_num,4));
		cc_bits := nibble_type(to_unsigned(completion_code,4));		
		-- Upon startup, we make sure we are in the idle state.
		if (RESET = '1') then 
			state := 0;
			TXA <= false;
		elsif rising_edge(TCK) then
			-- The process starts when we assert TXI. We move through all 
			-- subsequent states until we reach the final state, where we 
			-- wait until TXI is un-asserted for our return to the idle state. 
			case state is
				when mt_idle => 
					if TXI then
						next_state := 1;
					else
						next_state := 0;
					end if;
				
				when mt_done =>
					if not TXI then
						next_state := mt_idle;
					else
						next_state := mt_done;
					end if;
				
				when others =>
					next_state := state + 1;
			end case;
		
			-- The data bit is the outgoing bit value for transmission of the sensor signal.
			TXB <= ((state >= 0) and (state < first_start_bit))
				or ((state = first_id_bit + 0) and (chan_bits(3) = '1'))
				or ((state = first_id_bit + 1) and (chan_bits(2) = '1'))
				or ((state = first_id_bit + 2) and (chan_bits(1) = '1'))
				or ((state = first_id_bit + 3) and (chan_bits(0) = '1'))
				or ((state = first_data_bit) and (smem_data(17) = '1'))
				or ((state = first_data_bit + 1) and (smem_data(16) = '1'))
				or ((state = first_data_bit + 2) and (smem_data(15) = '1'))
				or ((state = first_data_bit + 3) and (smem_data(14) = '1'))
				or ((state = first_data_bit + 4) and (smem_data(13) = '1'))
				or ((state = first_data_bit + 5) and (smem_data(12) = '1'))
				or ((state = first_data_bit + 6) and (smem_data(11) = '1'))
				or ((state = first_data_bit + 7) and (smem_data(10) = '1'))
				or ((state = first_data_bit + 8) and (smem_data(9) = '1'))
				or ((state = first_data_bit + 9) and (smem_data(8) = '1'))
				or ((state = first_data_bit + 10) and (smem_data(7) = '1'))
				or ((state = first_data_bit + 11) and (smem_data(6) = '1'))
				or ((state = first_data_bit + 12) and (smem_data(5) = '1'))
				or ((state = first_data_bit + 13) and (smem_data(4) = '1'))
				or ((state = first_data_bit + 14) and (smem_data(3) = '1'))
				or ((state = first_data_bit + 15) and (smem_data(2) = '1'))
				or ((state = first_cc_bit + 0) and (cc_bits(3) = '1'))
				or ((state = first_cc_bit + 1) and (cc_bits(2) = '1'))
				or ((state = first_cc_bit + 2) and (cc_bits(1) = '1'))
				or ((state = first_cc_bit + 3) and (cc_bits(0) = '1'));
				
			-- TXA indicates that a transmission is on-going.
			TXA <= (state /= mt_idle) and (state /= mt_done);
			
			-- Assert the next state value.
			state := next_state;
		end if;
	end process;

-- With XEN we enable the VCO. We assert XEN while Transmit Active (TXA) or 
-- Transmit Warm-Up (TXWP), but only if not Command Processor Receive (CPRCV).
	XEN <= to_std_logic((not CMDRCV) and (TXA or TXWP));
			
-- The Frequency Modulation process takes the transmit bit values provided by
-- the Message Transmitter, turns them into a sequence of rising and falling
-- edges so as to balance the ratio of HI and LO, and modulates the transmit DAC
-- output (xdac) between the HI and LO frequency values. These values are turned
-- into analog voltages on the TUNE input of the radio frequency oscillator, and
-- so modulate the frequency of the transmission.
	Frequency_Modulation : process (all) is
	begin
		if RESET = '1' then
			xdac <= (others => '0');
			FHI <= false;
			
		-- Frequency modulation runs off the 10-MHz FCK clock. This clock is
		-- synchronous with TCK. It presents a rising edge over 10 ns after 
		-- both the rising and falling edges of TCK. Thus, when we see a
		-- rising edge on FCK, the value of TCK and TXB are both established.
		elsif rising_edge(FCK) then
		
			-- When we are not transmitting RF power, we set the DAC output to
			-- zero so as to eliminate current consumption by the DAC resistors.
			if not TXA then
				xdac <= (others => '0');
				FHI <= false;
				
			-- If TXB is asserted, we want the modulation frequency to go from low
			-- to high on the falling edge of TCK. When TXB is unasserted, we want
			-- the modulation frequency to go from high to low on the falling edge of
			-- TCK.
			elsif (TXB xor (TCK = '1')) then
				xdac <= std_logic_vector(to_unsigned(
					frequency_low + frequency_step,5));
				FHI <= true;
			else
				xdac <= std_logic_vector(to_unsigned(
					frequency_low,5));
				FHI <= false;
			end if;
		end if;
	end process;
	
-- The Receive Power signal must be synchronized with the RCK clock.
	Synchronize_RP: process (all) is 
	begin
		if RESET = '1' then
			RPS <= false;
		elsif rising_edge(RCK) then
			RPS <= (RP = '1');
		end if;
	end process;
	
-- We detect a long enough burst of command power to initiate
-- command reception, and set the ICMD signal.
	Initiate_Command: process (all) is 
		constant endcount : natural := 2;
		variable counter : natural range 0 to 3;
	begin
		if (not RPS) then
			ICMD <= false;
			counter := 0;
		elsif rising_edge(MCK) then
			if (counter = endcount) then 
				counter := endcount;
				ICMD <= true;
			else 
				counter := counter + 1;
				ICMD <= false;
			end if;
		end if;
	end process;
	
-- We detect a long enough period without command power to 
-- terminate command reception, and set the TCMD signal.
	Terminate_Command: process (all) is 
		constant endcount : natural := 7;
		variable counter : natural range 0 to 7;
	begin
		if RPS then
			counter := 0;
			TCMD <= false;
		elsif rising_edge(MCK) then
			if (counter = endcount) then 
				counter := endcount;
				TCMD <= true;
			else 
				counter := counter + 1;
				TCMD <= false;
			end if;
		end if;
	end process;
	
-- The Receive Command (RCMD) signal indicates that a command is being 
-- received. We set RCMD when Initiate Command (ICMD) occurs, and we clear
-- RCMD when Terminate Command (TCMD) occurs.
	Receive_Command: process (all) is
	begin
		if RESET = '1' then
			RCMD <= false;
		elsif rising_edge(RCK) then
			if not RCMD then
				RCMD <= ICMD;
			else 
				RCMD <= not TCMD;
			end if;
		end if;
	end process;

-- We watch for a start bit and receive serial bytes when instructed
-- to do so by the Command Processor with the RBI signal. The command
-- bytes arrive at 8192 bps. We use RCK, which is 32.768 kHz to detect
-- the rising edge of a start bit and then sample the center of the
-- subsequent bits to obtain a byte.
	Byte_Receiver: process (all) is
		constant end_state : natural := 39;
		variable state, next_state : natural range 0 to end_state;
	begin
		if RESET = '1' then
			state := 0;
			RBD <= false;
		elsif rising_edge(RCK) then
			-- By default, go to the idle state.
			next_state := 0;
		
			-- Idle state, waiting for Receive Byte Initiate.
			if (state = 0) then
				if RBI and (not RPS) then 
					next_state := 1;
				else 
					next_state := 0;
				end if;
			end if;
			
			-- Wait for a start bit. If we wait long enough, we will see the 
			-- termination signal, in which case we abort and wait for not RPI.
			if (state = 1) then
				if TCMD then 
					next_state := end_state; 
				else 
					if RPS then 
						next_state := 2;
					else 
						next_state := 1; 
					end if;
				end if;
			end if;
			
			-- Once we have a start bit, we proceed through the eight bits of
			-- a command byte, each bit taking four states. The first bit occurs
			-- at state 7 and the stop bit at state 39.
			if (state >= 2) and (state <= 38) then 
				next_state := state + 1; 
			end if;

			-- In the end state, we assert Receive Byte Done and we wait for the 
			-- command processor to un-assert Receive Byte Initiate. When we see not 
			-- RBI, we return to the idle state and unassert RBD. When we see 
			-- Terminate Command (TCMD) we unassert RBD.
			if (state = end_state) then 
				if not RBI then 
					next_state := 0; 
				else 
					next_state := end_state; 
				end if;
			end if;
			RBD <= (state = end_state) and (not TCMD);
					
			-- The eight bits of the command are set every four states during
			-- the command reception.
			for i in 0 to 7 loop
				if (state = 35 - i * 4) then 
					if RPS then 
						cmd_in(i) <= '1'; 
					else 
						cmd_in(i) <= '0'; 
					end if;
				end if;
			end loop;
			
			-- We assert Command Bit Strobe (CBS) one RCK period before the best moment
			-- to sample each bit value.
			if (state = 34) or (state = 30) or (state = 26) or (state = 22) 
				or (state = 18) or (state = 14) or (state = 10) or (state = 6) then
				CBS <= true;
			else 
				CBS <= false;
			end if;
			
			-- The Byte Strobe signal indicates that we have a start bit and is 
			-- useful as a test point trigger. It provides a pulse of two RCK 
			-- periods.
			BYTS <= (state = 2) or (state = 3);	

			-- Assert the new state.
			state := next_state;
			
		end if;
	end process;

-- This process runs all the bits of a command through a sixteen-bit linear 
-- feedback shift register, with local name "crc" for "cyclic redundancy check". 
-- We preset crc to all ones. The final sixteen bits of every command are chosen 
-- so that they reset the crc register to all zeros. If crc is not zero at the 
-- end of a command, there was some error during reception. We use the Command
-- Bit Strobe (CBS) signal to clock crc, because CBS is asserted only when a command 
-- data bit is received, not when we receive a start or stop bit.
	Error_Check : process (all) is
		variable crc, next_crc : std_logic_vector(15 downto 0);
	begin
		if RESET = '1' then
			crc := (others => '1');
		elsif rising_edge(RCK) then
			if ICMD then
				-- When a new command transmission starts, we preload the cyclic redundancy
				-- check register to all ones.
				crc := (others => '1');
			else
				-- We use Command Bit Strobe (CBS) to clock each command bit into the CRC.
				-- The transmitter calculates the checksum with zeros in the last
				-- sixteen bits, reverses the order of these checksum bits, and sends
				-- them as the last two bytes of the actual transmission, instead of the
				-- zeros it used when it calculated its own checksum. These last sixteen
				-- bits, thus obtained, will reset the receiver CRC to zero, provided there
				-- has been no corruption of the data on the way.
				if CBS then
					for i in 0 to 9 loop next_crc(i) := crc(i+1); end loop;
					next_crc(10) := crc(11) xor crc(0);
					next_crc(11) := crc(12);
					next_crc(12) := crc(13) xor crc(0);
					next_crc(13) := crc(14) xor crc(0);
					next_crc(14) := crc(15);
					next_crc(15) := to_std_logic(RPS) xor crc(0);	
					crc := next_crc;
				end if;		
			end if;
		end if;
		
		-- The CRCERR flag tells us when the CRC is not zero. It will be zero when it
		-- has been reset by the two bytes of a correct checksum.
		CRCERR <= (crc /= x"0000");
	end process;

-- The Command Memory First-In First-Out (FIFO) Buffer. We clock bytes into the buffer
-- on the rising edge of RCK and out of the buffer on the falling edge. Writes are 
-- enabled by CMWR and reads are enabled by CMRD. We use separate edges because this is,
-- in experience, safer when operating EBR buffers. We use the falling edge for reading
-- because doing so simplifies the Command Processor: if we assert CMRD in one processor
-- state, the byte read will be available for testing in the next state. We configure
-- the FIFO so that its AlmostEmpty flag is asserted when there are two or fewer bytes
-- left in the buffer. Thus, when we have no more instruction bytes left, and only the
-- two CRC bytes, the Command Memory Empty (CME) flag will be asserted by AlmostEmpty
-- and we will stop processing the command. The Full flag is asserted when the buffer
-- is a few bytes from full, so Command Memory Full (CMF) indicates an overflow and
-- is cause for aborting processing.
	Command_Memory : entity CMDMEM port map (
		Reset => CMRST, 
		RPReset => '0',
		WrClock => RCK,
		WrEn => CMWR,
		Data => cmd_in,
		RdClock => not PCK,
		RdEn => CMRD,
		AlmostEmpty => CME,
		Full => CMF,
		Q => cmd_out);
	
-- The Command Processor detects Inititiate Command (ICMD) and activates the Byte Receiver. 
-- It stores command bytes in the Command Memory until it detects Terminate Command (TCMD). If
-- the Error Check reports no error, the processor proceeds to read the instructions of the
-- command out of the command memory and execute them. 
	Command_Processor: process (all) is
		
		-- General-purpose state names for the Command Processor
		constant idle_s : natural := 0;
		constant receive_cmd_s : natural := 1;
		constant store_cmd_s : natural := 2;
		constant check_full_s : natural := 3;
		constant check_cmd_s : natural := 4;
		constant complete_s : natural := 5;
		
		-- Variables and constants for the Command Processor
		variable state, next_state : natural range 0 to 5;
		
	begin
		-- Reset to the idle state on global RESET.
		if (RESET = '1') then
			state := idle_s;
			CMRST <= '1';
			CMDRQ <= false;
			
		-- The Command Processor state machine runs off RCK, which allows 
		-- it to work with the Byte Receiver.
		elsif rising_edge(RCK) then
			next_state := idle_s;
			CMRST <= '0';
			RBI <= false;
			CMWR <= '0';
		
			-- Idle State.
			if (state = idle_s) then
				if ICMD then 
					next_state := receive_cmd_s; 
				else 
					next_state := idle_s;
				end if;
				CMRST <= '1';
			end if;
			
			-- Receive a command byte. We assert RBI and wait for RBD. If we see 
			-- Terminate Command (TCMD), we move on. Note that the Byte Receiver 
			-- aborts on TCMD also.
			if (state = receive_cmd_s) then 
				if TCMD then 
					next_state := check_cmd_s;
				else 
					if RBD then 
						next_state := store_cmd_s;
					else 
						next_state := receive_cmd_s;
					end if;
				end if;
				RBI <= true;
			end if;
			
			-- Store the new command byte in the command memory. We assert 
			-- Command Memory Write (CMWR) for one clock cycle.
			if (state = store_cmd_s) then 
				next_state := check_full_s;
				CMWR <= '1';
			end if;
			
			-- Check if the Command Memory is full. If so, abort. Otherwise, we 
			-- wait for RBD to be unasserted before receiving the next command 
			-- byte.
			if (state = check_full_s) then
				if (CMF = '1') then
					next_state := idle_s;
				elsif not RBD then
					next_state := receive_cmd_s;
				else
					next_state := check_full_s;
				end if;
			end if;		
			
			-- There are two possible sources of error: a failure in the cyclic 
			-- redundancy check (CRCERR) or an empty command memory (CME). If 
			-- either of these are asserted, we go back to idle and discard the 
			-- command. Whether the command is valid or not, we assert CMRD to 
			-- clock the first byte out of the command memory FIFO. 
			if (state = check_cmd_s) then
				if CRCERR or (CME = '1') then 
					next_state := idle_s;
				else 
					next_state := complete_s;
					CMDRQ <= not CMDRQ;
				end if;
			end if;

			-- We have a completed command in memory, waiting for the CPU to read it out.
			-- We assert CMDRDY and wait until the CPU asserts CPRST. The command processor
			-- will ignore any further command transmission.
			if (state = complete_s) then
				if (CMDRQ xor CMDACK) then
					next_state := complete_s;
				else
					next_state := idle_s;
				end if;
			end if;

			-- Advance the state variable.
			state := next_state;
		end if;
		
		CMDRCV <= (state > idle_s) and (state < complete_s);
	end process;
	
	TP <= to_std_logic(CMDRQ);
end behavior;