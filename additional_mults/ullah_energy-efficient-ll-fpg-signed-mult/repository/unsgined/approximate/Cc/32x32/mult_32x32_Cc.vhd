library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
library UNISIM;
use UNISIM.VComponents.all;
entity mult_32x32 is
generic (mult_size: integer:= 32);
Port (
a : in  STD_LOGIC_VECTOR (mult_size-1 downto 0);
b : in  STD_LOGIC_VECTOR (mult_size-1 downto 0);
prod: out STD_LOGIC_VECTOR (mult_size * 2 - 1 downto 0));
end mult_32x32;

architecture Behavioral of mult_32x32 is

	component mult_16x16 is

		Port (a: in STD_LOGIC_VECTOR(15 downto 0);
		b: in STD_LOGIC_VECTOR(15 downto 0);
		prod: out STD_LOGIC_VECTOR(31 downto 0));
	end component;

	type pps is array(3 downto 0) of std_logic_vector(mult_size - 1 downto 0);
	signal prod_sig: pps;
	signal sum, carr: std_logic_vector(mult_size downto 0);
	constant mult_size_half : integer := mult_size/2;
	begin
	pp_gen:
	for i in 0 to 1 generate
		second:
		for j in 0 to 1 generate
			inst0_mult: mult_16x16
			port map (
				a => a(mult_size_half*i+(mult_size_half-1) downto mult_size_half*i),
				b => b(mult_size_half*j+(mult_size_half-1) downto mult_size_half*j),
				prod => prod_sig(i * (mult_size/mult_size_half) + j)
			);
		end generate second;
	end generate pp_gen;

	pp_add:
	for k in 0 to (mult_size/2 - 1) generate
		lut_inst0: lut6_2
		generic map(INIT => X"9696969696969696")
		port map(
			I0 => prod_sig(0)(k + mult_size_half),
			I1 => prod_sig(1)(k),
			I2 => prod_sig(2)(k),
			I3 => '1',
			I4 => '1',
			I5 => '1',
			O6 => sum(k)
		);
	end generate pp_add;

	pp_add1:
	for l in 0 to (mult_size/2 - 1) generate
		lut_inst1: lut6_2
		generic map(INIT => X"9696969696969696")
		port map(
			I0 => prod_sig(1)(l + mult_size_half),
			I1 => prod_sig(2)(l + mult_size_half),
			I2 => prod_sig(3)(l),
			I3 => '1',
			I4 => '1',
			I5 => '1',
			O6 => sum(l + mult_size_half)
		);
	end generate pp_add1;

	assign_values0:
	for r in 0 to mult_size/2 - 1 generate
		prod(r) <= prod_sig(0)(r);
	end generate assign_values0;

	assign_values1:
	for s in 0 to mult_size - 1 generate
		prod(s + (mult_size/2)) <= sum(s);
	end generate assign_values1;

	assign_values3:
	for t in mult_size/2 to mult_size - 1 generate
		prod(t + mult_size) <= prod_sig(3)(t);
	end generate assign_values3;

end Behavioral;
