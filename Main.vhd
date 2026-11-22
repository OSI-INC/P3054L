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
-- into 640 LUTs with 2 EBR, as in the LXMCO2-640ZE.


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
-- Configuration of the Ring Oscillator
	constant fck_num_feeds : integer := 8;
	constant fck_num_gates : integer := 24;
	constant fck_mask : std_logic_vector(fck_num_feeds-1 downto 0) := "01000000";

-- Configuration and Calibration of Transmitter.
	constant tx_channel_default : integer := 1;
	constant frequency_step : integer := 1; 
	constant frequency_low : integer := 6;
	
-- Configuration of the Telemetry Manager
	constant TMRUN : boolean := true; -- Run the Telemetry Protocol
	constant tx_period : integer := 8; -- Shortest Period of All Signals
	
-- Sample and Accumulate Constants
	constant X1SKIP : boolean := false;
	constant X2SKIP : boolean := false;
	constant X3SKIP : boolean := false;
	constant X4SKIP : boolean := false;
	constant x1_sel : std_logic_vector(1 downto 0) := "00";
	constant x2_sel : std_logic_vector(1 downto 0) := "01";
	constant x3_sel : std_logic_vector(1 downto 0) := "10";
	constant x4_sel : std_logic_vector(1 downto 0) := "11";
	constant x1_channel : integer := 1;
	constant x2_channel : integer := 18;
	constant x3_channel : integer := 35;
	constant x4_channel : integer := 52;	
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
-- makes the ring oscillator period vary from one compile to the next.
	signal TCK, FCK, FCKEN : std_logic;
	attribute syn_keep of TCK, FCK, FCKEN : signal is true;
	attribute nomerge of TCK, FCK, FCKEN : signal is ""; 

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
	signal SMWRADC, -- Sample Memory Write by ADC Controller
		SMWRTD, -- Sample Memory Write by Telemetry Dispatcher
		ACCADD, -- Accumulator Add
		ACCRST -- Accumulator Reset
		: std_logic;
	signal smem_data, acc_data : std_logic_vector(17 downto 0);
	signal smem_addr, sample_sel : std_logic_vector(1 downto 0);

-- ADC Controller.
	signal ADCCAL, -- Calibrate the Selected ADC
		ADCRD, -- Initiate ADC Read
		ADCBSY -- ADC Busy
		: boolean := false;
	signal adc_data : std_logic_vector(17 downto 0);
	signal adc_sel : std_logic_vector(1 downto 0);

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
		
-- I2C Bus Controller
	signal i2c_in : std_logic_vector(7 downto 0); -- I2C Serial Byte
	
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
-- and RESET set HI. When RCK starts up, we us the falling edge to move the 
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
			
			if (state < stdby_state) then state := state + 1;
			elsif (SFLAG = '0') then state := stdby_state;
			elsif (state < end_state) then state := state + 1; 
			else state := end_state; end if;
		end if;
	end process;	

-- The Fast Clock process produces FCK when one of several flags are asserted.
-- The ring oscillator should be calibrated so that it produces FCK of 10 MHz.
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
			
-- The Telemetry Manager organizes sampling of the inputs X1-X4 at
-- frequency that is an integer fraction of 1024 SPS and generates
-- the transmit interrupt offset from sampling by a random number
-- of RCK periods. The manager runs off RCK, but the Sample
-- Controller and Telemetry Dispatcher that it manages run off
-- FCK. In the manager's sample state, the manager unasserts Sample
-- Controller Reset (SCRST) so that the Sample Controller can come out 
-- of reset on the next rising edge of FCK. The manager also toggles 
-- Sample Controller Request (SCRQ) so as to request that FCK start up.
-- The Sample Controller will set SCACK equal to SCRQ when it has finished 
-- sampling. The manager enables FCK when SCRQ and SCACK are not equal. 
-- This interaction between two processes, one running on RCK and one on 
-- FCK works provided that the Sample Controller runs on the rising edge 
-- of FCK and toggles SCACK on the falling edge. 
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
    elsif rising_edge(RCK) then
        if not TMRUN then
            next_state := tm_idle;
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
-- the sum of up to sixteen fourteen-bit ADC samples. The sample 
-- memory runs off the fast clock to work well with the Sample 
-- Controller, which also runs on fast clock.
	Sample_Memory : entity SMRAM port map (
		Clock => not FCK,
		ClockEn => '1',
 		WE => SMWRADC or SMWRTD,
		Address => smem_addr, 
		Data => acc_data,
		Q => smem_data);
	
-- The Sample Memory Address Multiplexer sets the sample memory 
-- address equal to adc_sel when the ADC Controller is busy, and
-- sample_sel otherwise. The former is incremented by the Sample 
-- Controller as it steps through the ADCs performing samples. The
-- latter is set by the CPU with a write to the sample memory
-- address register.
	Sample_Addr_Mux : process (all) is 
	begin
		if SCBSY then
			smem_addr <= adc_sel;
		else
			smem_addr <= sample_sel;
		end if;
	end process;
		
-- The Sample Accumulator adds newly-acquired ADC samples, which have
-- been shifted left from zero to four places, to an existing eighteen
-- bit sample memory value.
	Sample_Accumulator : entity SMADD port map (
		DataA => adc_data,
		DataB => smem_data,
		Result => acc_data,
		Clock => not FCK,
		ClockEn => ACCADD,
		Reset => ACCRST
	);

-- The Sample Controller organizes sampling of all four inputs X1-X4 using
-- the four converters ADC1-ADC4. It runs off FCK. It starts running when
-- it sees the ACRUN flag set. It will not return to its idle state until
-- this flag is cleared. It obtains a sample from each ADC for which the
-- skip flag is clear. The controller latches the state of the four skip
-- flags when it is idle. The latching of these flags is essential. If we
-- do not latch them, the firmware will freeze occasionally on RESET.
-- The controller sets adc_sel to match each ADC in turn.
Sample_Controller : process (FCK) is
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

-- ADC Controller starts reading one of the 14-bit ADCs when it detects 
-- ADC Read (ADCRD). It waits until ADCRD is unasserted before returning
-- to its rest state. When the controller has acquired the 14-bit sample,
-- it updates the transmit time shift value using a linear shift 
-- register that will, if the ADC is working properly, generate a random
-- number for transmit scatter. After that, the controller shifts 14-bit 
-- samples to the left from zero to four place, as directed by adc_shift. 
-- After shifting, the controller adds the sample to the accumulator, and 
-- writes the output of the accumulator to the sample memory. The ADC it 
-- selects for readout is the one specified by adc_sel. If ADCRD is 
-- accompanied by ADCCAL, the ADC Controller performs a calibration read 
-- of twenty-four bits, with no shifting, no accumulation, and no storage. 
-- This calibration read will cause the ADC to self-calibrate provided 
-- that the calibration access is the first one after power-up. 
ADC_Controller : process (RESET, FCK) is
    variable state, next_state : integer range 0 to 63 := 0;
    constant calib_end : integer := 50;
    constant read_end : integer := 40;
	variable adc_shift : integer := 0;
begin
	-- Calculate the number of left shifts we should apply to each ADC
	-- sample before storing in the sample memory.
	if (tx_period = 1) then
		adc_shift := 4;
	elsif (tx_period = 2) then
		adc_shift := 3;
	elsif (tx_period = 4) then
		adc_shift := 2;
	elsif (tx_period = 8) then
		adc_shift := 1;
	elsif (tx_period = 16) then
		adc_shift := 0;
	else
		adc_shift := 0;
	end if;

    -- Upon startup, make sure we are in the idle state.
    if (RESET = '1') then
        state := 0;
        ADCBSY <= false;
        ACCADD <= '0';
        SMWRADC <= '0';
        adc_data <= (others => '0');
        transmit_shift <= (others => '1');

    -- The ADC Controller initiates a conversion and reads
    -- one zero, fourteen data bits, and three trailing zeros.
    -- Calibration reads have nine trailing zeros instead.
    elsif falling_edge(FCK) then

        -- Shared state-counter logic.
        if (state = 0) then
            if ADCRD then
                next_state := 1;
            else
                next_state := 0;
            end if;
        elsif ((state = read_end) and (not ADCCAL))
            or ((state = calib_end) and ADCCAL) then
            next_state := 0;
        else
            next_state := state + 1;
        end if;

        -- Acquire ADC data.
        if ADCCAL then
            adc_data <= (others => '0');
        else
            if (state = 1) then
                adc_data <= (others => '0');
            end if;

            -- Read fourteen ADC data bits.
            if (state >= 4) and (state <= 30)
                and ((state mod 2) = 0) then
                adc_data(17 downto 1) <= adc_data(16 downto 0);
                adc_data(0) <= SDO;
            end if;

            -- Programmable left shift, zero to four places.
            if ((state = 32) and (adc_shift >= 1))
                or ((state = 34) and (adc_shift >= 2))
                or ((state = 36) and (adc_shift >= 3))
                or ((state = 38) and (adc_shift >= 4)) then
                adc_data(17 downto 1) <= adc_data(16 downto 0);
                adc_data(0) <= '0';
            end if;
        end if;

        -- Shared SCK generation for normal and
        -- calibration reads.
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
                adc_data(0) xor transmit_shift(0);
            transmit_shift(2) <=
                transmit_shift(3) xor transmit_shift(0);
            transmit_shift(1) <= transmit_shift(2);
            transmit_shift(0) <= transmit_shift(1);
        end if;

        -- Accumulator and sample-memory control.
        ACCADD <= to_std_logic((state = read_end - 1) and (not ADCCAL));
        SMWRADC <= to_std_logic((state = read_end) and (not ADCCAL));

        -- ADC busy flag.
		ADCBSY <=
			(state > 0)
			and (state < calib_end)
			and (ADCCAL or (state < read_end));

        state := next_state;
    end if;

    -- Select the ADC using the top two bits
    -- of the sample address.
    NADC1 <= to_std_logic(not (ADCBSY and (adc_sel = x1_sel)));
    NADC2 <= to_std_logic(not (ADCBSY and (adc_sel = x2_sel)));
    NADC3 <= to_std_logic(not (ADCBSY and (adc_sel = x3_sel)));
    NADC4 <= to_std_logic(not (ADCBSY and (adc_sel = x4_sel)));
end process;

-- The Telemetry Dispatcher runs off FCK and is reset by TDRST.
-- It transmits four channels in sequence, clearing each accumulator 
-- after transmission. The channel index replaces four separate copies 
-- of the transmit, wait, and clear state sequences.
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
    elsif rising_edge(FCK) then
        ACCRST <= '0';
        SMWRTD <= '0';
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
            ACCRST <= '1';
            SMWRTD <= '1';
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
            sample_sel <= x1_sel;
            tx_channel <= x1_channel;
        else
            case channel_index is
                when 0 =>
                    sample_sel <= x1_sel;
                    tx_channel <= x1_channel;
                when 1 =>
                    sample_sel <= x2_sel;
                    tx_channel <= x2_channel;
                when 2 =>
                    sample_sel <= x3_sel;
                    tx_channel <= x3_channel;
                when others =>
                    sample_sel <= x4_sel;
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
-- transmitting the bits. The process runs off TCK, so the CPU must assert ENFCK
-- for the process to run. The TXI signal will be asserted for one period of CK
-- following a CPU write to the TXI location. Further writes to the same location
-- will be ignored until the Message Transmitter returns to its idle state.
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
		-- The channel number, set number, and comletion code are a function of the 
		-- device id and the channel offset, which we calculate here.
		channel_num := tx_channel mod 16;
		set_num := tx_channel / 16;
		completion_code := 15 - channel_num + set_num;
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

-- With XEN we enable the VCO. We assert XEN while the Message Transmitter is active,
-- provided that the Command Processor is not receiving a command. We also turn on
-- the VCO when the CPU asserts Transmit Warmup (TXWP). 
	XEN <= to_std_logic(TXA or TXWP);
			
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
	
	SDA <= '1';
	SCL <= '1';
	TP <= RP;
end behavior;