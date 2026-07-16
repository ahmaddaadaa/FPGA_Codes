library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
library UNISIM;
use UNISIM.VComponents.all;

entity goal_32x32 is
generic (word_size: integer:=32);
Port (
a : in  STD_LOGIC_VECTOR (word_size-1 downto 0);
b : in  STD_LOGIC_VECTOR (word_size-1 downto 0);

prod: out STD_LOGIC_VECTOR (word_size * 2 - 1 downto 0));
end goal_32x32;

architecture Behavioral of goal_32x32 is

type data_type is array((word_size/2 -1) downto 0) of std_logic_vector((word_size-1) downto 0);
signal prop: data_type;
signal gen: data_type;
signal carries: data_type;
signal output: data_type;

type input_carries is array((word_size - 2 ) downto 0) of std_logic_vector(word_size/4 downto 0);
signal input_carry: input_carries;

type interm_results is array((word_size/2 - 1) downto 0) of std_logic_vector(word_size+1 downto 0);
signal chain: interm_results;

signal a_reg, b_reg, c_reg : std_logic_vector(word_size+1 downto 0) := (others => '0');
signal d_reg : std_logic_vector(1 downto 0) := (others => '0');

signal p, g, g_modified: std_logic_vector(word_size + 4 downto 0) := (others => '0');

signal s_reg : std_logic_vector(word_size + 6 downto 0) := (others => '0');

signal a1_reg, b1_reg, c1_reg : std_logic_vector(word_size+1 downto 0) := (others => '0');
signal d1_reg : std_logic_vector(1 downto 0) := (others => '0');

signal p1, g1, g1_modified: std_logic_vector(word_size + 4 downto 0) := (others => '0');

signal s1_reg : std_logic_vector(word_size + 6 downto 0) := (others => '0');
signal c1_i, c_i_last: std_logic_vector(word_size+4 downto 0);
signal c_i: std_logic_vector(word_size+4 downto 0);
signal p2, g2, g2_modified: std_logic_vector(47 downto 0) := (others => '0');

signal s2_reg : std_logic_vector(47 downto 0) := (others => '0');
signal c2_i, c_2_last: std_logic_vector(48 downto 0);


signal a3_reg, b3_reg, c3_reg : std_logic_vector(25 downto 0) := (others => '0');
signal d3_reg : std_logic_vector(4 downto 0) := (others => '0');


signal p3, g3, g3_modified: std_logic_vector(28 downto 0) := (others => '0');

signal s3_reg: std_logic_vector(31 downto 0):=(others => '0');

signal c3_i, c3_i_last : std_logic_vector(31 downto 0);
signal pp : std_logic_vector (word_size/2 -1 downto 0);

signal gen_s, prop_s: std_logic_vector(word_size + 3 downto 0);

--signal a, b : std_logic_vector(word_size -1 downto 0);
--signal prod : std_logic_vector(2*word_size - 1 downto 0);
signal s_before_final0: std_logic_vector(51 downto 0):= (others => '0');
signal s_before_final1: std_logic_vector(46 downto 0):= (others => '0');
signal c2nd_last0_i, s2nd_last0_reg : std_logic_vector(48 downto 0) := (others => '0');
signal g2nd_last0: std_logic_vector(48 downto 0) := (others => '0');
signal p2nd_last0, g2nd_last0_modified: std_logic_vector(47 downto 0) := (others => '0');
signal a2nd_last0_reg, b2nd_last0_reg, c2nd_last0_reg: std_logic_vector (38 downto 0):= (others => '0');
signal d2nd_last0_reg: std_logic_vector (5 downto 0):= (others => '0');
--signal s_before_final1: std_logic_vector(46 downto 0):= (others => '0');
signal p2nd_last1, g2nd_last1_modified : std_logic_vector(43 downto 0):= (others => '0');
signal g2nd_last1: std_logic_vector(44 downto 0):= (others => '0');
signal s2nd_last1_i: std_logic_vector(43 downto 0):= (others => '0');
signal c2nd_last1_i: std_logic_vector(44 downto 0):= (others => '0');
signal a2nd_last1_reg, b2nd_last1_reg, c2nd_last1_reg: std_logic_vector(38 downto 0):= (others => '0');
signal d2nd_last1_reg: std_logic;
signal s14_reg, s11_reg, s8_reg: std_logic_vector(38 downto 0):= (others => '0');
signal c14_i, c11_i, c8_i: std_logic_vector(36 downto 0):= (others => '0');
signal g14_modified, p14, p11, g11_modified, p8, g8_modified: std_logic_vector(35 downto 0):= (others => '0');
signal g14, g11, g8: std_logic_vector(36 downto 0):= (others => '0');
signal a14_reg, b14_reg, c14_reg, a11_reg, b11_reg, c11_reg, a8_reg, b8_reg, c8_reg: std_logic_vector(33 downto 0):= (others => '0');
signal d14_reg, d11_reg, d8_reg: std_logic_vector(1 downto 0):= (others => '0');

signal s2nd_last1_reg: std_logic_vector(39 downto 0):= (others => '0');
--signal g8 : std_logic_vector(36 downto 0):= (others => '0');
--signal g8_modified, p8 : std_logic_vector(35 downto 0):= (others => '0');

begin

set_initial_carry:
for car in 0 to (word_size - 2) generate
input_carry(car)(0) <= '0';
end generate set_initial_carry;

---------- Assign Generate signals -------------------


----- LUTs Type A ------------
row_count:
for j in 0 to (word_size/2 - 1) generate -- 0 to 7
Type_A:
for i in 0 to (word_size - 2) generate -- 0 to 14
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

------------- End of Type A LUTs ---------

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

-------------------------------------------------------------------------------
a8_reg <= "00" & chain(6)(word_size + 1 downto 2);
b8_reg <= chain(7)((word_size + 1)  downto 0);
c8_reg <= chain(8)((word_size-1) downto 0) & "00";
d8_reg <= chain(8)((word_size+1) downto word_size);
c8_i(0) <= '0';

--c1_i_last(0) <='0';

g8(0) <= '0';

  PG08: LUT6_2
  generic map(
    INIT => X"96969696E8E8E8E8"
  )
  port map(
    O6 => p8(0),
    O5 => g8(1),
    I5 => '1',
    I4 => '1',
    I3 => '1',
    I2 => a8_reg(0),
    I1 => b8_reg(0),
    I0 => c8_reg(0)
  );

  --generate the propagates for each bit for the carry chains
  genPG8: for i in 1 to word_size+1 generate
  begin
    PGi8: LUT6_2
    generic map(
      INIT => X"69966996E8E8E8E8"
    )
    port map(
      O6 => p8(i),
      O5 => g8(i+1),
      I5 => '1',
      I4 => '1',
      I3 => g8(i),
      I2 => a8_reg(i),
      I1 => b8_reg(i),
      I0 => c8_reg(i)
    );
  end generate genPG8;

  PGN8: LUT6_2
  generic map(
    INIT => X"17E817E8E8E8E8E8"
  )
  port map(
    O6 => p8(word_size+2),   -- P(18)
    O5 => g8(word_size+3),
    I5 => '1',
    I4 => '1',
    I3 => d8_reg(0),
    I2 => a8_reg(word_size+1),
    I1 => b8_reg(word_size+1),
    I0 => c8_reg(word_size+1)
  );

p8(word_size+3) <= d8_reg(1);  --- P(19)
g8(word_size + 4) <= '0';	--g(20)
g8_modified(word_size + 3 downto 0) <= g8(word_size + 4 downto word_size + 3) & g8(word_size + 1 downto 0);
--generate carry chains
  genCC8: for i in 0 to word_size/4 generate   ---- 0 to 4
  begin
    CCi8: CARRY4
      port map(
        CO  => c8_i(4*i+4 downto 4*i+1),
        O   => s8_reg(4*i+5 downto 4*i+2),
        CI  => c8_i(4*i),
        CYINIT  => '0',
        DI  => g8_modified(4*i+3 downto 4*i),
        S   => p8(4*i+3 downto 4*i) 	--
      );
  end generate genCC8;

s8_reg(word_size + 6) <= c8_i(word_size + 4);
s8_reg(1 downto 0) <= chain(6)(1 downto 0);

--------------------------------------------------------------

-------------------------------------------------------------------------------
a11_reg <= "00" & chain(9)(word_size + 1 downto 2);
b11_reg <= chain(10)((word_size + 1)  downto 0);
c11_reg <= chain(11)((word_size-1) downto 0) & "00";
d11_reg <= chain(11)((word_size+1) downto word_size);
c11_i(0) <= '0';

--c1_i_last(0) <='0';

g11(0) <= '0';

  PG011: LUT6_2
  generic map(
    INIT => X"96969696E8E8E8E8"
  )
  port map(
    O6 => p11(0),
    O5 => g11(1),
    I5 => '1',
    I4 => '1',
    I3 => '1',
    I2 => a11_reg(0),
    I1 => b11_reg(0),
    I0 => c11_reg(0)
  );

  --generate the propagates for each bit for the carry chains
  genPG11: for i in 1 to word_size+1 generate
  begin
    PGi11: LUT6_2
    generic map(
      INIT => X"69966996E8E8E8E8"
    )
    port map(
      O6 => p11(i),
      O5 => g11(i+1),
      I5 => '1',
      I4 => '1',
      I3 => g11(i),
      I2 => a11_reg(i),
      I1 => b11_reg(i),
      I0 => c11_reg(i)
    );
  end generate genPG11;

  PGN11: LUT6_2
  generic map(
    INIT => X"17E817E8E8E8E8E8"
  )
  port map(
    O6 => p11(word_size+2),   -- P(18)
    O5 => g11(word_size+3),
    I5 => '1',
    I4 => '1',
    I3 => d11_reg(0),
    I2 => a11_reg(word_size+1),
    I1 => b11_reg(word_size+1),
    I0 => c11_reg(word_size+1)
  );

p11(word_size+3) <= d11_reg(1);  --- P(19)
g11(word_size + 4) <= '0';	--g(20)
g11_modified(word_size + 3 downto 0) <= g11(word_size + 4 downto word_size + 3) & g11(word_size + 1 downto 0);
--generate carry chains
  genCC11: for i in 0 to word_size/4 generate   ---- 0 to 4
  begin
    CCi11: CARRY4
      port map(
        CO  => c11_i(4*i+4 downto 4*i+1),
        O   => s11_reg(4*i+5 downto 4*i+2),
        CI  => c11_i(4*i),
        CYINIT  => '0',
        DI  => g11_modified(4*i+3 downto 4*i),
        S   => p11(4*i+3 downto 4*i) 	--
      );
  end generate genCC11;

s11_reg(word_size + 6) <= c11_i(word_size + 4);
s11_reg(1 downto 0) <= chain(9)(1 downto 0);

--------------------------------------------------------------


-------------------------------------------------------------------------------
a14_reg <= "00" & chain(12)(word_size + 1 downto 2);
b14_reg <= chain(13)((word_size + 1)  downto 0);
c14_reg <= chain(14)((word_size-1) downto 0) & "00";
d14_reg <= chain(14)((word_size+1) downto word_size);
c14_i(0) <= '0';

--c1_i_last(0) <='0';

g14(0) <= '0';

  PG014: LUT6_2
  generic map(
    INIT => X"96969696E8E8E8E8"
  )
  port map(
    O6 => p14(0),
    O5 => g14(1),
    I5 => '1',
    I4 => '1',
    I3 => '1',
    I2 => a14_reg(0),
    I1 => b14_reg(0),
    I0 => c14_reg(0)
  );

  --generate the propagates for each bit for the carry chains
  genPG14: for i in 1 to word_size+1 generate
  begin
    PGi14: LUT6_2
    generic map(
      INIT => X"69966996E8E8E8E8"
    )
    port map(
      O6 => p14(i),
      O5 => g14(i+1),
      I5 => '1',
      I4 => '1',
      I3 => g14(i),
      I2 => a14_reg(i),
      I1 => b14_reg(i),
      I0 => c14_reg(i)
    );
  end generate genPG14;

  PGN14: LUT6_2
  generic map(
    INIT => X"17E817E8E8E8E8E8"
  )
  port map(
    O6 => p14(word_size+2),   -- P(18)
    O5 => g14(word_size+3),
    I5 => '1',
    I4 => '1',
    I3 => d14_reg(0),
    I2 => a14_reg(word_size+1),
    I1 => b14_reg(word_size+1),
    I0 => c14_reg(word_size+1)
  );

p14(word_size+3) <= d14_reg(1);  --- P(19)
g14(word_size + 4) <= '0';	--g(20)
g14_modified(word_size + 3 downto 0) <= g14(word_size + 4 downto word_size + 3) & g14(word_size + 1 downto 0);
--generate carry chains
  genCC14: for i in 0 to word_size/4 generate   ---- 0 to 4
  begin
    CCi14: CARRY4
      port map(
        CO  => c14_i(4*i+4 downto 4*i+1),
        O   => s14_reg(4*i+5 downto 4*i+2),
        CI  => c14_i(4*i),
        CYINIT  => '0',
        DI  => g14_modified(4*i+3 downto 4*i),
        S   => p14(4*i+3 downto 4*i) 	--
      );
  end generate genCC14;

s14_reg(word_size + 6) <= c14_i(word_size + 4);
s14_reg(1 downto 0) <= chain(12)(1 downto 0);

--------------------------------------------------------------

-------------------------------------------------------------------------------
a2nd_last1_reg <= "000000" & s11_reg(38 downto 6);
b2nd_last1_reg <= s14_reg(38  downto 0);
c2nd_last1_reg <= chain(15)(32 downto 0) & "000000";
d2nd_last1_reg <= chain(15)(33);
c2nd_last1_i(0) <= '0';

--c1_i_last(0) <='0';

g2nd_last1(0) <= '0';

  PG02nd_last1: LUT6_2
  generic map(
    INIT => X"96969696E8E8E8E8"
  )
  port map(
    O6 => p2nd_last1(0),
    O5 => g2nd_last1(1),
    I5 => '1',
    I4 => '1',
    I3 => '1',
    I2 => a2nd_last1_reg(0),
    I1 => b2nd_last1_reg(0),
    I0 => c2nd_last1_reg(0)
  );

  --generate the propagates for each bit for the carry chains
  genPG2nd_last1: for i in 1 to word_size+6 generate
  begin
    PGi2nd_last1: LUT6_2
    generic map(
      INIT => X"69966996E8E8E8E8"
    )
    port map(
      O6 => p2nd_last1(i),
      O5 => g2nd_last1(i+1),
      I5 => '1',
      I4 => '1',
      I3 => g2nd_last1(i),
      I2 => a2nd_last1_reg(i),
      I1 => b2nd_last1_reg(i),
      I0 => c2nd_last1_reg(i)
    );
  end generate genPG2nd_last1;

  PGN2nd_last1: LUT6_2
  generic map(
    INIT => X"17E817E8E8E8E8E8"
  )
  port map(
    O6 => p2nd_last1(word_size+7),   -- P(18)
    O5 => g2nd_last1(word_size+8),
    I5 => '1',
    I4 => '1',
    I3 => d2nd_last1_reg,
    I2 => a2nd_last1_reg(word_size+6),
    I1 => b2nd_last1_reg(word_size+6),
    I0 => c2nd_last1_reg(word_size+6)
  );

--p2nd_last1(40) <= d2nd_last1_reg(1);  --- P(19)
--p2nd_last1(43 downto 41) <= "111";  --- P(19)
g2nd_last1(41) <= '0';	--g(20)
--g2nd_last1(44 downto 42) <= "000";	--g(20)
g2nd_last1_modified(39 downto 0) <= g2nd_last1(40) & g2nd_last1(38 downto 0);
--generate carry chains
  genCC2nd_last1: for i in 0 to 9 generate   ---- 0 to 4
  begin
    CCi2nd_last1: CARRY4
      port map(
        CO  => c2nd_last1_i(4*i+4 downto 4*i+1),
        O   => s2nd_last1_reg(4*i+3 downto 4*i),
        CI  => c2nd_last1_i(4*i),
        CYINIT  => '0',
        DI  => g2nd_last1_modified(4*i+3 downto 4*i),
        S   => p2nd_last1(4*i+3 downto 4*i) 	--
      );
  end generate genCC2nd_last1;

--sg2nd_last1_modified_reg(word_size + 6) <= cg2nd_last1_modified_i(41);
--sg2nd_last0_modified_reg(5 downto 0) <= s_reg(5 downto 0);

s_before_final1(45 downto 6) <= s2nd_last1_reg(39 downto 0);
s_before_final1(46) <= c2nd_last1_i(40);
s_before_final1(5 downto 0) <= s11_reg(5 downto 0);

--------------------------------------------------------------
--------------------------------------------------------------
a2nd_last0_reg <= "000000" & s_reg(38 downto 6);
b2nd_last0_reg <= s1_reg(38  downto 0);
c2nd_last0_reg <= s8_reg(32 downto 0) & "000000";
d2nd_last0_reg <= s8_reg(38 downto 33);
c2nd_last0_i(0) <= '0';

--c1_i_last(0) <='0';

g2nd_last0(0) <= '0';

  PG02nd_last0: LUT6_2
  generic map(
    INIT => X"96969696E8E8E8E8"
  )
  port map(
    O6 => p2nd_last0(0),
    O5 => g2nd_last0(1),
    I5 => '1',
    I4 => '1',
    I3 => '1',
    I2 => a2nd_last0_reg(0),
    I1 => b2nd_last0_reg(0),
    I0 => c2nd_last0_reg(0)
  );

  --generate the propagates for each bit for the carry chains
  genPG2nd_last0: for i in 1 to word_size+6 generate
  begin
    PGi2nd_last0: LUT6_2
    generic map(
      INIT => X"69966996E8E8E8E8"
    )
    port map(
      O6 => p2nd_last0(i),
      O5 => g2nd_last0(i+1),
      I5 => '1',
      I4 => '1',
      I3 => g2nd_last0(i),
      I2 => a2nd_last0_reg(i),
      I1 => b2nd_last0_reg(i),
      I0 => c2nd_last0_reg(i)
    );
  end generate genPG2nd_last0;

  PGN2nd_last0: LUT6_2
  generic map(
    INIT => X"17E817E8E8E8E8E8"
  )
  port map(
    O6 => p2nd_last0(word_size+7),   -- P(18)
    O5 => g2nd_last0(word_size+8),
    I5 => '1',
    I4 => '1',
    I3 => d2nd_last0_reg(0),
    I2 => a2nd_last0_reg(word_size+6),
    I1 => b2nd_last0_reg(word_size+6),
    I0 => c2nd_last0_reg(word_size+6)
  );

p2nd_last0(44 downto 40) <= d2nd_last0_reg(5 downto 1);  --- P(19)
p2nd_last0(47 downto 45) <= "111";  --- P(19)
g2nd_last0(45 downto 41) <= "00000";	--g(20)
g2nd_last0(48 downto 46) <= "000";	--g(20)
g2nd_last0_modified(47 downto 0) <= g2nd_last0(48 downto 40) & g2nd_last0(38 downto 0);
--generate carry chains
  genCC2nd_last0: for i in 0 to 11 generate   ---- 0 to 4
  begin
    CCi2nd_last0: CARRY4
      port map(
        CO  => c2nd_last0_i(4*i+4 downto 4*i+1),
        O   => s2nd_last0_reg(4*i+3 downto 4*i), -------------- 53 downto 50. 50 is required.
        CI  => c2nd_last0_i(4*i),
        CYINIT  => '0',
        DI  => g2nd_last0_modified(4*i+3 downto 4*i),
        S   => p2nd_last0(4*i+3 downto 4*i) 	--
      );
  end generate genCC2nd_last0;

--sg2nd_last0_modified_reg(word_size + 6) <= cg2nd_last0_modified_i(48);
s_before_final0(50 downto 6) <= s2nd_last0_reg(44 downto 0);
s_before_final0(51) <= c2nd_last0_i(45);
s_before_final0(5 downto 0) <= s_reg(5 downto 0);

--------------------------------------------------------------
--------------------------------------------------------------
last_add1:
for k in 0 to word_size  generate
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
    I1 => s_before_final1(k),
    I0 => s_before_final0(k + 18)
  );
end generate last_add1;
p2(45 downto 33) <= s_before_final1(45 downto 33);
p2(47 downto 46) <= "11";
g2(47 downto 33) <= "000000000000000";

c2_i(0) <= '0';
last_carry2: for i in 0 to 11 generate -- 0 to 4
  begin
    CCii2: CARRY4
      port map(
        CO  => c2_i(4*i+4 downto 4*i+1),
        O   => s2_reg(4*i+3 downto 4*i),
        CI  => c2_i(4*i),
        CYINIT  => '0',
        DI  => g2(4*i+3 downto 4*i),
        S   => p2(4*i+3 downto 4*i)
      );
  end generate last_carry2;


  prod (63 downto 18) <= s2_reg(45 downto 0);
  prod(17 downto 0) <= s_before_final0(17 downto 0);
end Behavioral;
