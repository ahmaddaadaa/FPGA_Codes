library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sync_ram_s32 is
    generic (
        DEPTH      : integer := 4;
        ADDR_WIDTH : integer := 2
    );
    port (
        clk : in std_logic;

        ----------------------------------------------------------------
        -- Write port
        ----------------------------------------------------------------
        we    : in  std_logic;
        waddr : in  unsigned(ADDR_WIDTH - 1 downto 0);
        wdata : in  signed(31 downto 0);

        ----------------------------------------------------------------
        -- Read port
        ----------------------------------------------------------------
        raddr : in  unsigned(ADDR_WIDTH - 1 downto 0);
        rdata : out signed(31 downto 0)
    );
end entity;

architecture rtl of sync_ram_s32 is

    type ram_t is array (0 to DEPTH - 1) of signed(31 downto 0);
    signal ram : ram_t := (others => (others => '0'));

    attribute ram_style : string;
    attribute ram_style of ram : signal is "block";

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if we = '1' then
                ram(to_integer(waddr)) <= wdata;
            end if;

            rdata <= ram(to_integer(raddr));
        end if;
    end process;

end architecture;