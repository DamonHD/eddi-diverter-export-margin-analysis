#!/bin/sh
# Select an optimal value for the Eddi PV diverter export margin.

# Output designed to be (kinda) human-readable,
# and easily handled by gnuplot and/or converted to an HTML table.

# Published under an Apache 2.0 licence:
#     https://www.apache.org/licenses/LICENSE-2.0
# Copyright 2022 Damon Hart-Davis

# Model the optimal Export Margin (eg in 50W increments) month-by-month (and whole-year vs winter) vs pre-Eddi post-Enphase 15-minute exports to grid to find the trade-off between Export Margin and useful diversion available to the heat battery and exported energy during peak demand and even-ness of heat battery charge (charging over more hours would be better).

# Whole years to use (avoiding 2020 might avoid lockdown distortions).
YEARSTOUSE="2019 2020 2021"

# Export Margins to simulate (W).
# Notes:
#   * Eddi can only configure in multiples of 50W.
#   * Minimum of 50W or 100W required for reliable Eddi/Enphase interop.
#   * As of 2022-08 margin of 100W is set.
#   * Eddi measurement inaccuracy may be ~90W.
MARGINS="0 50 100 150 200 250 300 350 400 500 750 1000 1500 2000 3000 4000"

# Maximum divert power (approx actual element rating, W).
MAXDIVERTW=3000
# Typical DHW demand per day (Wh).
# Nominally includes storage losses.
DHWWhPERDAY=4000
# Heat storage capacity (Wh).
STOREMAXWh=7000

# Source data directory for exports (spill to grid) from Enphase.
DATADIR=data/16WWHiRes/Enphase/adhoc/

# Example file content (initial lines):
#Date/Time,Energy Produced (Wh),Energy Consumed (Wh),Exported to Grid (Wh),Imported from Grid (Wh),Stored in AC Batteries (Wh),Discharged from AC Batteries (Wh)
#2021-12-01 00:00:00 +0000,0,22,0,26,4,0
#2021-12-01 00:15:00 +0000,0,17,0,21,4,0
#
# The exported to grid column (4, Wh) is of interest.

echo "## YEARSTOUSE $YEARSTOUSE"
echo "## MAXDIVERTW $MAXDIVERTW"
echo "## DHWWhPERDAY $DHWWhPERDAY"
echo "## STOREMAXWh $STOREMAXWh"
echo "#margin-W year-divert-frac year-divert-daily-kWh MarToSep-divert-frac MarToSep-divert-daily-kWh NovToJan-divert-frac NovToJan-divert-daily-kWh"

for em in $MARGINS;
    do
    #echo '<!-- INFO: simulating Export Margin of '${em}'W -->'

    printf "%d " $em
    for season in year MarToSep NovToJan;
        do
        MONTHS="01 02 03 04 05 06 07 08 09 10 11 12"
        if [ "NovToJan" = "$season" ]; then MONTHS="01 11 12"; fi
        if [ "MarToSep" = "$season" ]; then MONTHS="03 04 05 06 07 08 09"; fi

        # Gather all files for one analysis and process at once.
        files=""
        for y in $YEARSTOUSE;
            do
            for m in $MONTHS;
                do
                f=$DATADIR/net_energy_$y$m.csv.gz
                if [ ! -s $f ]; then continue; fi
                files=" $files $f"
                done
            done
        # Process all data as one stream.
        cat $files | gzip -d | \
            awk -F, \
                -v em=$em \
                -v DHWWhPERDAY=$DHWWhPERDAY \
                -v MAXDIVERTW=$MAXDIVERTW \
                -v STOREMAXWh=$STOREMAXWh \
            'BEGIN {
                yesterday=""
                WhToday = 0
                storedWh = 0
                days = 0;
                samples = 0;
                divSamples = 0;
                Wh = 0;
            }
            /^20/ {
                date=substr($1,1,10);
                if(date != yesterday) {
                    # if(WhToday > 0) { printf("diverted %dWh on %s\n", WhToday, date); }
                    yesterday=date; WhToday=0; ++days;
                    storedWh -= DHWWhPERDAY;
                    if(storedWh < 0) { storedWh = 0; }
                    }
                ++samples;
                exportWh=$4
                exportW=exportWh * 4; # 15 minute samples.
                if((exportW > em) && (storedWh < STOREMAXWh)) {
                    ++divSamples;
                    maxdivertableW = exportW - em;
                    divertableW = maxdivertableW;
                    # Limit maximum diversion power to element/Eddi capacity.
                    if(divertableW > MAXDIVERTW) { divertableW = MAXDIVERTW; }
                    # Limit by daily demand.
                    headroomWh = STOREMAXWh - storedWh;
                    divertableWh = divertableW / 4; # 15 minute samples.
                    if(divertableWh > headroomWh) { divertableWh = headroomWh; }
                    Wh += divertableWh;
                    WhToday += divertableWh;
                    storedWh += divertableWh;
                    }
            }
            END {
                printf("%.3f %.2f ", divSamples/samples, Wh/days/1000);
            }'

        done

    echo

    done
