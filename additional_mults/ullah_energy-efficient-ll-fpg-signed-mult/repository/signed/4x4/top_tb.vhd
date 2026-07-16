library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
use IEEE.NUMERIC_STD.ALL;

use IEEE.MATH_REAL.ALL;
use STD.TEXTIO.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;

entity top_tb is
end top_tb;

architecture Behavioral of top_tb is
constant N : integer := 4; --width
constant M : integer := 4; --height

constant mult_size : natural := 4;
signal clock : std_logic := '0';
signal reset: std_logic := '0';

signal a : std_logic_vector(N-1 downto 0) := '1' & (N-2 downto 0 => '0'); --width
signal b : std_logic_vector(M-1 downto 0) := '1' & (M-2 downto 0 => '0'); --height

signal p : std_logic_vector(N+M-1 downto 0);

signal acc_p, acc_p_reg : std_logic_vector(N+M-1 downto 0);
signal a1, a2 : std_logic_vector(N-1 downto 0) := (others => '0');
signal b1, b2 : std_logic_vector(M-1 downto 0) := (others => '0');
signal running : std_logic := '1';

signal total_clocks_sim : std_logic_vector(3*N-1 downto 0) := (3*N-8 downto 0 => '0') & "0100010" ;
constant clk_period : time := 2.58 ns;

component top is
   --width and heigth of the multiplier
  port(
  topclk : in std_logic;
  topa : in std_logic_vector(N-1 downto 0);
  topb : in std_logic_vector(M-1 downto 0);

  topp : out std_logic_vector(N+M-1 downto 0)
  );
end component;

  begin

  clock <= clock xor running after clk_period;

  DUT : top

  port map(
  topclk => clock,
  topa => a,
  topb => b,

  topp => p
  );


  Stimuli : process

  file file_results : text;
  file file_clocks : text;

  variable file_oline : line;
  variable file_oline_clock : line;

   file file_input1, file_input2 : text;
   variable file_iline1, file_iline2: line;
   variable input_a : integer;
   variable input_b : integer;
  begin

    wait for clk_period * 59;
-- I have already fixed the error
    file_open(file_clocks, "/home/salim/vivado_test_projects/signed/4x4/total_clocks.txt", write_mode);
    file_open(file_results, "/home/salim/vivado_test_projects/signed/4x4/mul_results_2.csv", write_mode);

    write(file_oline, string'("a, b, acc, approx"));
    writeline(file_results, file_oline);

    write(file_oline_clock, string'("Total number of clocks consumed for simulation: "));
    writeline(file_clocks, file_oline_clock);

    file_open(file_input1, "/home/salim/vivado_test_projects/signed/data_4/tb_in_a2.txt", read_mode);
    for i in 0 to 15 loop
      readline (file_input1, file_iline1);
      read(file_iline1, input_a);
      a <= std_logic_vector(to_signed(input_a, a'length));

     file_open(file_input2, "/home/salim/vivado_test_projects/signed/data_4/tb_in_b2.txt", read_mode);
      for j in 0 to 15 loop
        readline (file_input2, file_iline2);
        read(file_iline2, input_b);
        b <= std_logic_vector(to_signed(input_b, b'length));

       wait until rising_edge(clock);

        a1 <= a;
        b1 <= b;
        a2 <= a1;
        b2 <= b1;

        total_clocks_sim <= std_logic_vector(unsigned(total_clocks_sim) + 1);

       acc_p <= std_logic_vector(signed(a) * signed(b));
       acc_p_reg <= acc_p;

       write(file_oline, integer'image(to_integer(signed(a2))));
       write(file_oline, string'(", "));
       write(file_oline, integer'image(to_integer(signed(b2))));
       write(file_oline, string'(", "));
       write(file_oline, integer'image(to_integer(signed(acc_p_reg))));
       write(file_oline, string'(", "));
       write(file_oline, integer'image(to_integer(signed(p))));
       writeline(file_results, file_oline);

      end loop;
        file_close(file_input2);
    end loop;
    file_close(file_input1);

   wait until rising_edge(clock);
    write(file_oline, integer'image(to_integer(signed(a2))));
    write(file_oline, string'(", "));
           write(file_oline, integer'image(to_integer(signed(b2))));
           write(file_oline, string'(", "));
           write(file_oline, integer'image(to_integer(signed(acc_p_reg))));
           write(file_oline, string'(", "));
           write(file_oline, integer'image(to_integer(signed(p))));
           writeline(file_results, file_oline);

        wait until rising_edge(clock);

           write(file_oline, integer'image(to_integer(signed(a1))));
           write(file_oline, string'(", "));
           write(file_oline, integer'image(to_integer(signed(b1))));
           write(file_oline, string'(", "));
           write(file_oline, integer'image(to_integer(signed(acc_p))));
           write(file_oline, string'(", "));
           write(file_oline, integer'image(to_integer(signed(p))));
           writeline(file_results, file_oline);

    wait for clk_period * 6;

    write(file_oline_clock, integer'image(to_integer(signed(total_clocks_sim))));
    writeline(file_clocks, file_oline_clock);

    file_close(file_results);
    file_close(file_clocks);
     running <= '0';
     wait;
end process;

end Behavioral;




