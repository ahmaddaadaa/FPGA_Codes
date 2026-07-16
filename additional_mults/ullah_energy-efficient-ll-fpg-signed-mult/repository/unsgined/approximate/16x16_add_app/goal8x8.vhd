library IEEE; 
use IEEE.STD_LOGIC_1164.ALL; 
use IEEE.NUMERIC_STD.ALL; 
use IEEE.STD_LOGIC_UNSIGNED.ALL; 
library UNISIM; 
use UNISIM.VComponents.all; 
entity goal is 
generic (word_size: integer:=8); 
Port ( 
a : in  STD_LOGIC_VECTOR (word_size-1 downto 0); 
b : in  STD_LOGIC_VECTOR (word_size-1 downto 0); 
prod: out STD_LOGIC_VECTOR (word_size * 2 - 1 downto 0)); 
end goal; 
 
architecture Behavioral of goal is 
 
----- Define new data types for storing a_reg etc.. 
type abc_reg is array(0 downto 0) of std_logic_vector(word_size+1 downto 0); 
signal a_reg, b_reg, c_reg: abc_reg; 
type ds_reg is array(0 downto 0) of std_logic_vector(word_size+1 downto 0); 
signal d_reg: ds_reg; 
type c_i_type is array(0 downto 0) of std_logic_vector(word_size+4 downto 0); 
signal c_i, c_i_last : c_i_type; 
signal p, g, g_modified : c_i_type; 
 type s_reg_type is array(0 downto 0) of std_logic_vector(2*word_size-2 downto 0); 
 signal s_reg: s_reg_type; 
 ----------------- 
type data_type is array((word_size/2 -1) downto 0) of std_logic_vector((word_size-1) downto 0); 
signal prop: data_type; 
signal gen: data_type; 
signal carries: data_type; 
signal output: data_type; 
type input_carries is array(word_size/2  downto 0) of std_logic_vector(word_size/4 downto 0); 
 signal input_carry: input_carries; 
-- define new data type for storing the partial products 
type interm_results is array((word_size/2 - 1) downto 0) of std_logic_vector(word_size+1 downto 0); 
signal chain: interm_results; 
signal s_reg_last: std_logic_vector(word_size + 3 downto 0):=(others => '0'); 
-- The pp signal is used to store the first ANDing of each partial prduct row. For example A0B0, A0B2 etc. It is generatd using O5. 
signal pp : std_logic_vector (word_size/2 -1 downto 0); 
signal gen_s, prop_s: std_logic_vector(word_size + 3 downto 0); 
 
begin 
 
 	set_initial_carry: 
 	for car in 0 to (word_size/2) generate 
	 	input_carry(car)(0) <= '0'; 
	end generate set_initial_carry; 
----- Compute generate and propagate signals 
	 row_count: 
	 for j in 0 to (word_size/2 - 1) generate 
		 Type_A: 
		 for i in 0 to (word_size - 2) generate 
			 lut_inst0: lut6_2 
			 generic map(INIT => X"7888788880008000") 
			 port map( 
			 I0 => b(j*2), 
			 I1 => a(i+1), 
			 I2 => b((j*2)+1), 
			 I3 => a(i), 
			 I4 => '1', 
			 I5 => '1', 
			 O5 => gen(j)(i), 
			 O6 => prop(j)(i) 
			 ); 
		 end generate Type_A; 
		 lut_inst1: lut6_2 
		 generic map(INIT => X"F000F00088888888") 
		 port map ( 
		 I0 => a(0), 
		 I1 => b(j*2), 
		 I2 => a(word_size - 1), 
		 I3 => b((j*2)+1), 
		 I4 => '1', 
		 I5 => '1', 
		 O5 => pp(j), 
		 O6 => prop(j)(word_size-1) 
		 ); 
		 gen(j)(word_size -1) <= '0'; 
	 end generate row_count; 
-- use carry chain for generating partil products using prop and gen signals 
	 row_control: 
	 for j in 0 to (word_size/2 -1) generate 
		 carry_chain_type_A: 
		 for i in 0 to (word_size/4 - 1) generate 
			 carry_inst0: CARRY4 
			 port map ( 
 			 DI => gen(j)(i*4+3 downto i*4), 
 			 S => prop(j)(i*4+3 downto i*4), 
 			 O => output(j)(i*4+3 downto i*4), 
			 CO => carries(j)(i*4+3 downto i*4), 
			 CI => input_carry(j)(i), 
			 CYINIT => '0' 
			 ); 
			 input_carry(j)(i+1) <= carries(j)(i*4+3); 
			 chain(j)(i*4+4 downto i*4+1) <= output(j)(i*4+3 downto i*4); 
			 end generate carry_chain_type_A; 
		 chain(j)(0) <= pp(j); 
		 chain(j)(word_size + 1) <= carries(j)(word_size - 1); 
		 end generate row_control; 
		 align_pps: 
	 for i in 0 to 0 generate 
		 a_reg(i) <= "00" & chain(i*3)(word_size + 1 downto 2); 
		 b_reg(i) <= chain(i*3+1)(word_size + 1  downto 0); 
		 c_reg(i) <= chain(i*3+2)((word_size-1) downto 0) & "00"; 
		 d_reg(i) <= chain(i*3+2)((word_size+1) downto word_size); 
		 c_i(i)(0) <= '0'; 
		 c_i_last(i)(0) <= '0'; 
		 g(i)(0) <= '0'; 
		 end generate align_pps; 

-------- Add PPs for the first stage 
		 add_pps_stage_1: 
	 for k in 0 to 0 generate 
		 PG0: LUT6_2 
		 generic map( 
		 INIT => X"96969696E8E8E8E8" 
 ) 
		 port map( 
		 O6 => p(k)(0), 
		 O5 => g(k)(1), 
		 I5 => '1', 
		 I4 => '1', 
		 I3 => '1', 
		 I2 => a_reg(k)(0), 
		 I1 => b_reg(k)(0), 
		 I0 => c_reg(k)(0) 
		 ); 
--generate the propagates for each bit for the carry chains 
		 genPG: for i in 1 to word_size+1 generate 
			 PGi: LUT6_2 
			 generic map( 
			 INIT => X"69966996E8E8E8E8" 
 ) 
 			 port map( 
			 O6 => p(k)(i), 
			 O5 => g(k)(i+1), 
			 I5 => '1', 
			 I4 => '1', 
			 I3 => g(k)(i), 
			 I2 => a_reg(k)(i), 
			 I1 => b_reg(k)(i), 
			 I0 => c_reg(k)(i) 
			 ); 
			 end generate genPG; 
		 PGN: LUT6_2 
 		 generic map( 
 		 INIT => X"17E817E8E8E8E8E8" 
 ) 
 		 port map( 
 		 O6 => p(k)(word_size+2), 
 		 O5 => g(k)(word_size+3), 
 		 I5 => '1', 
 		 I4 => '1', 
 		 I3 => d_reg(k)(0), 
		 I2 => a_reg(k)(word_size+1), 
		 I1 => b_reg(k)(word_size+1), 
		 I0 => c_reg(k)(word_size+1) 
		 ); 
		 p(k)(word_size+3) <= d_reg(k)(1); 
		 g(k)(word_size + 4) <= '0'; 
		 g_modified(k)(word_size + 3 downto 0) <= g(k)(word_size + 4 downto word_size + 3) & g(k)(word_size + 1 downto 0); 
		 genCC: for i in 0 to word_size/4 generate   
 			 begin 
			 CCi: CARRY4 
			 port map( 
			 CO  => c_i(k)(4*i+4 downto 4*i+1), 
			 O   => s_reg(k)(4*i+5 downto 4*i+2), 
			 CI  => c_i(k)(4*i), 
			 CYINIT  => '0', 
 			 DI  => g_modified(k)(4*i+3 downto 4*i), 
			 S   => p(k)(4*i+3 downto 4*i) 
 			 ); 
			 end generate genCC; 
			 s_reg(k)(word_size + 6) <= c_i(k)(word_size + 4); 
			 s_reg(k)(1 downto 0) <= chain(k*3)(1 downto 0); 
		 end generate add_pps_stage_1; 
		 last_add: 
		 for k in 0 to word_size generate 
 			 begin 
 			 last: LUT6_2 
 			 generic map (
			 INIT => X"6666666688888888" 
			 ) 
			 port map (
 			 O6 => prop_s(k),
 			 O5 => gen_s(k), 
			 I5 => '1', 
 			 I4 => '1', 
 			 I3 => '1',	
 			 I2 => '1', 
 			 I1 => chain(3)(k), 
 			 I0 => s_reg(0)(k + 6) 
 			 ); 
			 end generate last_add; 
			 prop_s (word_size + 1) <= chain(3)(word_size + 1); 
			 gen_s(word_size + 1) <= '0';
			 prop_s (11 downto 10) <= "11"; 
 			 gen_s (11 downto 10) <= "00";
			 last_carry: for i in 0 to word_size/4 generate
 			 begin 
 			 CCii: CARRY4
 			 port map(
 			 CO  => c_i_last(0)(4*i+4 downto 4*i+1),
 			 O   => s_reg_last(4*i+3 downto 4*i), 
 			 CI  => c_i_last(0)(4*i), 
 			 CYINIT  => '0', 
 			 DI  => gen_s(4*i+3 downto 4*i), 
 			 S   => prop_s(4*i+3 downto 4*i) 
			 ); 
 			 end generate last_carry; 
 	 prod (5 downto 0 ) <= s_reg(0)(5 downto 0); 
 	 prod (15 downto 6) <= s_reg_last(9 downto 0); 
 	end Behavioral; 
 