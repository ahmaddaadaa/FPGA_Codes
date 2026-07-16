library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
library UNISIM;
use UNISIM.VComponents.all;

entity goal is
generic (word_size: integer:=4);
Port (
a : in  STD_LOGIC_VECTOR (word_size-1 downto 0);
b : in  STD_LOGIC_VECTOR (word_size-1 downto 0);
prod: out STD_LOGIC_VECTOR (word_size * 2 - 1 downto 0));
end goal;

architecture Behavioral of goal is

type data_type is array((word_size/2 -1) downto 0) of std_logic_vector((word_size-1) downto 0);
signal prop: data_type;
signal gen: data_type;
signal carries: data_type;
signal output: data_type;

type input_carries is array((word_size - 2 ) downto 0) of std_logic_vector(word_size/4 downto 0);
signal input_carry: input_carries;

type interm_results is array((word_size/2 - 1) downto 0) of std_logic_vector(word_size+3 downto 0);
signal chain: interm_results;

signal p, g: std_logic_vector(word_size + 4 downto 0) := (others => '0');
signal p1, g1: std_logic_vector(word_size + 4 downto 0) := (others => '0');

signal s_reg : std_logic_vector(2*word_size - 1 downto 0) := (others => '0');
signal s_reg2 : std_logic_vector(2*word_size - 1 downto 0) := (others => '0');
signal prod_temp : std_logic_vector(word_size * 2 - 1 downto 0);


signal c_i : std_logic_vector(word_size+4 downto 0);
signal c_i2 : std_logic_vector(word_size+4 downto 0);
signal pp : std_logic_vector (word_size/2 -1 downto 0);
--signal gen_s, prop_s: std_logic_vector(word_size + 3 downto 0);

begin

set_initial_carry:
for car in 0 to (word_size - 2) generate
input_carry(car)(0) <= '0';
end generate set_initial_carry;

row_count:
for j in 0 to (word_size/2 - 2) generate -- do not count last two rows
Type_A:
for i in 0 to (word_size - 3) generate -- do not count last two columns
lut_inst0: lut6_2
generic map(INIT => X"7888788880008000")
port map(
I0 => b(j*2), --h
I1 => a(i+1), --c
I2 => b((j*2)+1), -- g
I3 => a(i), -- d
I4 => '1',
I5 => '1',
O5 => gen(j)(i),
O6 => prop(j)(i)
);
end generate Type_A;

lut_inst2: lut6_2
generic map(INIT => X"8777877770007000")
port map(
I0 => b(j*2),
I1 => a(word_size-2+1),
I2 => b((j*2)+1),
I3 => a(word_size-2),
I4 => '1',
I5 => '1',
O5 => gen(j)(word_size-2),
O6 => prop(j)(word_size-2)
);

lut_inst1: lut6_2
generic map(INIT => X"0FFF0FFF88888888")
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
------------- End of Type A LUTs ---------

----------- Now for last row -----------------
Type_Last_row:
for i in 0 to (word_size - 3) generate -- do not count last two columns
lut_inst3: lut6_2
generic map(INIT => X"8777877708880888")
port map(
I0 => b(word_size-2),
I1 => a(i+1),
I2 => b(word_size-1),
I3 => a(i),
I4 => '1',
I5 => '1',
O5 => gen(word_size/2 - 1)(i),
O6 => prop(word_size/2 - 1)(i)
);
end generate Type_Last_row;

lut_inst4: lut6_2 			-- lAST row special LUT
generic map(INIT => X"7888788807770777")
port map(
I0 => b(word_size-2),
I1 => a(word_size-2+1),
I2 => b(word_size-1),
I3 => a(word_size-2),
I4 => '1',
I5 => '1',
O5 => gen(word_size/2 - 1)(word_size-2),
O6 => prop(word_size/2 - 1)(word_size-2)
);

lut_inst5: lut6_2
generic map(INIT => X"F000F00088888888")
port map (
I0 => a(0),
I1 => b(word_size-2),
I2 => a(word_size - 1),
I3 => b(word_size-1),
I4 => '1',
I5 => '1',
O5 => pp(word_size/2 - 1),
O6 => prop(word_size/2 - 1)(word_size-1)
);
gen(word_size/2 - 1)(word_size -1) <= '0';

---------------------Last row ------------------------
row_control:
for j in 0 to (word_size/2 -1) generate

carry_chain_type_A:										-- for word_size =8, this will loop will iterate two times (0 and 1)
for i in 0 to (word_size/4 - 1) generate			--
carry_inst0: CARRY4										--
port map (													-- so first gen(0) and gen (1) are used which are 4 bits wide registers
	DI => gen(j)(i*4+3 downto i*4), 											--
	S => prop(j)(i*4+3 downto i*4),											--
	O => output(j)(i*4+3 downto i*4),										--
	CO => carries(j)(i*4+3 downto i*4),										-- output carries are stored in carries(0) and carries(1)
	CI => input_carry(j)(i),							-- first input carry should be input_carry(0)(0) and second should be input_carry(1)(0)
	CYINIT => '0'
	);
input_carry(j)(i+1) <= carries(j)(i*4+3);
chain(j)(i*4+4 downto i*4+1) <= output(j)(i*4+3 downto i*4);
end generate carry_chain_type_A;
chain(j)(0) <= pp(j);
chain(j)(word_size + 1) <= carries(j)(word_size - 1);
------------------------ new code for signed -------------
chain(j)(word_size + 2) <= '0';
chain(j)(word_size + 3) <= '1';
end generate row_control;
-----------------------------------------


----------------------------------------
last_add:
for k in 0 to word_size+1 generate
begin
last: LUT6_2
  generic map(
    INIT => X"6666666688888888"
  )
  port map(
    O6 => p(k),
    O5 => g(k),
    I5 => '1',
    I4 => '1',
    I3 => '1',
    I2 => '1',
    I1 => chain(1)(k),
    I0 => chain(0)(k + 2)
  );
end generate last_add;
--p(7 downto 4) <= "11" & chain(1)(5 downto 4);
p(7 downto 6) <= "11" ;
--g(7 downto 4) <= "0000";
g(7 downto 6) <= "00";

c_i(0) <= '0';
--generate carry chains
  last_carry: for i in 0 to word_size/4 generate
  begin
    CCii: CARRY4
      port map(
        CO  => c_i(4*i+4 downto 4*i+1),
        O   => s_reg(4*i+3 downto 4*i),
        CI  => c_i(4*i),
        CYINIT  => '0',
        DI  => g(4*i+3 downto 4*i),
        S   => p(4*i+3 downto 4*i)
      );
  end generate last_carry;

prod_temp(1 downto 0) <= chain(0)(1 downto 0);
prod_temp(7 downto 2) <= s_reg(5 downto 0);

---------------------- addition for adding 1 --------

last1: LUT6_2
  generic map(
    INIT => X"6666666688888888"
  )
  port map(
    O6 => p1(0),
    O5 => g1(0),
    I5 => '1',
    I4 => '1',
    I3 => '1',
    I2 => '1',
    I1 => prod_temp(word_size),
    I0 => '1'
  );

p1(word_size-1 downto 1) <= prod_temp(word_size*2-1 downto word_size+1);

g1(word_size-1 downto 1) <= "000";


c_i2(0) <= '0';
--generate carry chains
  last_carry1: for i in 0 to (word_size/4 - 1) generate
  begin
    CCiii: CARRY4
      port map(
        CO  => c_i2(4*i+4 downto 4*i+1),
        O   => s_reg2(4*i+3 downto 4*i),
        CI  => c_i2(4*i),
        CYINIT  => '0',
        DI  => g1(4*i+3 downto 4*i),
        S   => p1(4*i+3 downto 4*i)
      );
  end generate last_carry1;

prod(word_size-1 downto 0) <= prod_temp(word_size-1 downto 0);
prod(word_size*2-1 downto word_size) <= s_reg2(word_size-1 downto 0);

------------------------------------------
end Behavioral;
