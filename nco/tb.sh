#!/usr/bin/bash

iverilog -Wall -Wno-timescale -y hdl/ tb/nco_tb.v && vvp a.out
