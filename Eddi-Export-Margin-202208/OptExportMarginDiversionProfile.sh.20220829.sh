#!/bin/sh
# Show the output diversion profile by time-of-day for a given Export Margin.
# Derived from OptExportMargin.sh to preserve the basic model operation.

# Output designed to be (kinda) human-readable,
# and easily handled by gnuplot.

# Published under an Apache 2.0 licence:
#     https://www.apache.org/licenses/LICENSE-2.0
# Copyright 2022 Damon Hart-Davis

# Whole years to use (avoiding 2020 might avoid lockdown distortions).
YEARSTOUSE="2019 2020 2021"

# Export Margins to simulate (W).
# Notes:
#   * Eddi can only configure in multiples of 50W.
#   * Minimum of 50W or 100W required for reliable Eddi/Enphase interop.
#   * As of 2022-08 margin of 100W is set.
#   * Eddi measurement inaccuracy may be ~90W.
#MARGINS="0 50 100 150 200 250 300 350 400 500 750 1000 1500 2000 3000 4000"
MARGINS="400"

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
echo "## MARGINW $MARGINS"
#echo "#margin-W year-divert-frac year-divert-daily-kWh MarToSep-divert-frac MarToSep-divert-daily-kWh NovToJan-divert-frac NovToJan-divert-daily-kWh"

for em in $MARGINS;
    do
    #echo '<!-- INFO: simulating Export Margin of '${em}'W -->'

    #printf "%d " $em
    #for season in year MarToSep NovToJan;
    for season in Jun Sep Dec;
        do
        #MONTHS="01 02 03 04 05 06 07 08 09 10 11 12"
        #if [ "NovToJan" = "$season" ]; then MONTHS="01 11 12"; fi
        #if [ "MarToSep" = "$season" ]; then MONTHS="03 04 05 06 07 08 09"; fi

        MONTHS=""
        if [ "Jun" = "$season" ]; then MONTHS="06"; fi
        if [ "Sep" = "$season" ]; then MONTHS="09"; fi
        if [ "Dec" = "$season" ]; then MONTHS="12"; fi
        printf "%s " "$MONTHS"

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

                    # Accumulate by hour of day...
                    # Adjust to UTC as necessary.
#2021-06-30 23:45:00 +0100,0,19,0,0,0,19
#2021-12-01 00:00:00 +0000,0,22,0,26,4,0
                    hourUTC = substr($1, 12, 2) + 0;
                    # Simple UTC adjustment good enough for 16WW!
                    # No wrap around needed for hourUTC adjustment
                    # as no PV generation or diversion expected then.
                    if("+0100" == substr($1, 21, 5)) { hourUTC -= 1; }
#printf("$1=%s, %s %s: hourUTC=%d\n", $1, substr($1, 12, 2), substr($1, 21, 5), hourUTC);
                    byHourWh[hourUTC] += divertableWh;
                    }
            }
            END {
                #printf("%.3f %.2f ", divSamples/samples, Wh/days/1000);
                for(i = 0; i < 24; ++i) {
                   # Allow for 15 minute samples.
                   meanW = (4 * byHourWh[i]) / (samples / 24);
                   printf("%4.0f ", meanW);
                   }
            }'

        echo

        done

    #echo

    done | \

    awk '
        # Transpose to gnuplot-friendly data-series per column.
        # Also add initial hour UTC x index column.
        {
        m = $1+0; # Convert string to int [1,12], eg "06" to 6.
        month[m] = 1; # There is data present for this month.
        for(h = 0; h < 24; ++h) {
            monthhW[m, h] = $(h+2); # Data for hour 0 is in field 2...
            }
        }
        END {
        # Spit out header row.
        printf("#h ", i);
        for(m = 1; m <= 12; ++m) {
            if(month[m]) { printf("  %02d ", m); }
            }
        print ""; # Terminate row.

        for(h = 0; h < 24; ++h) {
            printf("%02d ", h);

            for(m = 1; m <= 12; ++m) {
                if(!month[m]) { continue; } # Skip month without data.
 
                printf("%4d ", monthhW[m, h]);
                }

            print ""; # Terminate row.
            }
        }
        '

exit 0


Sample output from input data set:

## YEARSTOUSE 2019 2020 2021
## MAXDIVERTW 3000
## DHWWhPERDAY 4000
## STOREMAXWh 7000
## MARGINW 400
#h   06   09   12 
00    0    0    0 
01    0    0    0 
02    0    0    0 
03    0    0    0 
04    0    0    0 
05   18    0    0 
06  130    1    0 
07  329   35    0 
08  601  159    0 
09  853  379    0 
10  711  697    0 
11  434  791    3 
12  260  586    1 
13  163  414    0 
14  135  232    0 
15   62   81    0 
16   16    7    0 
17   19    0    0 
18    2    0    0 
19    0    0    0 
20    0    0    0 
21    0    0    0 
22    0    0    0 
23    0    0    0
