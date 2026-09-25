## N-2.5 probe constraints for noc_mesh_synth_top on Arty A7-100T (xc7a100tcsg324-1)
## Pins from memory of the Digilent Arty-A7-100 master XDC - verify before
## generating a bitstream: CLK100MHZ=E3, btn[0]=D9, led[0]=H5.
set_property -dict { PACKAGE_PIN E3 IOSTANDARD LVCMOS33 } [get_ports clk]
set_property -dict { PACKAGE_PIN D9 IOSTANDARD LVCMOS33 } [get_ports rst]
set_property -dict { PACKAGE_PIN H5 IOSTANDARD LVCMOS33 } [get_ports led]

## Timing target: 50 MHz (20 ns). The board oscillator is 100 MHz; this probe
## asks "does the mesh close at 50 MHz?" - an MMCM is added at SoC integration.
create_clock -name clk -period 20.000 [get_ports clk]

## rst is a push-button (synchronised inside the wrapper), led is a status pin.
set_false_path -from [get_ports rst]
set_false_path -to   [get_ports led]
