# syn/constraints_ooc_orderbook.xdc
# OOC clock constraint for order_book — must match top-level sys_clk period.
create_clock -name clk -period 3.200 [get_ports clk]
