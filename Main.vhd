-- A3054L Long-Life IPT Firmware, Top-Level Unit

-- V2.0 [28-OCT-26] Based upon P3054 V1.9. Creating long-life version.


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

-- Configuration and Calibration of Transmitter.
	constant tx_channel_default : integer := 1;
	constant frequency_step : integer := 1; 
	constant default_frequency_low : integer := 5;
		
-- Configuration of OSR8 CPU.
	constant mcu_addr_len : integer := 7;
	constant mcu_instr_len : integer := 12;
	constant start_pc : integer := 0;
	constant interrupt_pc : integer := 3;
	constant ram_addr_len : integer := 6;

-- Memory Map Constants, sizes and base addresses.
	constant ram_bot : integer := 16#0000#;
	constant ram_top : integer := 16#003F#;
	constant ctrl_bot  : integer := 16#0040#;
	constant ctrl_top  : integer := 16#007F#;
	
-- Memory Map Constants, low nibble addresses in units of bytes. When a location is
-- a control register shadowed in RAM, we say it is "Write/Readback". When writing to
-- a location initiates a process, we say it is "Write". When a location can be read
-- but not written, we say it is "Read".
	constant mmu_irqb  : integer := 16#00#; -- Interrupt Request Bits (Read)
	constant mmu_imsk  : integer := 16#01#; -- Interrupt Mask Bits (Write/Readback)
	constant mmu_irst  : integer := 16#02#; -- Interrupt Reset Bits (Write)
	constant mmu_acfg  : integer := 16#03#; -- Amplifier Configuration (Write/Readback)
	constant mmu_led   : integer := 16#04#; -- Lamp Switch (Write/Readback)
	constant mmu_rst   : integer := 16#05#; -- Software Reset (Write)
	constant mmu_xhb   : integer := 16#06#; -- Transmit HI Byte (Write/Readback)
	constant mmu_xlb   : integer := 16#07#; -- Transmit LO Byte (Write/Readback)
	constant mmu_xch   : integer := 16#08#; -- Transmit Channel Number (Write/Readback)
	constant mmu_xcr   : integer := 16#09#; -- Transmit Control (Write)
	constant mmu_rfc   : integer := 16#0A#; -- Radio Frequency Calibration (Write/Readback)	
	constant mmu_ccr   : integer := 16#0B#; -- Clock Control (Write/Readback)
	constant mmu_dfr   : integer := 16#0C#; -- Diagnostic Flags (Write/Readback)
	constant mmu_sr    : integer := 16#0D#; -- Status Register (Read)
	constant mmu_cmp   : integer := 16#0E#; -- Command Memory Portal (Read)
	constant mmu_cpr   : integer := 16#0F#; -- Command Processor Reset (Write)
	constant mmu_fck   : integer := 16#10#; -- Fast Clock Mask (Write/Readback)
	constant mmu_i0p   : integer := 16#11#; -- Interrupt Zero Period (Write/Readback)
	constant mmu_i2c00 : integer := 16#12#; -- i2c SDA=0 SCL=0 (Write/Readback)
	constant mmu_i2c01 : integer := 16#13#; -- i2c SDA=0 SCL=1 (Write/Readback)
	constant mmu_i2cA0 : integer := 16#14#; -- i2c SDA=A SCL=0 (Write/Readback)
	constant mmu_i2cA1 : integer := 16#15#; -- i2c SDA=A SCL=1 (Write/Readback)
	constant mmu_i2cZ0 : integer := 16#16#; -- i2c SDA=Z SCL=0 (Write/Readback)
	constant mmu_i2cZ1 : integer := 16#17#; -- i2c SDA=Z SCL=1 (Write/Readback)
	constant mmu_i2cMR : integer := 16#18#; -- i2C Most Recent Eight Bits (Read)
	constant mmu_smcr  : integer := 16#19#; -- Sample Control (Write/Readback)
	constant mmu_x1cfg : integer := 16#1A#; -- X1 Configuration (Write/Readback)
	constant mmu_x2cfg : integer := 16#1B#; -- X2 Configuration (Write/Readback)
	constant mmu_x3cfg : integer := 16#1C#; -- X3 Configuration (Write/Readback)
	constant mmu_x4cfg : integer := 16#1D#; -- X4 Configuration (Write/Readback)
	constant mmu_smemh : integer := 16#1E#; -- Sample HI Byte (Read)
	constant mmu_smeml : integer := 16#1F#; -- Sample LO Byte (Read)
	
-- Sample and Accumulate Constants
	constant x1_sel : std_logic_vector(1 downto 0) := "00";
	constant x2_sel : std_logic_vector(1 downto 0) := "01";
	constant x3_sel : std_logic_vector(1 downto 0) := "10";
	constant x4_sel : std_logic_vector(1 downto 0) := "11";
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
	signal TCK, FCK, FCKEN, CK, MCK : std_logic;
	attribute syn_keep of TCK, FCK, FCKEN, CK, MCK : signal is true;
	attribute nomerge of TCK, FCK, FCKEN, CK, MCK : signal is ""; 
	signal fck_mask : std_logic_vector(fck_num_feeds-1 downto 0);
	constant default_fck_mask :
		std_logic_vector(fck_num_feeds-1 downto 0) :=
		(fck_num_feeds-1 => '1', others => '0');

-- Clock Control. 
	signal ENFCKCPU, -- Enable Fast Clock, from CPU
		ENFCKTM, -- Enable Fast Clock, from Telemetry Manager
		BOOST, -- Boost CPU Clock
		KEEPFCK, -- Keep FCK Running
		RCKLO -- RCK is LO
		: boolean; 
	signal SRCK, -- RCK Synchronized with FCK
		SSRCK -- SRCK Delayed by one FCK Period
		: std_logic; 
	attribute syn_keep of BOOST, ENFCKCPU, ENFCKTM : signal is true;
	attribute nomerge of BOOST, ENFCKCPU, ENFCKTM : signal is "";

-- Telemetry Manager
	signal TMINT, -- Telemetry Manager Interrupt
		TMINTD -- TMINT Delayed
		: boolean := false;

-- Sample Controller
	signal SCRQ, -- Sample Controller Request
		SCRST, -- Sample Controller Reset
		SCACK, -- Sample Controller Acknowledge
		SCBSY, -- Sample Controller Busy
		X4SS -- Channel X4 Single Sample
		: boolean := false;
	attribute syn_keep of SCRST, SCBSY : signal is true;
	attribute nomerge of SCRST, SCBSY : signal is "";  
	signal x1_shift, x2_shift, x3_shift, x4_shift : std_logic_vector(2 downto 0);
	signal X1SKIP, X2SKIP, X3SKIP, X4SKIP : boolean;

-- Sample Memory and Accumulator
	signal SMWRADC, -- Sample Memory Write by ADC Controller
		SMWRCPU, -- Sample Memory Write by CPU
		ACCADD, -- Accumulator Add
		ACCRST -- Accumulator Reset
		: std_logic;
	attribute syn_keep of ACCADD, ACCRST : signal is true;
	attribute nomerge of ACCADD, ACCRST : signal is "";  
	signal smem_data, acc_data : std_logic_vector(17 downto 0);
	signal smem_addr, sample_sel : std_logic_vector(1 downto 0);

-- ADC Controller.
	signal ADCCAL, -- Calibrate the Selected ADC
		ADCRD, -- Initiate ADC Read
		ADCBSY -- ADC Busy
		: boolean := false;
	attribute syn_keep of ADCRD, ADCBSY : signal is true;
	attribute nomerge of ADCRD, ADCBSY : signal is "";  
	signal adc_data : std_logic_vector(17 downto 0);
	signal adc_sel : std_logic_vector(1 downto 0);
	signal adc_shift : std_logic_vector(2 downto 0);

-- Message Transmission. The syn_keep and nomerge reduce code size slightly.
	signal TXI, -- Transmit Initiate
		TXWP, -- Transmit Warmup
		TXA, -- Transmit Active
		TXB, -- Transmit Bit
		FHI -- Frequency High
		: boolean := false;
	attribute syn_keep of TXI, TXA : signal is true;
	attribute nomerge of TXI, TXA : signal is "";  
	signal xmit_bits : std_logic_vector(15 downto 0);
	signal tx_channel : integer range 0 to 255;
	signal frequency_low : integer range 0 to 31;
	signal transmit_shift : std_logic_vector(3 downto 0);
		
-- I2C Bus Controller
	signal i2c_in : std_logic_vector(7 downto 0); -- I2C Serial Byte
	
-- Diagnostic Flag Register
	signal df_reg : std_logic_vector(3 downto 0);

-- Program Memory Signals
	signal prog_data : std_logic_vector(mcu_instr_len-1 downto 0); -- ROM Data
	signal prog_cntr : std_logic_vector(mcu_addr_len-1 downto 0); -- Prog Address
	
-- Process Memory Signals
	signal ram_addr : std_logic_vector(ram_addr_len-1 downto 0); -- RAM Address
	signal ram_out, ram_in : std_logic_vector(7 downto 0); -- RAM Data In and Out
	signal RAMWR : std_logic; -- Command Memory Write
	
-- Central Processing Unit Signals. The syn_keep and nomerge reduce code size slightly.
	signal cpu_data_out, cpu_data_in : std_logic_vector(7 downto 0); 
	signal cpu_addr : std_logic_vector(mcu_addr_len-1 downto 0);
	attribute syn_keep of cpu_addr : signal is true;
	attribute nomerge of cpu_addr : signal is "";  
	signal CPUWR, -- Write (Not Read)
		CPUDS, -- Data Strobe
		CPUIRQ, -- Interrupt Request
		CPUISRV -- Interrupt Service
		: boolean; 
	signal CPUSIG : std_logic_vector(3 downto 0); -- Signals for debugging

-- Interrupt Handler signals.
	signal int_mask, int_bits, int_rst : std_logic_vector(7 downto 0);
	signal int_rst_d, int_rst_s : std_logic_vector(7 downto 0);
	signal int_period_0 : std_logic_vector(4 downto 0);
	
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
	FCKEN <= to_std_logic(ENFCKCPU or ENFCKTM or KEEPFCK or CPUISRV);
	Fast_Clock: entity ring_oscillator 
		generic map (
			num_gates => fck_num_gates,
			num_feeds => fck_num_feeds
		)	
		port map (
			ENABLE => FCKEN, 
			mask => fck_mask,
			CK => FCK
		);
		
-- The Millisecond Clock takes RCK, which is 32.768 kHz and divides
-- by 32 to get 1.024 kHz, which we use as our millisecond clock.
	Millisecond_Clock : process (RCK) is
		variable mcnt : integer range 0 to 31;
	begin
		if falling_edge(RCK) then
			mcnt := mcnt + 1;
			if (mcnt <= 15) then
				MCK <= '0';
			else
				MCK <= '1';
			end if;
		end if;	
	end process;
		
-- The Process Memory is the RAM available to the code executing on the CPU.
	Process_Memory : entity RAM port map (
		Clock => not CK,
		ClockEn => '1',
        Reset => '0',
		WE => RAMWR,
		Address => ram_addr, 
		Data => ram_in,
		Q => ram_out);

-- The Instruction Memory is a ROM that holds the CPU program. 
	Instruction_Memory : entity ROM port map (
		Address => prog_cntr,
        OutClock => not CK,
        OutClockEn => '1',
        Reset => '0',	
        Q => prog_data);

-- The RMC5, configured for this application by its generic map.
	CPU : entity RMC5_CPU
		generic map (
			addr_len => mcu_addr_len,
			instr_len => mcu_instr_len,
			start_pc => start_pc,
			interrupt_pc => interrupt_pc
		)
		port map (
			prog_data => prog_data,
			prog_cntr => prog_cntr,
			cpu_data_out => cpu_data_out,
			cpu_data_in => cpu_data_in,
			cpu_addr => cpu_addr,
			WR => CPUWR,
			DS => CPUDS,
			IRQ => CPUIRQ,
			ISRV => CPUISRV,
			RESET => RESET,
			CK => CK
		);
		
-- The Memory Manager maps eight-bit read and write access to the Sensor 
-- Controller, Sample Transmitter, Random Access Memory, and Interrupt 
-- Handler. Byte ordering is big-endian (most significant byte at lower 
-- address). 
	MMU : process (all) is
		variable all_bits : integer range 0 to 2048;
		variable bottom_bits : integer range 0 to 31;
	begin		
		-- By default, don't write to RAM or PROG memories, nor do we read from
		-- the command memory FIFO.
		RAMWR <= '0';
		
		-- The RAM address we take from the lower bits of the cpu
		-- address. The RAM data in is always the cpu data out.
		ram_in <= cpu_data_out;
		ram_addr <= cpu_addr(ram_addr_len-1 downto 0);
		
		-- These signals develop after the CPU asserts a new address
		-- along with CPU Write. They will be ready before the falling 
		-- edge of the CPU clock.
		all_bits := to_integer(unsigned(cpu_addr));
		bottom_bits := to_integer(unsigned(cpu_addr(5 downto 0)));
		
		-- Combinatorial memory map, which serves all access except 
		-- for writing to control registers. We have the control
		-- space reads, which are either supplied by registers or
		-- by shadow locations in RAM. We have the RAM itself, and
		-- the program memory as well.
		cpu_data_in <= (others => '0');
		case all_bits is
			when ctrl_bot to ctrl_top =>
				if not CPUWR then 
					case bottom_bits is
					
						-- The interrupt request bits, used by the CPU interrupt
						-- routine, of which there can by only one, to determine
						-- which of the interrupt sources requires servicing.						
						when mmu_irqb => cpu_data_in <= int_bits;
						
						-- The status register, which gives access to an array of
						-- flags that signal the state of the peripheral logic.
						-- and clocks, including the 32.768 kHz and 1.024 kHz 
						-- clocks, which the CPU can use for timing.
						when mmu_sr => 
							cpu_data_in(2) <= MCK;                  -- Millisecond Clock
							cpu_data_in(3) <= to_std_logic(TXA);    -- Transmit Active
							cpu_data_in(5) <= to_std_logic(SCBSY);  -- Sample Controller Busy
							cpu_data_in(7) <= RCK;                  -- Reference Clock
							
						-- The location from which the CPU reads command bytes out
						-- The location from which the CPU reads the byte most 
						-- recently received from the I2C interface.
						when mmu_i2cMR => cpu_data_in <= i2c_in;
						
						-- The two locations that provide the output of the sample 
						-- memory, which holds accumulated samples. We read the
						-- top sixteen bits of its eighteen-bit output.
						when mmu_smemh => cpu_data_in <= smem_data(17 downto 10);							
						when mmu_smeml => cpu_data_in <= smem_data(9 downto 2);
						
						-- Whenever we read any other location, we get the value 
						-- previously written to the shadow RAM.
						when others => cpu_data_in <= ram_out;
					end case;
				else 
					-- When we write to any control space register, record the 
					-- written value in the shadow RAM.
					RAMWR <= to_std_logic(CPUDS);
				end if;
			when ram_bot to ram_top => 
				-- The variable and stack RAM space, writing and reading.
				if not CPUWR then
					cpu_data_in <= ram_out;
				else
					RAMWR <= to_std_logic(CPUDS);
				end if;
			when others =>
				null;
		end case;
		
		-- Here is the memory map for control register write access. We use RESET 
		-- to clear some registers and signals, but not all. We do not clear the
		-- software reset signal, SWRST, on RESET, since we want SWRST to assert 
		-- RESET for one CK period. After a reset, the cpu address will not select 
		-- the SWRST location, so SWRST will be cleared on the next falling edge 
		-- of CK. All writes to control space are shadowed by RAM locations so that
		-- we can be sure to read them back.
		if (RESET = '1') then
			TXI <= false;
			TXWP <= false;
			ENFCKCPU <= false;
			BOOST <= false;
			tx_channel <= tx_channel_default;
			df_reg <= (others => '0');
			int_mask <= (others => '0');
			int_rst <= (others => '1');
			int_period_0 <= (others => '0');
			frequency_low <= default_frequency_low;
			fck_mask <= default_fck_mask;
			SDA <= 'Z';
			SCL <= '1';
			MSR <= '0';
			DC <= '0';
			ACCRST <= '1';
			SMWRCPU	<= '1';
			X1SKIP <= false;
			X2SKIP <= false;
			X3SKIP <= false;
			X4SKIP <= false;
			X4SS <= false;
			
		-- We use the falling edge of RCK to write to registers and to initiate sensor 
		-- and transmit activity. Some signals we assert only for one CK period, and 
		-- these we assert as false by default.
		elsif falling_edge(CK) then
			SWRST <= false;
			TXI <= false;
			ACCRST <= '0';
			SMWRCPU <= '0';
			int_rst <= (others => '0');
			if CPUDS and CPUWR then 
				if (all_bits >= ctrl_bot) and (all_bits <= ctrl_top) then
					case bottom_bits is
						-- The Amplifier Configuration register selects between
						-- AC and DC coupling for the unipolar inputs with bit
						-- zero. With bit one it activates the impedance 
						-- measurement switch, which displaces the ground
						-- potential of unipolar and bipolar inputs so as
						-- to introduce a step downwards in the unipolar 
						-- inputs, the size of which depends upon the ratio
						-- of the electrode impedance to the amplifier input
						-- impedance.
						when mmu_acfg => 
							DC <= cpu_data_out(0);
							MSR <= cpu_data_out(1);
						
						-- The two locations in which the CPU places the sixteen
						-- telemetry sample bits that will be transmitted after the
						-- next write to the transmission control register.
						when mmu_xlb  => xmit_bits(7 downto 0) <= cpu_data_out;
						when mmu_xhb  => xmit_bits(15 downto 8) <= cpu_data_out;
						
						-- The telemetry channel number for the next transmission.
						when mmu_xch  => tx_channel <= to_integer(unsigned(cpu_data_out));
						
						-- The telemetry control register. The TXI initiates a transmission,
						-- while TXWP turns on the VCO to warm it up before it transmits, 
						-- which is necessary if the VCO has been dormant for more than 
						-- 20 ms. We must turn off the warm-up by writing a zero to TXWP
						-- after a warm-up of no more than 20 ms so we do not collide with
						-- other transmitters.
						when mmu_xcr  => 
							TXI <= (cpu_data_out(0) = '1');
							TXWP <= (cpu_data_out(1) = '1');
							
						-- The frequency calibration of the VCO. We write the VCO control
						-- five-bit DAC value that sets the frequency of a transmit zero.
						when mmu_rfc  => frequency_low <= to_integer(unsigned(cpu_data_out));
						
						-- The interrupt mask. Bits set to one enable their corresponding
						-- interrupt request bits and any peripheral machines that generate
						-- interrupts.
						when mmu_imsk => int_mask <= cpu_data_out;
						
						-- The interrupt-0 period. In this case we set a four-bit period
						-- between 0 and 31 to indicate the transmit interrupt period in
						-- multiples of 1/1024 s. When the period is zero, the interrupt
						-- will take place every 32 periods, or at 32 Hz.
						when mmu_i0p  => int_period_0 <= cpu_data_out(4 downto 0);

						-- The interrupt reset register. Bits set to one reset their
						-- corresponding interrupt request bits, signalling that the
						-- interrupt has been serviced.
						when mmu_irst => int_rst <= cpu_data_out;
						
						-- Turn on the indicator lamp.
						when mmu_led  => LED <= cpu_data_out(0);
						
						-- A strobe that reboots the firmware and CPU.
						when mmu_rst  => SWRST <= (cpu_data_out(0) = '1');
						
						-- Control bits to turn on the fast clock, which in turn
						-- produces the transmit clock, and to move the CPU into
						-- boost mode. These bits are in addition to the automatic
						-- enable of the fast clock and move into boost that is 
						-- performed by the Boost Controller when it sees the
						-- CPU's interrupt service flag has been set by the CPU
						-- to indicate that it is servicing an interrupt.
						when mmu_ccr  => 
							ENFCKCPU <= (cpu_data_out(0) = '1');
							BOOST <= (cpu_data_out(1) = '1');
							
						-- The diagnostic flag register. These bits can be routed
						-- to test points for diagnostics with an oscilloscope.
						when mmu_dfr  => df_reg <= cpu_data_out(3 downto 0);
						
						-- The fast clock mask has only one bit out of eight set,
						-- and this bit selects which gate in the ring will be
						-- used for feedback, thus setting the ring frequency.
						when mmu_fck => fck_mask <= cpu_data_out;
						
						-- The I2C bit-banging interface. Each write to one of these
						-- locations sets both SDA and SCL to one of zero, one, or
						-- high-impedance. We operate the I2C by writing register A
						-- to these locations. Some locations take the top bit of A
						-- and, when this bit is zero, drive SDA low. Others cause
						-- the value of SDA to be shifted into the i2C byte register,
						-- from which it can later be read out. With the CPU in boost
						-- mode, the interface runs at 500 kHz. See the I2C assembler
						-- routine for more details.
						when mmu_i2c00 => 
							SDA <= '0';
							SCL <= '0';
						when mmu_i2c01 =>
							SDA <= '0';
							SCL <= '1';
						when mmu_i2cA0 => 
							if (cpu_data_out(7) = '0') then
								SDA <= '0';
							else
								SDA <= 'Z';
							end if;
							SCL <= '0';
						when mmu_i2cA1 =>
							if (cpu_data_out(7) = '0') then
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
							
						-- The sample select control register begins with two
						-- bits to select which accumulated sample the CPU
						-- will get when it reads the sample memory HI and
						-- LO bytes. The sample memory will accept this 
						-- sample select value provided that ADCBSY is not
						-- asserted. The ACCRST and SMWRCPU strobes reset the
						-- accumulator output and write the accumulator output
						-- to the selected accumulated sample.
						when mmu_smcr =>
							sample_sel <= cpu_data_out(1 downto 0);
							ACCRST <= cpu_data_out(2);
							SMWRCPU <= cpu_data_out(3);
							
						-- We have four locations to describe how each input
						-- is to be sampled.
						when mmu_x1cfg =>
							x1_shift <= cpu_data_out(2 downto 0);
							X1SKIP <= cpu_data_out(7) = '1';
						when mmu_x2cfg =>
							x2_shift <= cpu_data_out(2 downto 0);
							X2SKIP <= cpu_data_out(7) = '1';
						when mmu_x3cfg =>
							x3_shift <= cpu_data_out(2 downto 0);
							X3SKIP <= cpu_data_out(7) = '1';
						when mmu_x4cfg =>
							x4_shift <= cpu_data_out(2 downto 0);
							X4SS <= (cpu_data_out(3) = '1');
							X4SKIP <= cpu_data_out(7) = '1';

						-- For all other addresses, we have no bits to set.
						-- he shadow RAM is recording all writes to these 
						-- addresses, and will respond to reads for which 
						-- no readable register is implemented.
						when others => null;
					end case;
				end if;
			end if;
		end if;
	end process;
	
-- The Boost Controller switches the CPU between RCK and a 5-MHz it
-- generates using FCK. We call this 5-MHz clock the Transmit Clock 
-- (TCK). When the CPU's clock CK is set to TCK, we are in "boost" mode. 
-- When CK = RCK we are in "slow" mode. Switching to boost is easy
-- because we know the state of RCK when we want to switch into boost. 
-- Either the CPU just asserted BOOST with a regiseter write, or it 
-- just asserted Interrupt Service (ISRV). Both occur on the falling 
-- edge of CK, so RCK  will be LO for at least 15 us. We come out of 
-- boost when both BOOST and ISRV are un-asserted. We use signal 
-- RCKLO to coordinate the transition from TCK to RCK. We will perform
-- this transition only when both TCK and RCK are LO and guaranteed
-- to remain LO for at least two FCK cycles. We care about the value of 
-- RCKLO only when FCK is running and BOOST has been unasserted. We
-- assert RCKLO after each falling edge of RCK for a one hundred FCK
-- cycles, which will be 10 us if FCK is exactly 10 MHz, but longer
-- if FCK is running slower, as it will before calibration. We assume
-- that FCK will always be at least 7 MHz so that RCKLO will never
-- exceed 15 us and remain asserted during the next rising edge of RCK.
-- During transitions between boost and slow modes, TCK will skip some
-- cycles. We must refrain from moving in and out of boost while some
-- other process is relying on TCK to be sustained. For example, we must 
-- not boost or un-boost during a telemetry sample transmission.
	Boost_Controller : process (RESET, FCK) is
	variable state, next_state : integer range 0 to 3;
	constant end_count : integer := 100;
	variable counter : integer range 0 to 127;
	begin
	
		-- Generate KEEPFCK, RCKLO, and RCKHI.
		if (RESET = '1') then
			SRCK <= '0';
			SSRCK <= '0';
			counter := 0;
			RCKLO <= false;
			KEEPFCK <= false;
		elsif rising_edge(FCK) then
			KEEPFCK <= (state /= 0);
			SRCK <= RCK;
			SSRCK <= SRCK;
			
			if not KEEPFCK then
				RCKLO <= true;
			elsif (SRCK = '0') and (SSRCK = '1') then
				RCKLO <= true;
			elsif (counter = end_count) then 
				RCKLO <= false;
			end if;
			
			if (not RCKLO) or (not KEEPFCK) then
				counter := 0;
			else
				counter := counter + 1;
			end if;
		end if;
		
		-- Manage transition from slow to boost and back to slow.
		if RESET = '1' then
			state := 0;
			TCK <= '0';
		elsif falling_edge(FCK) then
			case state is
				when 0 =>
					if BOOST or CPUISRV then 
						TCK <= '0';
						next_state := 1;
					else
						TCK <= to_std_logic(TCK = '0');
						next_state := 0;
					end if;
				when 1 => 
					next_state := 3;
					TCK <= '0';
				when 3 =>
					if (not BOOST) and (not CPUISRV) then
						TCK <= '0';
						next_state := 2;
					else
						TCK <= to_std_logic(TCK = '0');
						next_state := 3;
					end if;
				when 2 => 
					if RCKLO then
						next_state := 0;
					else
						next_state := 2;
					end if;
					TCK <= '0';
			end case;
			state := next_state;
		end if;
		
		-- The clock selector: boost or slow according to state.
		CK <= to_std_logic(
			((RCK = '1') and (state = 0)) 
			or ((TCK = '1') and (state = 3)));
	end process;

-- The Interrupt Controller provides the interrupt signal to the CPU in response to
-- timer events. By default, at power-up, all interrupts are masked. We can set the
-- period of each timer by writing to locations in the CPU control space. If we want
-- the counter to have period N ticks, we write value N-1 to the period registers.
	Interrupt_Controller : process (RCK, int_rst) is
	begin
	
		-- Synchronize the int_rst bits with RCK. Our interrupt counters run off RCK, 
		-- and the interrupt lines themselves are generated by RCK, but the interrupt
		-- reset signals are asserted by the CPU during interrupt servicing, for which
		-- the CPU is in boost mode, running of the 5-MHz TCK. Our registers can handle 
		-- asynchronous assertion of reset, but not asynchronous unassertion of reset. 
		-- We must make the unassertion synchronous with the clock that drives the register.
	
		-- Interrupt One Reset
		if int_rst(0) = '1' then
			int_rst_d(0)  <= '1';
			int_rst_s(0) <= '1';
		elsif falling_edge(RCK) then
			int_rst_d(0)  <= '0';
			int_rst_s(0) <= int_rst_d(0);
		end if;
		
		-- The interrupt timers run all the time, counting down from their period value
		-- to zero. The only way to stop them counting is to set their period value to
		-- zero so that they stick at zero. Just disabling the interrupt does not stop 
		-- the counter.

		-- Interrupt One: Set by a rising edge on TMINT from the Telemetry Manager.
		if rising_edge(RCK) then
			TMINTD <= TMINT;
		end if;
		
		-- Using the interrupt reset bits that we synchronized with RCK, we 
		-- reset the interrupt bits. Otherwise, we set the interrupt bits
		-- either with some external flag or when a timer reaches zero.
				
		-- Interrupt One Control
		if (int_rst_s(0) = '1') then
			int_bits(0) <= '0';
		elsif rising_edge(RCK) then
			if (TMINT and (not TMINTD)) then
				int_bits(0) <= '1';
			end if;
		end if;
		
		-- We disable the remaining interrupt lines.
		for i in 1 to 7 loop
			int_bits(i) <= '0';
		end loop;		
	end process;

-- The Interrupt Generator takes the interrupt bits and the interrupt mask
-- and combines them to create an interrupt reques for the CPU, which we 
-- synchronize with CK.
	Interrupt_Generator : process (CK) is
	begin
		if RESET = '1' then
			CPUIRQ <= false;
		elsif falling_edge(CK) then
			CPUIRQ <= (int_bits and int_mask) /= "00000000";
		end if;
	end process;
	
-- The Telemetry Manager organizes sampling of the inputs X1-X4 a
-- frequency that is an integer fraction of 1024 SPS and generates
-- the transmit interrupt offset from sampling by a random number
-- of RCK periods. The manager runs off RCK, but the Sample
-- Controller, which it activates in its sample state, runs off
-- FCK. In the sample state, the manager unasserts SCRST so that 
-- the Sample Controller can come out of reset on the next rising 
-- edge of FCK. The manager also toggles the SCRQ so as to request
-- that FCK start up. The Sample Controller will set SCACK equal to
-- SCRQ when it has finished sampling. The manager enables FCK when 
-- SCRQ and SCACK are not equal, This interaction between two
-- processes, one running on RCK and one on FCK works provided that
-- the Sample Controller runs on the rising edge of FCK and toggles 
-- SCACK on the falling edge. 
	Telemetry_Manager : process (RCK) is 
		constant tm_max : integer := 31;
		constant tm_idle : integer := tm_max;
		constant tm_update : integer := tm_max - 1;
		constant tm_sample : integer := tm_max - 2;
		variable state, next_state : integer range 0 to tm_max := 0;
		variable TMRUN : boolean;
		variable tx_index : integer range 0 to 31;
		
	begin
		if RESET = '1' then
			ENFCKTM <= false;
			SCRST <= true;
			SCRQ <= false;
			TMINT <= false;
			TMRUN := false;
			state := tm_idle;
		elsif rising_edge(RCK) then
			TMRUN := (int_mask(0) = '1');
			
			if not TMRUN then
				next_state := tm_idle;
			else
				if state = tm_idle then
					next_state := 0;
				else
					next_state := state + 1;
				end if;
			end if;
			
			if (state = to_integer(unsigned(transmit_shift))) then
				if tx_index = 1 then
					TMINT <= true;
				end if;
			elsif (state = tm_sample) then
				SCRQ <= not SCRQ;
			elsif (state = tm_update) then
				SCRST <= true;
				TMINT <= false;
				if tx_index = 1 then
					tx_index := to_integer(unsigned(int_period_0));
				else
					tx_index := tx_index - 1;
				end if;
			elsif (state = tm_idle) then
				SCRST <= false;
				if not TMRUN then
					tx_index := to_integer(unsigned(int_period_0));
				end if;
			else
				SCRST <= false;
			end if;
			
			state := next_state;
		end if;
		
		ENFCKTM <= SCRQ xor SCACK;
	end process;

-- The Sample Memory is fourteen bits wide so as to accommodate
-- our fourteen-bit ADC samples. The sample memory runs off 
-- the fast clock to work well with the Sample Controller, which
-- also runs on fast clock.
	Sample_Memory : entity SMRAM port map (
		Clock => not FCK,
		ClockEn => '1',
        Reset => '0',
		WE => SMWRADC or SMWRCPU,
		Address => smem_addr, 
		Data => acc_data,
		Q => smem_data);
	
-- The Sample Memory Address Multiplexer sets the sample memory 
-- address equal to adc_sel when the ADC Controller is busy, and
-- sample_sel otherwise. The former is incremented by the Sample 
-- Controller as it steps through the ADCs performing samples. The
-- latter is set by the CPU with a write to the sample memory
-- address register.
	Sample_Addr_Mux : process (SCBSY) is 
	begin
		if SCBSY then
			smem_addr <= adc_sel;
		else
			smem_addr <= sample_sel;
		end if;
	end process;
		
-- The Sample Accumulator adds fourteen-bit samples from the Sample 
-- Memory together so as to produce an eighteen-bit value from which
-- we will read the top sixteen bits as our sample for transmission.
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
-- The controller sets adc_sel and adc_shift to match each ADC in turn.
	Sample_Controller : process (FCK) is
	variable state, next_state : integer range 0 to 15 := 0;
	variable X1SKIPL, X2SKIPL, X3SKIPL, X4SKIPL : boolean;
	constant sc_idle : integer := 0;
	constant x1_check : integer := 1;
	constant x1_start : integer := 2;
	constant x1_wait : integer := 3;
	constant x2_check : integer := 4;
	constant x2_start : integer := 5;
	constant x2_wait : integer := 6;
	constant x3_check : integer := 7;
	constant x3_start : integer := 8;
	constant x3_wait : integer := 9;
	constant x4_check : integer := 10;
	constant x4_start : integer := 11;
	constant x4_wait : integer := 12;
	constant sc_done : integer := 13;
	constant sc_wait : integer:= 14;
	variable X4EN : boolean;
	
	begin
		if RESET = '1' then
			SCACK <= false;
		elsif falling_edge(FCK) then
			if (state = sc_wait) then
				SCACK <= SCRQ;
			end if;
		end if;
		
		if RESET = '1' then
			ADCCAL <= true;
		elsif rising_edge(FCK) then
			if (state = sc_done) then
				ADCCAL <= false;
			end if;
		end if;
		
		if RESET = '1' then
			X4EN := true;
		elsif rising_edge(FCK) then
			if (ACCRST = '1') and (sample_sel = x4_sel) then
				X4EN := true;
			elsif (state = x4_wait) and X4SS then
				X4EN := false;
			end if;
		end if;
			
		if SCRST then
			ADCRD <= false;
			adc_sel <= x1_sel;
			state := sc_idle;
			X1SKIPL := X1SKIP;
			X2SKIPL := X2SKIP;
			X3SKIPL := X3SKIP;
			X4SKIPL := X4SKIP;
		elsif rising_edge(FCK) then
			if (state = sc_idle) then 
				adc_sel <= x1_sel;
				adc_shift <= x1_shift;
				ADCRD <= false;
				if ENFCKTM then
					next_state := x1_check;
				else
					next_state := sc_idle;
				end if;
			elsif (state = x1_check) then
				adc_sel <= x1_sel;
				adc_shift <= x1_shift;
				ADCRD <= false;
				if not X1SKIPL then
					next_state := x1_start;
				else 
					next_state := x2_check;
				end if;
			elsif (state = x1_start) then
				adc_sel <= x1_sel;
				adc_shift <= x1_shift;
				ADCRD <= true;
				if ADCBSY then
					next_state := x1_wait;	
				else
					next_state := x1_start;
				end if;
			elsif (state = x1_wait) then
				adc_sel <= x1_sel;
				adc_shift <= x1_shift;
				ADCRD <= false;
				if ADCBSY then
					next_state := x1_wait;
				else
					next_state := x2_check;
				end if;
			elsif (state = x2_check) then
				adc_sel <= x2_sel;
				adc_shift <= x2_shift;
				ADCRD <= false;
				if not X2SKIPL then
					next_state := x2_start;
				else 
					next_state := x3_check;
				end if;
			elsif (state = x2_start) then
				adc_sel <= x2_sel;
				adc_shift <= x2_shift;
				ADCRD <= true;
				if ADCBSY then
					next_state := x2_wait;	
				else
					next_state := x2_start;
				end if;
			elsif (state = x2_wait) then
				adc_sel <= x2_sel;
				adc_shift <= x2_shift;
				ADCRD <= false;
				if ADCBSY then
					next_state := x2_wait;
				else
					next_state := x3_check;
				end if;
			elsif (state = x3_check) then
				adc_sel <= x3_sel;
				adc_shift <= x3_shift;
				ADCRD <= false;
				if not X3SKIPL then
					next_state := x3_start;
				else 
					next_state := x4_check;
				end if;
			elsif (state = x3_start) then
				adc_sel <= x3_sel;
				adc_shift <= x3_shift;
				ADCRD <= true;
				if ADCBSY then
					next_state := x3_wait;	
				else
					next_state := x3_start;
				end if;
			elsif (state = x3_wait) then
				adc_sel <= x3_sel;
				adc_shift <= x3_shift;
				ADCRD <= false;
				if ADCBSY then
					next_state := x3_wait;
				else
					next_state := x4_check;
				end if;
			elsif (state = x4_check) then
				adc_sel <= x4_sel;
				adc_shift <= x4_shift;
				ADCRD <= false;
				if not X4SKIPL then
					next_state := x4_start;
				else 
					next_state := sc_done;
				end if;
			elsif (state = x4_start) then
				adc_sel <= x4_sel;
				adc_shift <= x4_shift;
				if X4EN then
					ADCRD <= true;
					if ADCBSY then
						next_state := x4_wait;	
					else
						next_state := x4_start;
					end if;
				else 
					ADCRD <= false;
					next_state := sc_done;
				end if;
			elsif (state = x4_wait) then
				adc_sel <= x4_sel;
				adc_shift <= x4_shift;
				ADCRD <= false;
				if ADCBSY then
					next_state := x4_wait;
				else
					next_state := sc_done;
				end if;
			elsif (state = sc_done) then
				adc_sel <= x4_sel;
				adc_shift <= x4_shift;
				ADCRD <= false;
				next_state := sc_wait;
			else 
				adc_sel <= x4_sel;
				adc_shift <= x4_shift;
				ADCRD <= false;
				next_state := sc_wait;
			end if;
			
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
-- This calibration read will cause the ADC to self-calibrate provided that 
-- the calibration access is the first one after power-up. 
	ADC_Controller : process (RESET, FCK) is
		variable state, next_state : integer range 0 to 63 := 0;
		constant calib_end : integer := 50;
		constant read_end : integer := 40;
		
 	begin
		-- Upon startup, we make sure we are in the idle state.
		if (RESET = '1') then 
			state := 0;
			ADCBSY <= false;
			ACCADD <= '0';
			SMWRADC <= '0';
			adc_data <= (others => '0');
			transmit_shift <= (others => '1');
			
		-- The ADC Contoller proceeds through states so as initiate a conversion,
		-- read out one zero, fourteen data bits, and three trailing zeros. If
		-- the ADCCAL flag is set, it reads out nine trailing zeros so as to 
		-- initiate an ADC self-calibration. When ADCCAL is not set, the fourteen 
		-- data bits are shifted into the adc_data register. Once we have them, we
		-- write the sample to the sample memory.
		elsif falling_edge(FCK) then
			if (state = 0) then 
				if ADCRD then 
					next_state := 1;
				else 
					next_state := 0;
				end if;
			end if;
			if ADCCAL then
				if (state > 0) and (state < calib_end) then
					next_state := state + 1;
				end if;
				if (state = calib_end) then
					next_state := 0;
				end if;
				SCK <= to_std_logic(
					(state = 0) 
					or ((state < 48) and (state mod 2) = 1));
				adc_data <= (others => '0');
			else 
				if (state > 0) and (state < read_end) then
					next_state := state + 1;
				end if;
				if (state = read_end) then
					next_state := 0;
				end if;
				SCK <= to_std_logic(
					(state = 0) 
					or ((state < 36) and ((state mod 2) = 1))
				);
				if (state = 1) then
					adc_data <= (others => '0');
				end if;
				if (state >= 4) and (state <= 30) and ((state mod 2) = 0) then
					adc_data(17 downto 1) <= adc_data(16 downto 0);
					adc_data(0) <= SDO;
				end if;
				if ((state = 32) and (unsigned(adc_shift) >= 1))
					or ((state = 34) and (unsigned(adc_shift) >= 2)) 
					or ((state = 36) and (unsigned(adc_shift) >= 3))
					or ((state = 38) and (unsigned(adc_shift) >= 4)) then
					adc_data(17 downto 1) <= adc_data(16 downto 0);
					adc_data(0) <= '0';
				end if;
			end if;
			
			if (state = 31) then
				transmit_shift(3) <= adc_data(0) xor transmit_shift(0);
				transmit_shift(2) <= transmit_shift(3) xor transmit_shift(0);
				transmit_shift(1) <= transmit_shift(2);
				transmit_shift(0) <= transmit_shift(1);
			end if;
			
			ACCADD <= to_std_logic((state = read_end - 1) and (not ADCCAL));
			SMWRADC <= to_std_logic((state = read_end) and (not ADCCAL));
			ADCBSY <= ((not ADCCAL) and (state > 0) and (state < read_end))
				or (ADCCAL and (state > 0) and (state < calib_end));

			state := next_state;
		end if;
		
		-- The ADC we read out or calibrate is selected by the top two bits 
		-- of the sample address.
		NADC1 <= to_std_logic(not (ADCBSY and (adc_sel = x1_sel)));
		NADC2 <= to_std_logic(not (ADCBSY and (adc_sel = x2_sel)));
		NADC3 <= to_std_logic(not (ADCBSY and (adc_sel = x3_sel)));
		NADC4 <= to_std_logic(not (ADCBSY and (adc_sel = x4_sel)));
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
			-- The process starts when we assert TXI. We move through all subsequen
			-- states until we reach the final state, where we wait until TXI is
			-- un-asserted for our return to the idle state. 
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
				or ((state = first_data_bit) and (xmit_bits(15) = '1'))
				or ((state = first_data_bit + 1) and (xmit_bits(14) = '1'))
				or ((state = first_data_bit + 2) and (xmit_bits(13) = '1'))
				or ((state = first_data_bit + 3) and (xmit_bits(12) = '1'))
				or ((state = first_data_bit + 4) and (xmit_bits(11) = '1'))
				or ((state = first_data_bit + 5) and (xmit_bits(10) = '1'))
				or ((state = first_data_bit + 6) and (xmit_bits(9) = '1'))
				or ((state = first_data_bit + 7) and (xmit_bits(8) = '1'))
				or ((state = first_data_bit + 8) and (xmit_bits(7) = '1'))
				or ((state = first_data_bit + 9) and (xmit_bits(6) = '1'))
				or ((state = first_data_bit + 10) and (xmit_bits(5) = '1'))
				or ((state = first_data_bit + 11) and (xmit_bits(4) = '1'))
				or ((state = first_data_bit + 12) and (xmit_bits(3) = '1'))
				or ((state = first_data_bit + 13) and (xmit_bits(2) = '1'))
				or ((state = first_data_bit + 14) and (xmit_bits(1) = '1'))
				or ((state = first_data_bit + 15) and (xmit_bits(0) = '1'))
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
				xdac <= std_logic_vector(to_unsigned(frequency_low + frequency_step,5));
				FHI <= true;
			else
				xdac <= std_logic_vector(to_unsigned(frequency_low,5));
				FHI <= false;
			end if;
		end if;
	end process;
	
-- Test Point appears on P1-7.
	TP <= to_std_logic(CPUISRV);
--	TP <= to_std_logic(ADCBSY);
--	TP <= to_std_logic(ENFCKTM);
end behavior;