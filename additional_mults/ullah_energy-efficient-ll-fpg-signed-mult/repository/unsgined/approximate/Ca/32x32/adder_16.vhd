----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 11/20/2017 08:10:36 PM
-- Design Name: 
-- Module Name: adder_16 - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values----------------------------------------------------------------------------------
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity adder_16 is
    generic (
      N : positive := 16);

    Port ( prod1      : in std_logic_vector(N-1 downto 0);
           prod2      : in std_logic_vector(N-1 downto 0);
           prod3      : in std_logic_vector(N-1 downto 0);
           prod4      : in std_logic_vector(N-1 downto 0);
           --c_in   : in std_logic;
           PROD      : out std_logic_vector(2*N-1 downto 0));
--           c_out  : out std_logic);
end adder_16;

architecture Behavioral of adder_16 is

  signal a_reg, b_reg, c_reg : std_logic_vector(N-1 downto 0) := (others => '0');
  signal d_reg : std_logic_vector(N/2-1 downto 0) := (others => '0');
  signal p, g : std_logic_vector(N+N/2 downto 0) := (others => '0');
  signal s_reg : std_logic_vector(2*N-1 downto 0) := (others => '0');
  signal c_in : std_logic;
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
  PROD(31 downto 0) <= s_reg;
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
  
  
 CCi1: CARRY4
       port map(
         CO  => c_i(4 downto 1),
         O   => s_reg(11 downto 8),
         CI  => c_i(0),
         CYINIT  => '0',
         DI  => g(3 downto 0),
         S   => p(3 downto 0)
       );
  
 CCi2: CARRY4
             port map(
               CO  => c_i(8 downto 5),
               O   => s_reg(15 downto 12),
               CI  => c_i(4),
               CYINIT  => '0',
               DI  => g(7 downto 4),
               S   => p(7 downto 4)
             );  
  
 CCi3: CARRY4
                         port map(
                           CO  => c_i(12 downto 9),
                           O   => s_reg(19 downto 16),
                           CI  => c_i(8),
                           CYINIT  => '0',
                           DI  => g(11 downto 8),
                           S   => p(11 downto 8)
                         );    
  
  
CCi4: CARRY4
       port map(
       CO  => c_i(16 downto 13),
       O   => s_reg(23 downto 20),
      CI  => c_i(12),
     CYINIT  => '0',
    DI  => g(15 downto 12),
    S   => p(15 downto 12)
   );          

  
CCi5: CARRY4
       port map(
       CO  => c_i(20 downto 17),
       O   => s_reg(27 downto 24),
      CI  => c_i(16),
     CYINIT  => '0',
    DI  => g(19 downto 16),
    S   => p(19 downto 16)
   );          
      
  
 CCi6: CARRY4
        port map(
        CO  => c_i(24 downto 21),
        O   => s_reg(31 downto 28),
       CI  => c_i(20),
      CYINIT  => '0',
     DI  => g(23 downto 20),
     S   => p(23 downto 20)
    );          
                      
--  --generate carry chains
--  genCC: for i in 0 to N/4-1 generate
--  begin  
--    CCi: CARRY4
--      port map(
--        CO  => c_i(4*i+4 downto 4*i+1),
--        O   => s_reg(4*i+N-1 downto 4*i+N/2),
--        CI  => c_i(4*i),
--        CYINIT  => '0',
--        DI  => g(4*i+3 downto 4*i),
--        S   => p(4*i+3 downto 4*i)
--      );
--  end generate genCC;
  
--  CCN: CARRY4
--    port map(
--      CO => c_i(N+4 downto N+1),
--      O  => s_reg(N+N-1 downto N+N/2),
--      CI => c_i(N),
--      CYINIT => '0',
--      DI => g(N+4 downto N+1),
--      S  => p(N+3 downto N)
--    );

--CCN1: CARRY4
--    port map(
--      CO => c_i(N+4 downto N+1),
--      O  => s_reg(N+N-1 downto N+N/2),
--      CI => c_i(N),
--      CYINIT => '0',
--      DI => g(N+4 downto N+1),
--      S  => p(N+3 downto N)
--    );

end Behavioral;
