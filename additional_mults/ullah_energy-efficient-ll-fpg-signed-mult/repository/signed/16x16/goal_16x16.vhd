library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
library UNISIM;
use UNISIM.VComponents.all;

entity goal_16x16 is
generic (word_size: integer:=16);
Port (
a : in  STD_LOGIC_VECTOR (word_size-1 downto 0);
b : in  STD_LOGIC_VECTOR (word_size-1 downto 0);

prod: out STD_LOGIC_VECTOR (word_size * 2 - 1 downto 0));
end goal_16x16;

architecture Behavioral of goal_16x16 is

type data_type is array((word_size/2 -1) downto 0) of std_logic_vector((word_size-1) downto 0);
signal prop: data_type;
signal gen: data_type;
signal carries: data_type;
signal output: data_type;

type input_carries is array((word_size - 2 ) downto 0) of std_logic_vector(word_size/4 downto 0);
signal input_carry: input_carries;

type interm_results is array((word_size/2 - 1) downto 0) of std_logic_vector(word_size+3 downto 0); ---- modified here for signed
signal chain: interm_results;

signal a_reg, b_reg, c_reg : std_logic_vector(word_size+1 downto 0) := (others => '0');
signal d_reg : std_logic_vector(1 downto 0) := (others => '0');

signal p, g, g_modified: std_logic_vector(word_size + 4 downto 0) := (others => '0');

signal s_reg : std_logic_vector(word_size + 6 downto 0) := (others => '0');

signal a1_reg, b1_reg, c1_reg : std_logic_vector(word_size+1 downto 0) := (others => '0');
signal d1_reg : std_logic_vector(1 downto 0) := (others => '0');

signal p1, g1, g1_modified: std_logic_vector(word_size + 4 downto 0) := (others => '0');

signal s1_reg : std_logic_vector(word_size + 6 downto 0) := (others => '0');
signal c1_i, c_i_last, c_i_last2: std_logic_vector(word_size+4 downto 0);
signal c_i: std_logic_vector(word_size+4 downto 0);
signal p2, g2, g2_modified: std_logic_vector(word_size + 4 downto 0) := (others => '0');
signal gen_s2, prop_s2: std_logic_vector(word_size + 3 downto 0); -- new for signed
signal s2_reg : std_logic_vector(word_size + 6 downto 0) := (others => '0');
signal c2_i, c_2_last: std_logic_vector(word_size+4 downto 0);


signal a3_reg, b3_reg, c3_reg : std_logic_vector(25 downto 0) := (others => '0');
signal d3_reg : std_logic_vector(4 downto 0) := (others => '0');


signal p3, g3, g3_modified: std_logic_vector(28 downto 0) := (others => '0');

signal s3_reg: std_logic_vector(31 downto 0):=(others => '0');

signal c3_i, c3_i_last : std_logic_vector(31 downto 0);
signal pp : std_logic_vector (word_size/2 -1 downto 0);

signal gen_s, prop_s: std_logic_vector(word_size + 3 downto 0);
signal prod_temp: std_logic_vector(word_size*2-1 downto 0);
signal s_reg_last2: std_logic_vector(word_size + 3 downto 0):=(others => '0');
begin


set_initial_carry:
for car in 0 to (word_size - 2) generate
input_carry(car)(0) <= '0';
end generate set_initial_carry;

---------- Assign Generate signals -------------------


----- LUTs Type A ------------
row_count:
for j in 0 to (word_size/2 - 2) generate -- 0 to 7
Type_A:
for i in 0 to (word_size - 3) generate -- 0 to 14
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
--------------------------------------------------

row_control:
for j in 0 to (word_size/2 -1) generate -- 0 to 7

carry_chain_type_A:										-- for word_size =8, this will loop will iterate two times (0 and 1)
for i in 0 to (word_size/4 - 1) generate	-- 0 to 3		--
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
end generate row_control;
-----------------------------------------


a_reg <= "00" & chain(0)(word_size + 1 downto 2);
b_reg <= chain(1)((word_size + 1)  downto 0);
c_reg <= chain(2)((word_size-1) downto 0) & "00";
d_reg <= chain(2)((word_size+1) downto word_size);
c_i(0) <= '0';
c_i_last(0) <='0';
c_i_last2(0) <= '0';
g(0) <= '0';

  PG0: LUT6_2
  generic map(
    INIT => X"96969696E8E8E8E8"
  )
  port map(
    O6 => p(0),
    O5 => g(1),
    I5 => '1',
    I4 => '1',
    I3 => '1',
    I2 => a_reg(0),
    I1 => b_reg(0),
    I0 => c_reg(0)
  );

  --generate the propagates for each bit for the carry chains
  genPG: for i in 1 to word_size+1 generate
  begin
    PGi: LUT6_2
    generic map(
      INIT => X"69966996E8E8E8E8"
    )
    port map(
      O6 => p(i),
      O5 => g(i+1),
      I5 => '1',
      I4 => '1',
      I3 => g(i),
      I2 => a_reg(i),
      I1 => b_reg(i),
      I0 => c_reg(i)
    );
  end generate genPG;

  PGN: LUT6_2
  generic map(
    INIT => X"17E817E8E8E8E8E8"
  )
  port map(
    O6 => p(word_size+2),   -- P(18)
    O5 => g(word_size+3),
    I5 => '1',
    I4 => '1',
    I3 => d_reg(0),
    I2 => a_reg(word_size+1),
    I1 => b_reg(word_size+1),
    I0 => c_reg(word_size+1)
  );

p(word_size+3) <= d_reg(1);  --- P(19)
g(word_size + 4) <= '0';	--g(20)
g_modified(word_size + 3 downto 0) <= g(word_size + 4 downto word_size + 3) & g(word_size + 1 downto 0);
--generate carry chains
  genCC: for i in 0 to word_size/4 generate   ---- 0 to 4
  begin
    CCi: CARRY4
      port map(
        CO  => c_i(4*i+4 downto 4*i+1),
        O   => s_reg(4*i+5 downto 4*i+2),
        CI  => c_i(4*i),
        CYINIT  => '0',
        DI  => g_modified(4*i+3 downto 4*i),
        S   => p(4*i+3 downto 4*i) 	--
      );
  end generate genCC;

s_reg(word_size + 6) <= c_i(word_size + 4);
s_reg(1 downto 0) <= chain(0)(1 downto 0);

-------------------------------------------------------------------------------
a1_reg <= "00" & chain(3)(word_size + 1 downto 2);
b1_reg <= chain(4)((word_size + 1)  downto 0);
c1_reg <= chain(5)((word_size-1) downto 0) & "00";
d1_reg <= chain(5)((word_size+1) downto word_size);
c1_i(0) <= '0';

--c1_i_last(0) <='0';

g1(0) <= '0';

  PG01: LUT6_2
  generic map(
    INIT => X"96969696E8E8E8E8"
  )
  port map(
    O6 => p1(0),
    O5 => g1(1),
    I5 => '1',
    I4 => '1',
    I3 => '1',
    I2 => a1_reg(0),
    I1 => b1_reg(0),
    I0 => c1_reg(0)
  );

  --generate the propagates for each bit for the carry chains
  genPG1: for i in 1 to word_size+1 generate
  begin
    PGi1: LUT6_2
    generic map(
      INIT => X"69966996E8E8E8E8"
    )
    port map(
      O6 => p1(i),
      O5 => g1(i+1),
      I5 => '1',
      I4 => '1',
      I3 => g1(i),
      I2 => a1_reg(i),
      I1 => b1_reg(i),
      I0 => c1_reg(i)
    );
  end generate genPG1;

  PGN1: LUT6_2
  generic map(
    INIT => X"17E817E8E8E8E8E8"
  )
  port map(
    O6 => p1(word_size+2),   -- P(18)
    O5 => g1(word_size+3),
    I5 => '1',
    I4 => '1',
    I3 => d1_reg(0),
    I2 => a1_reg(word_size+1),
    I1 => b1_reg(word_size+1),
    I0 => c1_reg(word_size+1)
  );

p1(word_size+3) <= d1_reg(1);  --- P(19)
g1(word_size + 4) <= '0';	--g(20)
g1_modified(word_size + 3 downto 0) <= g1(word_size + 4 downto word_size + 3) & g1(word_size + 1 downto 0);
--generate carry chains
  genCC1: for i in 0 to word_size/4 generate   ---- 0 to 4
  begin
    CCi1: CARRY4
      port map(
        CO  => c1_i(4*i+4 downto 4*i+1),
        O   => s1_reg(4*i+5 downto 4*i+2),
        CI  => c1_i(4*i),
        CYINIT  => '0',
        DI  => g1_modified(4*i+3 downto 4*i),
        S   => p1(4*i+3 downto 4*i) 	--
      );
  end generate genCC1;

s1_reg(word_size + 6) <= c1_i(word_size + 4);
s1_reg(1 downto 0) <= chain(3)(1 downto 0);

---------------------------------------------------------------------------------------------
--------------------------------------------------------------
chain(6)(word_size+3 downto word_size+2) <= "10"; ---- modified here for signed
last_add1:
for k in 0 to word_size + 1 generate
begin
last: LUT6_2
  generic map(
    INIT => X"6666666688888888"
  )
  port map(
    O6 => p2(k),
    O5 => g2(k),
    I5 => '1',
    I4 => '1',
    I3 => '1',
    I2 => '1',
    I1 => chain(7)(k),
    I0 => chain(6)(k + 2)
  );
end generate last_add1;
----- modified here for signed

-- p2(word_size) <= chain(7)(word_size);
-- p2(word_size+1) <= chain(7)(word_size+1);
p2(word_size + 3 downto word_size + 2) <= "11";
g2(word_size + 3 downto word_size+2) <= "00";
c2_i(0) <= '0';
last_carry2: for i in 0 to word_size/4 generate -- 0 to 4
  begin
    CCii2: CARRY4
      port map(
        CO  => c2_i(4*i+4 downto 4*i+1),
        O   => s2_reg(4*i+5 downto 4*i+2),
        CI  => c2_i(4*i),
        CYINIT  => '0',
        DI  => g2(4*i+3 downto 4*i),
        S   => p2(4*i+3 downto 4*i)
      );
  end generate last_carry2;

s2_reg(1 downto 0) <= chain(6)(1 downto 0);

------------------------------------------------------------------------------

a3_reg(22 downto 0) <= "000000" & s_reg(word_size + 6 downto 6);
b3_reg(22 downto 0) <= s1_reg((word_size + 6)  downto 0);
c3_reg(22 downto 0) <= s2_reg(word_size downto 0) & "000000";
d3_reg(4 downto 0) <= '1' & s2_reg((word_size+4) downto word_size+1); -- I have included the 1's for prop signal here. nothing special
c3_i(0) <= '0';

--c1_i_last(0) <='0';

g1(0) <= '0';

  PG03: LUT6_2
  generic map(
    INIT => X"96969696E8E8E8E8"
  )
  port map(
    O6 => p3(0),
    O5 => g3(1),
    I5 => '1',
    I4 => '1',
    I3 => '1',
    I2 => a3_reg(0),
    I1 => b3_reg(0),
    I0 => c3_reg(0)
  );

  --generate the propagates for each bit for the carry chains
  genPG3: for i in 1 to word_size+6 generate
  begin
    PGi3: LUT6_2
    generic map(
      INIT => X"69966996E8E8E8E8"
    )
    port map(
      O6 => p3(i),
      O5 => g3(i+1),
      I5 => '1',
      I4 => '1',
      I3 => g3(i),
      I2 => a3_reg(i),
      I1 => b3_reg(i),
      I0 => c3_reg(i)
    );
  end generate genPG3;

  PGN3: LUT6_2
  generic map(
    INIT => X"17E817E8E8E8E8E8"
  )
  port map(
    O6 => p3(word_size+7),   -- P(18)
    O5 => g3(word_size+8),
    I5 => '1',
    I4 => '1',
    I3 => d3_reg(0),
    I2 => a3_reg(word_size+6),
    I1 => b3_reg(word_size+6),
    I0 => c3_reg(word_size+6)
  );
p3(27 downto 24) <= d3_reg(4 downto 1);
g3(28 downto 25) <= "0000";

g3_modified(27 downto 0) <= g3(28 downto 24) & g3(22 downto 0);
--generate carry chains
  genCC3: for i in 0 to 6 generate   ---- 0 to 6
  begin
    CCi1: CARRY4
      port map(
        CO  => c3_i(4*i+4 downto 4*i+1),
        O   => s3_reg(4*i+3 downto 4*i),
        CI  => c3_i(4*i),
        CYINIT  => '0',
        DI  => g3_modified(4*i+3 downto 4*i),
        S   => p3(4*i+3 downto 4*i) 	--
      );
  end generate genCC3;


prod_temp(5 downto 0) <= s_reg(5 downto 0);
prod_temp(31 downto 6) <= s3_reg(25 downto 0);
----------------- new add for signed -------------
last1: LUT6_2
generic map (
INIT => X"6666666688888888"
)
port map (
O6 => prop_s2(0),
O5 => gen_s2(0),
I5 => '1',
I4 => '1',
I3 => '1',
I2 => '1',
I1 => prod_temp(word_size),
I0 => '1'
);


prop_s2(word_size-1 downto 1) <= prod_temp(word_size*2-1 downto word_size+1);
gen_s2(word_size-1 downto 1) <= "000000000000000";

last_carry1: for i in 0 to (word_size/4 - 1) generate
begin
  CCiii: CARRY4
    port map(
      CO  => c_i_last2(4*i+4 downto 4*i+1),
      O   => s_reg_last2(4*i+3 downto 4*i),
      CI  => c_i_last2(4*i),
      CYINIT  => '0',
      DI  => gen_s2(4*i+3 downto 4*i),
      S   => prop_s2(4*i+3 downto 4*i)
    );
end generate last_carry1;
prod (word_size-1 downto 0) <= prod_temp(word_size-1 downto 0);
prod(word_size*2-1 downto word_size) <= s_reg_last2(word_size-1 downto 0);
end Behavioral;
