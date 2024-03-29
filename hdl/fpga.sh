#!/usr/bin/bash

helpFunction()
{
    echo ""
    echo "Usage: $0 -u -w -p -m -h [-b <file name>] [-D <define>]"
    echo "    -u: ULX3S board."
    echo "    -w: Blue Whale board."
    echo "    -p: Run RISC-V."
    echo "    -m: Run the memory space test."
    echo "    -b: The name of the bin file to flash. Use this option only with -p -n."
    echo "    -D: define (e.g. -D CLK_PERIOD_NS)."
    echo "    -h: Help."
    exit 1 # Exit script after printing help
}

TRELLISD_DB="/home/virgild/.apio/packages/tools-oss-cad-suite/share/trellis/database"
BOARD=""
APP_NAME=""
BIN_FILE=""
RAM_FILE=""
LPF_FILE=""
SPEED=""

while getopts "uwpmhb:D:" flag; do
    case "${flag}" in
        u ) BOARD="BOARD_ULX3S" ;;
        w ) BOARD="BOARD_BLUE_WHALE" ;;
        p ) echo "Running RISC-V."; APP_NAME="risc_p" ;;
        m ) echo "Running memory space test."; APP_NAME="mem_space_test" ;;
        D ) OPTIONS="-D ${OPTARG} " ;;
        h ) helpFunction ;;
        b ) BIN_FILE=${OPTARG} ;;
        * ) helpFunction ;; #Invalid argument
    esac
done

if test -z "$BOARD"; then
    BOARD="BOARD_ULX3S"
fi

# Flags added by default by the script
#
# ENABLE_RV32M_EXT:    Multiply and divide instructions support.
# ENABLE_RV32C_EXT:    Enables/disables support for handling compressed RISC-V instructions.
# ENABLE_RV32A_EXT:    Atomic instructions support.
# ENABLE_ZBA_EXT, ENABLE_ZBB_EXT, ENABLE_ZBC_EXT, ENABLE_ZBS_EXT    : Bit manipulation extensions.
# ENABLE_ZIFENCEI_EXT: Zifencei extension.
# ENABLE_ZICOND_EXT:   Zicond extension.
# ENABLE_MHPM:         Enables support for High Performance Counters.
# ENABLE_QPI_MODE:     Use quad SPI for flash.
# ENABLE_LED_BASE      Enable LEDs on ULX3S or the ones on the BLUE_WHALE base board.
# ENABLE_LED_EXT       Enable LEDs on the BLUE_WHALE extension board.
if [ "$BOARD" = "BOARD_ULX3S" ] ; then
    echo "Running on ULX3S."
    OPTIONS="$OPTIONS -D ENABLE_RV32M_EXT -D ENABLE_RV32C_EXT -D ENABLE_RV32A_EXT \
                    -D ENABLE_ZBA_EXT -D ENABLE_ZBB_EXT -D ENABLE_ZBS_EXT \
                    -D ENABLE_ZIFENCEI_EXT -D ENABLE_ZICOND_EXT -D ENABLE_MHPM -D ENABLE_QPI_MODE -D ENABLE_LED_BASE"
    echo "OPTIONS: $OPTIONS"
    RAM_FILE="sdram.sv"
    LPF_FILE="ulx3s.lpf"
    SPEED="6"
else if [ "$BOARD" = "BOARD_BLUE_WHALE" ] ; then
    echo "Running on Blue Whale."
    OPTIONS="$OPTIONS -D ENABLE_RV32M_EXT -D ENABLE_RV32C_EXT -D ENABLE_RV32A_EXT \
                    -D ENABLE_ZBA_EXT -D ENABLE_ZBB_EXT -D ENABLE_ZBC_EXT -D ENABLE_ZBS_EXT \
                    -D ENABLE_ZIFENCEI_EXT -D ENABLE_ZICOND_EXT -D ENABLE_MHPM -D ENABLE_QPI_MODE \
                    -D ENABLE_LED_BASE -D ENABLE_LED_EXT"
    echo "OPTIONS: $OPTIONS"
    RAM_FILE="psram.sv"
    LPF_FILE="blue_whale.lpf"
    SPEED="8"
fi
fi

if test -z "$APP_NAME"; then
    helpFunction
    exit 1
fi

if test -f "out.bit"; then
    rm out.bit
fi

if test -f "out.config"; then
    rm out.config
fi

if test -f "out.json"; then
    rm out.json
fi

if [ "$APP_NAME" = "mem_space_test" ] ; then
    openFPGALoader --board ulx3s --file-type bin -o 0x600000 --unprotect-flash --write-flash ../apps/TestBlob/TestBlob.bin
    yosys -p "synth_ecp5 -noabc9 -json out.json" -D $BOARD $OPTIONS \
            uart_tx.sv uart_rx.sv utils.sv $RAM_FILE flash_master.sv io.sv timer.sv csr.sv io_bus.sv ram_bus.sv \
            mem_space.sv ecp5pll.sv mem_space_test.sv
    nextpnr-ecp5 --package CABGA381 --speed $SPEED --85k --freq 62.50 --json out.json --lpf $LPF_FILE --textcfg out.config
    ecppack --db $TRELLISD_DB out.config out.bit
    openFPGALoader -b ulx3s out.bit
else if [ "$APP_NAME" = "risc_p" ] ; then
    if test ! -z "$BIN_FILE"; then
        echo "Flashing bin file: $BIN_FILE ..."
        openFPGALoader --board ulx3s --file-type bin -o 0x600000 --unprotect-flash --write-flash $BIN_FILE
    fi
    yosys -p "synth_ecp5 -noabc9 -json out.json" -D $BOARD $OPTIONS \
            uart_tx.sv uart_rx.sv decoder.sv regfile.sv utils.sv exec.sv divider.sv multiplier.sv flash_master.sv \
            $RAM_FILE io.sv timer.sv csr.sv io_bus.sv ram_bus.sv mem_space.sv ecp5pll.sv risc_p.sv
    nextpnr-ecp5 --package CABGA381 --speed $SPEED --85k --freq 62.50 --json out.json --lpf $LPF_FILE --textcfg out.config
    ecppack --db $TRELLISD_DB out.config out.bit
    openFPGALoader -b ulx3s out.bit
fi
fi
