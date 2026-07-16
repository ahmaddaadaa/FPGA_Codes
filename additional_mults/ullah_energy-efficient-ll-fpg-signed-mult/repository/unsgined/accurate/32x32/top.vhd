library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity top is
generic (N : integer := 32; M : integer := 32);
port(
topclk : in std_logic;
topa : in std_logic_vector(N-1 downto 0);
topb : in std_logic_vector(M-1 downto 0);

topp : out std_logic_vector(N+M-1 downto 0)
);
end top;

architecture Behavioral of top is

signal reg_in_a : std_logic_vector(N-1 downto 0);
signal reg_in_b : std_logic_vector(M-1 downto 0);

signal reg_out_p : std_logic_vector(N+M-1 downto 0);

begin

mul : entity work.goal_32x32
generic map(
    word_size => N

)
port map(
    a => reg_in_a,
    b => reg_in_b,

    prod => reg_out_p
);

RegProc: process(topclk) --register for the multiplier IO
begin
    if rising_edge(topclk) then
        reg_in_a <= topa;
        reg_in_b <= topb;

        topp <= reg_out_p;
    end if;
end process RegProc;

end Behavioral;
