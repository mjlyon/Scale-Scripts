#!/usr/bin/bash
#
# Displays sane P and e-core sensor groupings
# Determines P core count by SMT count; remainder e-cores
# - Removed 'hud' arg, just specify time for persistent display
# - Added csv output option with filename generation specification
# This was written by Chris Nietzold and has no warranty implied or otherwise
# Changed by M Lyon to adjust XLS output options 

# Capture sensor output, determine P/E core topology, core arch names
sense=($(sensors | grep Core | awk '{print $3}'))
package=$(sensors | grep Package | awk '{print $4}')
pcores=$(cpuid -S | grep "SMT_ID=1" | wc -l)
lastpcore=$((pcores - 1))
lastecore=$(lscpu -e | tail -n 1 | awk '{print $4}')
ecores=$((lastecore - lastpcore))
pname=$(cpuid -S | grep -m 1 "(synth)" | awk -F'[][]' '{print $2}')
ename=$(cpuid -S | grep "(synth)" | tail -n 1 | awk -F'[][]' '{print $2}')

# Initialize global arrays as temperature pools over time
avgP=()
avgE=()

usage(){
    echo ""
    echo "  usage: $0 [time] [-csv] [csv_filename]"
    echo "  [time] can be noted as (s)econds, (m)inutes, or (h)ours"
    echo "  > ex: '$0 30s -csv myTemps' will log to myTemps.csv for 30 seconds"
    echo "  > ex: '$0 2h -csv' will log to a generated CSV for 2 hours "
    echo "  > ex: '$0 10m' will display values for 10 minutes "
    echo "  All arguments are optional"; echo ""
}

# When looping, we need to refresh the sensor values
resense(){
    unset sense
    sense=($(sensors | grep Core | awk '{print $3}'))
    package=$(sensors | grep Package | awk '{print $4}')
}

# Clear arrays and variables on exit
cleanup(){
    unset sense; unset pcores; unset ecores
    unset lastpcore; unset lastecore
    unset pHigh; unset eHigh; unset avgP; unset avgE
    [ ! -z "$csvfile" ] && (echo " --> CSV saved to ${csvfile}" && echo "")
    exit 0
}

# Output formatted csv
# Format = (date/time),(pHighT),(mpAvgT),(eHighT),(meAvgT),(packageT)
output_csv(){
    echo "$(date +%d%b%Y-%T),${1},${2},${3},${4},${5}" >> $csvfile
}

# Generate csv data; pass to output_csv()
gen_csv(){
    # establish arrays for momentary values and strip package format
    mpAvg=()
    meAvg=()
    packageT=$(echo "$package" | awk -F '.' '{print $1}' | cut -c2-)

    # build momentary average and peak temp for P-cores
    for idx in $(seq 1 ${pcores}); do
        mpAvg+=(${avgP[-${idx}]})
    done
    pSumT=0
    pHighT=0
    for i in "${mpAvg[@]}"; do let pSumT=$((pSumT + i)); done
    mpAvgT=$((pSumT / "${#mpAvg[@]}"))
    for temp in "${mpAvg[@]}"; do
        if ((temp > pHighT)); then
            pHighT=$temp
        fi
    done

    # build momentary average and peak temp for E-cores
    for idx in $(seq 1 ${ecores}); do
        meAvg+=(${avgE[-${idx}]})
    done
    eSumT=0
    eHighT=0
    for i in "${meAvg[@]}"; do let eSumT=$((eSumT + i)); done
    meAvgT=$((eSumT / "${#meAvg[@]}"))
    for temp in "${meAvg[@]}"; do
        if ((temp > eHighT)); then
            eHighT=$temp
        fi
    done

    # send out values to be written
    output_csv $pHighT $mpAvgT $eHighT $meAvgT $packageT

    # clear the temporary arrays
    unset mpAvg; unset meAvg
}

# Sequentially format sensor values per core
core_show(){
    for core in $(seq $1 $2); do
        echo "Core ${core}: ${sense[${core}]}"
    done
}

# Assemble and format sensor output & core info - P-cores always start at 0
sensor_show(){
    echo ""; echo "CPU Package: ${package}"
    echo "_____________________________________________"; echo ""
    echo "P-Cores ($pname ${pcores}C/$((pcores * 2))T):"
    core_show 0 $lastpcore
    echo ""; echo "E-cores ($ename ${ecores}C/${ecores}T):"
    core_show $pcores $lastecore
}

# Display extended info for 'hud' loop
loop_display(){
    clear; echo "  Time remaining: $1 seconds"; echo ""
    echo " *** PRESS CTRL+C TO EXIT THE HUD ***"
    sensor_show
    echo "___________________________________________________"; echo ""
    echo "P-Core max: +${2}.0°C  P-Core Avg: +${3}.0°C"
    echo "E-Core max: +${4}.0°C  E-Core Avg: +${5}.0°C"
    echo "___________________________________________________"; echo ""
    echo " *** PRESS CTRL+C TO EXIT THE HUD ***"; echo ""; sleep 1
}

# Timed or infinite loop with additional metrics displayed
loop_hud(){
    # set vars and arrays we'll need to work with in the loop
    pHigh=$(echo "${sense[0]}" | awk -F '.' '{print $1}' | cut -c2-)
    eHigh=$(echo "${sense[${pcores}]}" | awk -F '.' '{print $1}' | cut -c2-)
    remaining=$1
    # main loop
    while [[ "$1" -ge 1 ]]; do
        # for P&E cores, add values to the arrays and check for highest temp
        for pVal in $(seq 0 $lastpcore); do
            ptemp=$(echo "${sense[$pVal]}" | awk -F '.' '{print $1}' | cut -c2-)
            avgP+=(${ptemp})
            [[ "$ptemp" -gt "$pHigh" ]] && let pHigh=$ptemp
        done
        for eVal in $(seq $pcores $lastecore); do
            etemp=$(echo "${sense[$eVal]}" | awk -F '.' '{print $1}' | cut -c2-)
            avgE+=(${etemp})
            [[ "$etemp" -gt "$eHigh" ]] && let eHigh=$etemp
        done

        # housekeeping so our arrays don't become cumbersome
        [[ "${#avgP[@]}" -gt 1000 ]] && for i in $(seq 0 100); do
            unset 'avgP[i]'; done; avgP=("${avgP[@]}")
        [[ "${#avgE[@]}" -gt 1000 ]] && for i in $(seq 0 100); do
            unset 'avgE[i]'; done; avgE=("${avgE[@]}")

        # calculate overall average temps
        pSum=0
        eSum=0
        for i in "${avgP[@]}"; do let pSum=$((pSum + i)); done
        pAvg=$((pSum / "${#avgP[@]}"))
        for i in "${avgE[@]}"; do let eSum=$((eSum + i)); done
        eAvg=$((eSum / "${#avgE[@]}"))

        # if -csv is set, generate and write new csv entry
        if [[ $2 == "-csv" ]]; then gen_csv; fi

        # display everything
        loop_display $remaining $pHigh $pAvg $eHigh $eAvg

        # retrigger new sense values
        resense

        # tick down on our counter if set; exit if done
        [[ $remaining -eq 0 ]] && cleanup || let remaining=$((remaining -1))
    done
}

# Convert any time input to seconds
toseconds(){
    if [[ ${1: -1} =~ [0-9] ]]; then
        seconds=$1
    else
        case ${1: -1} in
            [sS])
                seconds=${1%?}
                ;;
            [mM])
                seconds=$((${1%?}*60))
                ;;
            [hH])
                seconds=$((${1%?}*3600))
                ;;
        esac
    fi
    return $seconds
}

# Trap for ctrl+c exit
trap cleanup INT

# If the user specified a filename for the csv, use that
# otherise, if -csv was specified, generate a file
if [[ "$2" == "-csv" ]]; then
    if [ -n "$3" ]; then
        [[ "$3" =~ ".csv" ]] && _file=$3 || _file="${3}.csv"
        csvfile="`pwd`/${_file}"
    else
        csvname="displaytemp-`date +%d%b`"
        adder=1
        # Ensure we don't overwrite past results files
        while [ -e "`pwd`/${csvname}.csv" ]; do
            csvname="$(echo "$csvname" | awk -F- '{print $1"-"$2}')-${adder}"
            adder=$((adder+1))
        done
        csvfile="`pwd`/${csvname}.csv"
    fi
    # Populate the csv with header row
    echo "Time,P-Core_High,P-Core_Avg,E-Core_High,E-Core_Avg,Package" > $csvfile
fi

# Parse arguments and execute
if [ -z "$1" ]; then
    sensor_show; echo ""; echo " -> Try '$0 30s' for more info "
    echo " -> Try '$0 30s -csv' for 30 seconds of results with CSV output"
else
    case $1 in
        (*[0-9]*)
            toseconds $1
            loop_hud $seconds $2
            ;;
        help|--help|--h|-h|-?|/?)
            usage
            cleanup
            ;;
        *)
            sensor_show
            cleanup
            ;;
    esac
fi
