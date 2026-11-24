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

-- V2.4 [23-NOV-26]


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
	constant device_id : std_logic_vector(15 downto 0) := x"AA55";
	constant wildcard_id : std_logic_vector(15 downto 0) := x"FFFF";
-- Configuration of the Ring Oscillator
	constant fck_num_feeds : integer := 8;
	constant fck_num_gates : integer := 26;
	constant default_fck_mask : 
		std_logic_vector(fck_num_feeds-1 downto 0) := x"10";

-- Configuration and Calibration of Transmitter.
	constant tx_channel_default : integer := 1;
	constant frequency_step : integer := 1; 
	constant frequency_low : integer := 6;
	
-- Configuration of the Telemetry Manager
	constant TMRUN : boolean := true; -- Run the Telemetry Protocol
	constant tx_period : integer := 2; -- Shortest Period of All Signals
	
-- Sample and Accumulate Constants
	constant X1SKIP : boolean := false;
	constant X2SKIP : boolean := false;
	constant X3SKIP : boolean := false;
	constant X4SKIP : boolean := false;
	constant x1_sel : std_logic_vector(1 downto 0) := "00";
	constant x2_sel : std_logic_vector(1 downto 0) := "01";
	constant x3_sel : std_logic_vector(1 downto 0) := "10";
	constant x4_sel : std_logic_vector(1 downto 0) := "11";
	constant x1_pd : integer := 1;
	constant x2_pd : integer := 2;
	constant x3_pd : integer := 4;
	constant x4_pd : integer := 8;
	constant x1_shift : integer := 4;
	constant x2_shift : integer := 3;
	constant x3_shift : integer := 1;
	constant x4_shift : integer := 0;
	constant x1_channel : integer := 1;
	constant x2_channel : integer := 3;
	constant x3_channel : integer := 5;
	constant x4_channel : integer := 7;	
end;

architecture behavior of main is

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
	
-- Ring Oscillator, Fast Clock, and Transmit Clock. We retain all these signals
-- as nodes in the logic to stop the compiler from spreading them around, which
-- makes the ring oscillator period vary from one compile to the next. We want
-- the compiler to preserve the fck_mask bits or else FCK period will not be
-- always increasing with mask bit index.
	signal TCK, FCK, MCK, FCKEN : std_logic;
	signal fck_mask : std_logic_vector(fck_num_feeds-1 downto 0);
	attribute syn_keep of TCK, FCK, FCKEN, fck_mask : signal is true;
	attribute nomerge of TCK, FCK, FCKEN, fck_mask : signal is ""; 

-- Clock Control. 
	signal ENFCKTM : boolean; -- Enable Fast Clock, from Telemetry Manager
	signal SRCK, -- RCK Synchronized with FCK
		SSRCK -- SRCK Delayed by one FCK Period
		: std_logic; 
	attribute syn_keep of ENFCKTM : signal is true;
	attribute nomerge of ENFCKTM : signal is "";

-- Sample Controller
	signal SCRQ, -- Sample Controller Request
		SCRST, -- Sample Controller Reset
		SCACK, -- Sample Controller Acknowledge
		SCBSY -- Sample Controller Busy
		: boolean := false;

-- Telemetry Manager and Dispatcher
	signal TMCK, -- The Transmit Manager Clock
		TDRST, -- Telemetry Dispatcher Reset
		TDRQ, -- Telemetry Dispatcher Request
		TDACK -- Telemetry Dispatcher Acknowledge
		: boolean := false;
		
-- Sample Memory and Accumulator
	signal ADCWRSM, -- ADC Reader Writes to Sample Memory
		TDWRSM, -- Telemetry Dispatcher Writes to Sample Memory
		TDRSTACC -- Telemetry Dispatcher Resets Accumulator
		: std_logic;
	signal smem_data : std_logic_vector(17 downto 0); -- Sample Memory Output
	signal acc_data : std_logic_vector(17 downto 0); -- Accumulator Output
	signal sample_data : std_logic_vector(17 downto 0); -- Accumulator Input
	signal smem_addr : std_logic_vector(1 downto 0); -- Sample Memory Addr
	signal tx_sel : std_logic_vector(1 downto 0); -- Sample Selector

-- ADC Controller and ADC Reader
	signal ADCCAL, -- Calibrate the Selected ADC
		ADCRD, -- Initiate ADC Read
		ADCBSY, -- ADC Busy
		ADCSHSD -- ADC Reader Shifts Sample Data
		: boolean := false;
	signal ADCBIT, -- ADC Bit for Sample Data
		ADCADD -- ADC Reader Requests Addition
		: std_logic;
	signal adc_sel : std_logic_vector(1 downto 0); -- ADC Selector

-- Message Transmission. The syn_keep and nomerge reduce code size slightly.
	signal TXI, -- Transmit Initiate
		TXWP, -- Transmit Warmup
		TXA, -- Transmit Active
		TXB, -- Transmit Bit
		FHI -- Frequency High
		: boolean := false;
	attribute syn_keep of TXI, TXA : signal is true;
	attribute nomerge of TXI, TXA : signal is "";  
	signal tx_channel : integer range 0 to 255;
	signal transmit_shift : std_logic_vector(3 downto 0);
		
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
	
-- Command Memory
	signal cmd_in : std_logic_vector(7 downto 0); -- Command Memory Data In
	signal cmd_out : std_logic_vector(7 downto 0); -- Command Memory Data Out
	signal CME, -- Command Memory Empty
		CMF, -- Command Memory Full
		CMRST, -- Command Memory Reset
		CMWR,  -- Command Memory Write
		CMRD -- Command Memory Read
		: std_logic; 

-- Command Processor
	signal CPA -- Command Processor Active
		: boolean := false;
	signal target_id_hi : std_logic_vector(7 downto 0);
	
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
	PowerUp: process (RCK) is
		constant end_state : integer := 7;
		constant clr_state : integer := 3;
		constant stdby_state : integer := clr_state + 2;
		variable state : integer range 0 to end_state := 0;
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
-- calibrated so that it produces FCK of 10 MHz.
	FCKEN <= to_std_logic(ENFCKTM);
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
		
-- The Transmit Clock is FCK divided by two.
	Transmit_Clock : process (FCK) is
	begin
		if falling_edge(FCK) then
			TCK <= not TCK;
		end if;
	end process;
			
-- The Millisecond Clock takes RCK, which is 32.768 kHz and divides
-- by 32 to get 1.024 kHz, which we use as our millisecond clock.
	Millisecond_Clock : process (RCK) is
		variable mcnt : integer range 0 to 31;
	begin
		if RESET = '1' then
			mcnt := 0;
		elsif falling_edge(RCK) then
			mcnt := mcnt + 1;
			if (mcnt <= 15) then
				MCK <= '0';
			else
				MCK <= '1';
			end if;
		end if;	
	end process;
		
-- The Telemetry Manager starts the Sample Controller regularly at 1024 Hz
-- and starts the Telemetry Dispatcher irregularly at 1024 Hz / tx_period,
-- where tx_period must be 1, 2, 4, 8, or 16. The Sample Controller will 
-- sample, shift, and store all enabled intputs. The Telemetry Dispatcher 
-- will transmit all enabled inputs. We say "irregularly" because the 
-- moment the dispatcher is started is shifted within the 1024 Hz period 
-- by 0-15 RCK periods so as to produce "transmission scatter", which is 
-- a requirement of our telemetry protocol. The Telemetry Manager runs off
-- RCK but the Sample Controller and the Telemetry Dispatcher run off 
-- FCK. Furthermore, the Telemetry Manager turns on FCK for these processes.
-- To perform the control of FCK we use toggle hand-shakes. We have SCRQ and
-- SCACK for the Sample Controller and TDRQ and TDACK for the Telemetry
-- Dispatcher. The signals are toggled rather than set, and their equality
-- turns on FCK. We also have SCRST and TDRST to reset the controller and
-- dispatcher.
	Telemetry_Manager : process (RCK) is
		constant tm_max : integer := 31;
		constant tm_idle : integer := tm_max;
		constant tm_update : integer := tm_max - 1;
		constant tm_sample : integer := tm_max - 2;
		variable state, next_state : integer range 0 to tm_max := 0;
		variable tx_index : integer range 0 to tx_period-1;
	begin
		if RESET = '1' then
			ENFCKTM <= false;
			SCRST <= true;
			SCRQ <= false;
			TDRQ <= false;
			TMCK <= false;
			state := tm_idle;
			tx_index := 0;
		elsif rising_edge(RCK) then
			if not TMRUN then
				next_state := tm_idle;
				tx_index := 0;
			else
				if state = tm_idle then
					next_state := 0;
				else
					next_state := state + 1;
				end if;
			end if;

			TMCK <= false;
			
			if (state = to_integer(unsigned(transmit_shift))) then
				if tx_index = 0 then
					TDRQ <= not TDRQ;
				end if;
			elsif (state = tm_sample) then
				SCRQ <= not SCRQ;
			elsif (state = tm_update) then
				SCRST <= true;
				TDRST <= true;
				if tx_index = 0 then
					TMCK <= true;
					tx_index := tx_period - 1;
				else
					tx_index := tx_index - 1;
				end if;
			elsif (state = tm_idle) then
				SCRST <= false;
				TDRST <= false;
				if not TMRUN then
					tx_index := tx_period - 1;
				end if;
			else
				SCRST <= false;
			end if;

			state := next_state;
		end if;

		ENFCKTM <= (SCRQ xor SCACK) or (TDRQ xor TDACK);
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
	Sample_Register : process (RESET, FCK) is
	begin
		if RESET = '1' then
			sample_data <= (others => '0');
		elsif falling_edge(FCK) then
			if ADCSHSD then
				sample_data(17 downto 1) <= sample_data(16 downto 0);
				sample_data(0) <= ADCBIT;
			end if;
		end if;
	end process;

-- The Sample Memory Address Multiplexer sets the sample memory 
-- address equal to the address specified by one of the 
-- sample-generating processes.
	Sample_Addr : process (all) is 
	begin
		if SCBSY then
			smem_addr <= adc_sel;
		else
			smem_addr <= tx_sel;
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

-- The ADC Controller organizes sampling of all four inputs X1-X4 using
-- the four converters ADC1-ADC4. It runs off FCK. It starts running when
-- it SCRST is unasserted and FCK is running. It will not return to its idle 
-- state until SCRST is asserted again. It indicates to the source of SCRST
-- that it has completed its sampling by toggling the SCACK signal. The 
-- controller obtains a sample from each ADC for which the skip flag is 
-- clear. It latches the state of the four skip flags when it is idle or else
-- the firmware will freeze occasionally on RESET. The controller sets adc_sel 
-- and adc_shift to match each ADC in turn. The controller does not perform
-- the sampling itself, but instead uses the ADC Reader to read out one of
-- the ADCs and initiate another conversion.
	ADC_Controller : process (FCK) is
		variable state, next_state : integer range 0 to 5 := 0;
		variable adc_index : integer range 0 to 3 := 0;
		variable X1SKIPL, X2SKIPL, X3SKIPL, X4SKIPL : boolean;
		variable skip_adc : boolean;
		constant sc_idle  : integer := 0;
		constant sc_check : integer := 1;
		constant sc_start : integer := 2;
		constant sc_adcw  : integer := 3;
		constant sc_done  : integer := 4;
		constant sc_wait  : integer := 5;
	 
	begin
		if RESET = '1' then
			SCACK <= false;
		elsif falling_edge(FCK) then
			if state = sc_wait then
				SCACK <= SCRQ;
			end if;
		end if;

		if RESET = '1' then
			ADCCAL <= true;
		elsif rising_edge(FCK) then
			if state = sc_done then
				ADCCAL <= false;
			end if;
		end if;

		if SCRST then
			ADCRD <= false;
			adc_sel <= x1_sel;
			state := sc_idle;
			adc_index := 0;
			X1SKIPL := X1SKIP;
			X2SKIPL := X2SKIP;
			X3SKIPL := X3SKIP;
			X4SKIPL := X4SKIP;
		elsif rising_edge(FCK) then
			ADCRD <= false;
			next_state := state;
			
			case adc_index is
				when 0 =>
					adc_sel <= x1_sel;
					skip_adc := X1SKIPL;
				when 1 =>
					adc_sel <= x2_sel;
					skip_adc := X2SKIPL;
				when 2 =>
					adc_sel <= x3_sel;
					skip_adc := X3SKIPL;
				when others =>
					adc_sel <= x4_sel;
					skip_adc := X4SKIPL;
			end case;

			case state is
				when sc_idle =>
					adc_index := 0;
					adc_sel <= x1_sel;
	 
					if SCRQ xor SCACK then
						next_state := sc_check;
					else
						next_state := sc_idle;
					end if;
				when sc_check =>
					if skip_adc then
						if adc_index = 3 then
							next_state := sc_done;
						else
							adc_index := adc_index + 1;
							next_state := sc_check;
						end if;
					else
						next_state := sc_start;
					end if;
				when sc_start =>
					ADCRD <= true;
					if ADCBSY then
						next_state := sc_adcw;
					else
						next_state := sc_start;
					end if;
				when sc_adcw =>
					if ADCBSY then
						next_state := sc_adcw;
					elsif adc_index = 3 then
						next_state := sc_done;
					else
						adc_index := adc_index + 1;
						next_state := sc_check;
					end if;
				when sc_done =>
					adc_sel <= x4_sel;
					next_state := sc_wait;
				when others =>
					adc_sel <= x4_sel;
					next_state := sc_wait;
			end case;

			state := next_state;
			SCBSY <= (state > sc_idle) and (state < sc_wait);
		end if;
	end process;

-- The ADC Reader starts reading one of the 14-bit ADCs when it detects 
-- ADC Read (ADCRD). It waits until ADCRD is unasserted before returning
-- to its rest state. When the reader has acquired a 14-bit sample,
-- it updates the transmit time shift value using a linear shift 
-- register that provides the transmit scatter random number needed by
-- the Telemetry Manager. The reader shifts 14-bit sample to the left 
-- from zero to four place, as directed by adc_shift. The reader adds
-- sample to the accumulator, and writes the output of the accumulator to 
-- the sample memory. If ADCRD is accompanied by ADCCAL, the reader 
-- performs a calibration read of twenty-four bits, with no shifting, no 
-- accumulation, and no storage. This calibration read will cause the 
-- ADC to self-calibrate provided that the calibration access is the 
-- first one after power-up. The reader runs off FCK.
	ADC_Reader : process (RESET, FCK) is
		variable state, next_state : integer range 0 to 63 := 0;
		constant calib_end : integer := 50;
		constant read_end : integer := 40;
		variable adc_shift : integer := 0;
	begin
		-- Calculate the number of left shifts we should apply to the ADC
		-- sample before passing it to the accumulator. 
		case adc_sel is
			when x1_sel => adc_shift := x1_shift;
			when x2_sel => adc_shift := x2_shift;
			when x3_sel => adc_shift := x3_shift;
			when x4_sel => adc_shift := x4_shift;
		end case;

		-- Upon startup, make sure we are in the idle state.
		if (RESET = '1') then
			state := 0;
			ADCBSY <= false;
			ADCADD <= '0';
			ADCWRSM <= '0';
			ADCBIT <= '0';
			ADCSHSD <= false;
			transmit_shift <= (others => '1');

		-- The reader initiates a conversion and reads one zero, 
		-- fourteen data bits, and three trailing zeros. Calibration 
		-- reads have nine trailing zeros instead.
		elsif falling_edge(FCK) then
			ADCSHSD <= false;

			-- Shared state-counter logic.
			if (state = 0) then
				if ADCRD then
					next_state := 1;
					ADCBIT <= '0';
					ADCSHSD <= true;
				else
					next_state := 0;
				end if;
			elsif ((state = read_end) and (not ADCCAL))
				or ((state = calib_end) and ADCCAL) then
				next_state := 0;
			else
				next_state := state + 1;
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
					sample_data(0) xor transmit_shift(0);
				transmit_shift(2) <=
					transmit_shift(3) xor transmit_shift(0);
				transmit_shift(1) <= transmit_shift(2);
				transmit_shift(0) <= transmit_shift(1);
			end if;

			-- Accumulator and sample-memory control.
			ADCADD <= to_std_logic((state = read_end - 1) and (not ADCCAL));
			ADCWRSM <= to_std_logic((state = read_end) and (not ADCCAL));

			-- ADC busy flag.
			ADCBSY <=
				(state > 0)
				and (state < calib_end)
				and (ADCCAL or (state < read_end));

			state := next_state;
		end if;

		-- Select the ADC using the top two bits of the sample address.
		NADC1 <= to_std_logic(not (ADCBSY and (adc_sel = x1_sel)));
		NADC2 <= to_std_logic(not (ADCBSY and (adc_sel = x2_sel)));
		NADC3 <= to_std_logic(not (ADCBSY and (adc_sel = x3_sel)));
		NADC4 <= to_std_logic(not (ADCBSY and (adc_sel = x4_sel)));
	end process;

-- The Telemetry Dispatcher runs off FCK and is reset by TDRST. It
-- arranges for transmission of four values stored in the sample memory.
-- It transmits four channels in sequence, ignoring the ADC disable-- flags. It ignores the individual transmit periods of the channels
-- as well. This dispatcher is a place holder for a more sophisticated
-- dispatcher coming later.
	Telemetry_Dispatcher : process (RESET, FCK) is
		variable state, next_state : integer range 0 to 5 := 0;
		variable channel_index : integer range 0 to 3 := 0;
		constant td_idle : integer := 0;
		constant td_tx   : integer := 1;
		constant td_wt   : integer := 2;
		constant td_clr  : integer := 3;
		constant td_done : integer := 4;
		constant td_wait : integer := 5;
	begin
		if RESET = '1' then
			TDACK <= false;
		elsif falling_edge(FCK) then
			if state = td_wait then
				TDACK <= TDRQ;
			end if;
		end if;

		if TDRST then
			state := td_idle;
			channel_index := 0;
			TDRSTACC <= '0';
			TDWRSM <= '0';
		elsif rising_edge(FCK) then
			TDRSTACC <= '0';
			TDWRSM <= '0';
			TXI <= false;
			next_state := td_wait;
			
			if (state = td_idle) and (TDRQ xor TDACK) then
				channel_index := 0;
				next_state := td_tx;
			elsif state = td_tx then
				TXI <= true;
				if TXA then
					next_state := td_wt;
				else
					next_state := td_tx;
				end if;
			elsif state = td_wt then
				if TXA then
					next_state := td_wt;
				else
					next_state := td_clr;
				end if;
			elsif state = td_clr then
				TDRSTACC <= '1';
				TDWRSM <= '1';
				if channel_index = 3 then
					next_state := td_done;
				else
					next_state := td_tx;
				end if;
			elsif state = td_done then
				next_state := td_wait;
			else
				next_state := td_wait;
			end if;

			-- Select the channel associated with the current
			-- state. In td_clr, preserve the old channel for
			-- the accumulator reset, then advance the index.
			if (next_state = td_wait) or
			   (state = td_done) then
				tx_sel <= x1_sel;
				tx_channel <= x1_channel;
			else
				case channel_index is
					when 0 =>
						tx_sel <= x1_sel;
						tx_channel <= x1_channel;
					when 1 =>
						tx_sel <= x2_sel;
						tx_channel <= x2_channel;
					when 2 =>
						tx_sel <= x3_sel;
						tx_channel <= x3_channel;
					when others =>
						tx_sel <= x4_sel;
						tx_channel <= x4_channel;
				end case;
			end if;

			if (state = td_clr) and (channel_index < 3) then
				channel_index := channel_index + 1;
			end if;

			state := next_state;
		end if;
	end process;

-- The Message Transmitter responds to Transmit Initiate (TXI) by turning on the 
-- radio-frequency oscillator, reading sixteen bits from one of the sensors and
-- transmitting the bits. The process runs off TCK, which is FCK divided by two,-- so FCK must be running.
	Message_Transmitter : process (RESET, TCK) is
		variable channel_num, set_num, completion_code : 
			integer range 0 to 15; -- set number for data
		constant num_sync_bits : integer := 11; -- Num synchronizing bits at start.
		constant num_id_bits : integer := 4; -- Number of ID bits.
		constant num_start_bits : integer := 1; -- Num zero start bits.
		constant num_stop_bits : integer := 2; -- For state machine termination only.
		constant num_data_bits : integer := 16; -- Number of ADC data bits.
		constant num_xmit_bits : integer := -- Number of transmission bit periods.
			num_sync_bits + num_start_bits + num_id_bits + num_data_bits + num_id_bits; 
		constant st_idle : integer := 0; -- Idle state value.
		constant first_sync_bit : integer := 1; -- First transmit state.
		constant first_start_bit : integer := first_sync_bit + num_sync_bits;
		constant first_id_bit : integer := first_start_bit + num_start_bits;
		constant first_data_bit : integer := first_id_bit + num_id_bits;
		constant first_cc_bit : integer := first_data_bit + num_data_bits;
		constant st_done : integer := -- Final state of sample transmit machine.
			num_xmit_bits + num_stop_bits; 
		variable channel_bits : std_logic_vector(3 downto 0);
		variable cc_bits : std_logic_vector(3 downto 0);
		variable state, next_state : integer range 0 to 63; -- Stample Transmit State
	begin
		-- The channel number, set number, and completion code are a function of the 
		-- device id and the channel offset, which we calculate here.
		channel_num := tx_channel mod 16;
		set_num := tx_channel / 16;
		completion_code := (15 - channel_num + set_num) mod 16;
		channel_bits := std_logic_vector(to_unsigned(channel_num,4));
		cc_bits := std_logic_vector(to_unsigned(completion_code,4));
		
		-- Upon startup, we make sure we are in the idle state.
		if (RESET = '1') then 
			state := 0;
			
		elsif rising_edge(TCK) then
			-- The process starts when we assert TXI. We move through all 
			-- subsequent states until we reach the final state, where we 
			-- wait until TXI is un-asserted for our return to the idle state. 
			case state is
				when st_idle => 
					if TXI then
						next_state := 1;
					else
						next_state := 0;
					end if;
				
				when st_done =>
					if not TXI then
						next_state := st_idle;
					else
						next_state := st_done;
					end if;
				
				when others =>
					next_state := state + 1;
			end case;
		
			-- The data bit is the outgoing bit value for transmission of the sensor signal.
			TXB <= ((state >= 0) and (state < first_start_bit))
				or ((state = first_id_bit + 0) and (channel_bits(3) = '1'))
				or ((state = first_id_bit + 1) and (channel_bits(2) = '1'))
				or ((state = first_id_bit + 2) and (channel_bits(1) = '1'))
				or ((state = first_id_bit + 3) and (channel_bits(0) = '1'))
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
			TXA <= (state /= st_idle) and (state /= st_done);
			
			-- Assert the next state value.
			state := next_state;
		end if;
	end process;

-- With XEN we enable the VCO. We assert XEN while Transmit Active (TXA) or 
-- Transmit Warm-Up (TXWP), but only if not Command Processor Active (CPA).
	XEN <= to_std_logic((not CPA) and (TXA or TXWP));
			
-- The Frequency Modulation process takes the transmit bit values provided by
-- the Message Transmitter, turns them into a sequence of rising and falling
-- edges so as to balance the ratio of HI and LO, and modulates the transmit DAC
-- output (xdac) between the HI and LO frequency values. These values are turned
-- into analog voltages on the TUNE input of the radio frequency oscillator, and
-- so modulate the frequency of the transmission.
	Frequency_Modulation : process (RESET, FCK) is
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
	Synchronize_RP: process (RESET, RCK) is 
	begin
		if RESET = '1' then
			RPS <= false;
		elsif rising_edge(RCK) then
			RPS <= (RP = '1');
		end if;
	end process;
	
-- We detect a long enough burst of command power to initiate
-- command reception, and set the ICMD signal.
	Initiate_Command: process (RPS, MCK) is 
		constant endcount : integer := 2;
		variable counter : integer range 0 to 3;
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
	Terminate_Command: process (RPS, MCK) is 
		constant endcount : integer := 7;
		variable counter : integer range 0 to 7;
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
	Receive_Command: process (RESET, RCK) is
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
	Byte_Receiver: process (RESET, RCK) is
		constant end_state : integer := 39;
		variable state, next_state : integer range 0 to end_state;
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
	Error_Check : process (RESET, RCK) is
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
	Command_Memory : entity CMD_FIFO port map (
		Reset => CMRST, 
		RPReset => '0',
		WrClock => RCK,
		WrEn => CMWR,
		Data => cmd_in,
		RdClock => not RCK,
		RdEn => CMRD,
		AlmostEmpty => CME,
		Full => CMF,
		Q => cmd_out);
	
-- The Command Processor detects Inititiate Command (ICMD) and activates the Byte Receiver. 
-- It stores command bytes in the Command Memory until it detects Terminate Command (TCMD). If
-- the Error Check reports no error, the processor proceeds to read the instructions of the
-- command out of the command memory and execute them. 
	Command_Processor: process (RESET, RCK) is
		
		-- General-purpose state names for the Command Processor
		constant idle_s : integer := 0;
		constant receive_cmd_s : integer := 1;
		constant store_cmd_s : integer := 2;
		constant check_fifo_s : integer := 3;
		constant check_cmd_s : integer := 4;
		constant read_id_hi_s : integer := 5;
		constant check_id_s : integer := 6;
		constant check_empty_s : integer := 7;
		constant interpret_opcode_s : integer := 8;
		constant set_fck_mask_s : integer := 9;
		
		-- Variables and constants for the Command Processor
		variable state, next_state : integer range 0 to 15;
		
	begin
		-- We reset to the idle state on global RESET.
		if (RESET = '1') then
			state := idle_s;
			CMRST <= '1';
			fck_mask <= default_fck_mask;
			
		-- The Command Processor state machine runs off RCK, which allows it to
		-- work with the Byte Receiver.
		elsif rising_edge(RCK) then
			next_state := idle_s;
			CMRST <= '0';
			RBI <= false;
			CMWR <= '0';
			CMRD <= '0';
			MSR <= '0';
		
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
			
			-- Store the new command byte in the command memory. We assert Command
			-- Memory Write (CMWR) for one clock cycle.
			if (state = store_cmd_s) then 
				next_state := check_fifo_s;
				CMWR <= '1';
			end if;
			
			-- Check if the Command Memory is full. If so, abort. Otherwise, we 
			-- wait for RBD to be unasserted before receiving the next command byte.
			if (state = check_fifo_s) then
				if (CMF = '1') then
					next_state := idle_s;
				elsif not RBD then
					next_state := receive_cmd_s;
				else
					next_state := check_fifo_s;
				end if;
			end if;		
			
			-- There are two possible sources of error: a failure in the cyclic 
			-- redundancy check (CRCERR) or an empty command memory (CME). If 
			-- either of these are asserted, we go back to idle and discard the 
			-- command. Whether the command is valid or not, we assert CMRD to clock 
			-- the first byte out of the command memory FIFO. 
			if (state = check_cmd_s) then
				if CRCERR or (CME = '1') then 
					next_state := idle_s;
				else 
					next_state := read_id_hi_s;
				end if;
				CMRD <= '1';
			end if;

			-- The first byte out of the FIFO is the top byte of the target device
			-- identifier. Save this so we can combine it with the low byte in the
			-- next step. Clock the next byte out of the FIFO.
			if (state = read_id_hi_s) then
				next_state := check_id_s;
				target_id_hi <= cmd_out;
				CMRD <= '1';
			end if;	
			
			-- Compare the target identifier with this device's identifier
			-- and the wildcard. If it matches either, we will proceed to
			-- decode the command. Otherwise, we return to the idle state.
			if (state = check_id_s) then
				if (target_id_hi & cmd_out) = device_id then
					next_state := check_empty_s;
				elsif (target_id_hi & cmd_out) = wildcard_id then
					next_state := check_empty_s;
				else
					next_state := idle_s;
				end if;
				CMRD <= '1';
			end if;
			
			-- If the command FIFO is empty, we are done, so go back to idle.
			if (state = check_empty_s) then
				if (CME = '1') then
					next_state := idle_s;
				else 
					next_state := interpret_opcode_s;
				end if;
			end if;
			
			-- Interpret the opcode at the output of the command memory. At the 
			-- same time, bring the next byte to the output of the memory.
			if (state = interpret_opcode_s) then
				CMRD <= '1';
				case to_integer(unsigned(cmd_out)) is 
					when 65 => next_state := set_fck_mask_s;
					when others => next_state := idle_s;
				end case;
			end if;
			
			-- Set the fck_mask.
			if (state = set_fck_mask_s) then
				CMRD <= '1';
				fck_mask <= cmd_out;
				next_state := check_empty_s;
			end if;

			-- Advance the state variable.
			state := next_state;
		end if;
		
		CPA <= (state /= idle_s);
	end process;

	SDA <= '1';
	SCL <= '1';
	TP <= to_std_logic(CPA);
end behavior;