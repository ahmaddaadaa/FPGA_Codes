
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity adder_32 is
    generic (
      N : Natural := 32);

    Port ( prod1      : in std_logic_vector(N-1 downto 0);
           prod2      : in std_logic_vector(N-1 downto 0);
           prod3      : in std_logic_vector(N-1 downto 0);
           prod4      : in std_logic_vector(N-1 downto 0);
           --c_in   : in std_logic;
           PROD      : out std_logic_vector(2*N-1 downto 0));
--           c_out  : out std_logic);
end adder_32;

architecture Behavioral of adder_32 is

  signal a_reg, b_reg, c_reg : std_logic_vector(N-1 downto 0) := (others => '0');
  signal d_reg : std_logic_vector(N/2-1 downto 0) := (others => '0');
  signal p, g : std_logic_vector(N+N/2 downto 0) := (others => '0');
  signal s_reg : std_logic_vector(2*N-1 downto 0) := (others => '0');
  signal c_in : std_logic :='0';
  signal c_out : std_logic;
  signal c_i : std_logic_vector(2*N-1 downto 0);

begin

  ------------------------signal assignment------------------------

  a_reg <= prod4(N/2-1 downto 0) & prod1(N-1 downto N/2);
  b_reg <= prod2;
  c_reg <= prod3;
  d_reg <= prod4(N-1 downto N/2);

  c_i(0) <= c_in;
  g(0) <= '0';
  g(N+N/2 downto N+2) <= (others => '0');
  p(N+N/2-1 downto N+1) <= d_reg(N/2-1 downto 1);

  s_reg(N/2-1 downto 0) <= prod1(N/2-1 downto 0);
  PROD <= s_reg;
  c_out <= c_i(N+4);

  -----------------------------RCA part----------------------------

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
  genPG: for i in 1 to N-1 generate
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
    O6 => p(N),
    O5 => g(N+1),
    I5 => '1',
    I4 => '1',
    I3 => d_reg(0),
    I2 => a_reg(N-1),
    I1 => b_reg(N-1),
    I0 => c_reg(N-1)
  );

  --generate carry chains
  genCC: for i in 0 to N/4-1 generate
  begin
    CCi: CARRY4
      port map(
        CO  => c_i(4*i+4 downto 4*i+1), --- for N 16: i 0 to 3 => c_i(16 downto 13)
        O   => s_reg(4*i+N/2+3 downto 4*i+N/2),
        CI  => c_i(4*i),
        CYINIT  => '0',
        DI  => g(4*i+3 downto 4*i),
        S   => p(4*i+3 downto 4*i) -- for N 16: p(15 downto 12)
      );
  end generate genCC;

  genCC1: for j in 0 to (N/2)/4-1 generate -- 8/2 => 4/4 => 1-1 => 0.... 16/2 => 8/4 => 2-1 => 1... 32/2 => 16/4 => 4-1=> 3
  begin
    CCi: CARRY4
      port map(
        CO  => c_i(j*4+N+4 downto j*4+N+1), -- for N 16: j 0 to 1 => for j 0 => c_i(20 downto 17) and for j 1 => c_i(24 downto 21)
        O   => s_reg(j*4+N+N/2+3 downto j*4+N+N/2),
        CI  => c_i(j*4+N),
        CYINIT  => '0',
        DI  => g(j*4+N+4 downto j*4+N+1),
        S   => p(j*4+N+3 downto j*4+N) -- for N 16: j 0 to 1 => for j 0 => p(19 downto 16) and p(23 downto 20)
      );
  end generate genCC1;




end Behavioral;
