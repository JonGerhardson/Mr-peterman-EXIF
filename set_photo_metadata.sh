#!/bin/bash

# --- Script Configuration & Strict Mode ---
# This script transforms input image(s) to mimic an iPhone 4 photo taken
# in Myanmar in 2020.
# It handles batch processing, resizes/crops images, sets EXIF data,
# embeds a thumbnail, and adjusts file system timestamps.
# Location data can be randomly selected from a CSV or use fixed coordinates.
#
# WARNINGS:
# 1. ACTUAL IMAGE DIMENSIONS: While this script can resize/crop, the EXIF tags
#    for PixelXDimension/PixelYDimension are set to iPhone 4 defaults.
#    The actual JPEG structure's width/height will reflect the resize/crop.
#
# 2. FILE INODE CHANGE TIME (ctime): This script modifies the file's 'last access'
#    and 'last modification' timestamps. However, the 'inode change time' (ctime)
#    will be updated to the current time when the script runs. Modifying ctime
#    is generally not possible with standard user tools.

set -o errexit   # Exit on any command that fails
set -o nounset   # Exit on use of unset variables
set -o pipefail  # Produce a failure return code if any command in a pipeline fails

# --- Default Configuration Values ---
DEFAULT_TARGET_DATETIME_EXIF="2020:07:22 10:15:30" # Local Myanmar Time
DEFAULT_TARGET_OFFSET_ORIGINAL="+06:30" # Myanmar Time (MMT UTC+6:30)
DEFAULT_TARGET_SUBSEC="175" # Example subseconds

# iPhone 4 Target Dimensions
TARGET_WIDTH_LANDSCAPE=2592
TARGET_HEIGHT_LANDSCAPE=1936
TARGET_WIDTH_PORTRAIT=1936
TARGET_HEIGHT_PORTRAIT=2592

# iPhone 4 Thumbnail dimensions
THUMBNAIL_WIDTH=192
THUMBNAIL_HEIGHT=144

# Fuzzing amount for GPS coordinates (in meters) when using CSV
FUZZ_METERS=100

# Mr. Peterman's hardcoded Myanmar coordinates
MR_PETERMAN_LAT="22.3000" # Example specific Myanmar coordinates
MR_PETERMAN_LON="94.4666"
MR_PETERMAN_ALT="350"

# --- Function to display usage ---
usage() {
    echo "Usage: $0 [OPTIONS] [locations_csv_file_if_not_--mr-peterman] <input_image_file1> [input_image_file2 ...]"
    echo ""
    echo "Processes one or more input images to mimic iPhone 4 photos."
    echo ""
    echo "Options:"
    echo "  --resize-mode <auto|scale|crop> : Image resizing/cropping mode. Default: auto."
    echo "                                    auto: Scale if aspect ratio is close, else crop."
    echo "                                    scale: Force scale to fit, may add padding."
    echo "                                    crop: Force crop to fill."
    echo "  --random-filenames              : Use IMG_XXXX.JPG with random XXXX for output filenames."
    echo "                                    Default for batch is sequential (IMG_0001.JPG, ...)."
    echo "  --mr-peterman                   : Use hardcoded Myanmar GPS coordinates instead of CSV."
    echo "                                    If used, <locations_csv_file> argument is omitted."
    echo "  --output-dir <directory>        : Specify a directory for output files. Default: same as input."
    echo "  --datetime <\"YYYY:MM:DD HH:MM:SS\"> : Override default EXIF DateTime (Local). Default: \"$DEFAULT_TARGET_DATETIME_EXIF\""
    echo "  --offset <\"±HH:MM\">             : Override default Time Offset from UTC. Default: \"$DEFAULT_TARGET_OFFSET_ORIGINAL\""
    echo "  --subsec <SSS>                  : Override default Subseconds. Default: \"$DEFAULT_TARGET_SUBSEC\""
    echo ""
    echo "Arguments:"
    echo "  [locations_csv_file] : Path to CSV file (latitude,longitude,elevation_meters,...)."
    echo "                         Required unless --mr-peterman is used."
    echo "  <input_image_file(s)>: Path to one or more input image files."
    echo ""
    echo "Example (CSV): $0 --resize-mode crop locations.csv photo1.jpg photo2.jpg"
    echo "Example (Mr. Peterman): $0 --mr-peterman --random-filenames original.png"
    exit 1
}

# --- Initialize Variables ---
RESIZE_MODE="auto"
RANDOM_FILENAMES_FLAG=false
MR_PETERMAN_FLAG=false
LOCATIONS_CSV_FILE=""
INPUT_FILES=()
OUTPUT_DIR=""
TARGET_DATETIME_EXIF="$DEFAULT_TARGET_DATETIME_EXIF"
TARGET_OFFSET_ORIGINAL="$DEFAULT_TARGET_OFFSET_ORIGINAL"
TARGET_SUBSEC="$DEFAULT_TARGET_SUBSEC"

# --- Parse Command-Line Options ---
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --resize-mode)
            RESIZE_MODE="$2"
            if [[ ! "$RESIZE_MODE" =~ ^(auto|scale|crop)$ ]]; then
                echo "Error: Invalid resize mode '$RESIZE_MODE'. Must be auto, scale, or crop." >&2; usage;
            fi
            shift 2 
            ;;
        --random-filenames)
            RANDOM_FILENAMES_FLAG=true
            shift 
            ;;
        --mr-peterman)
            MR_PETERMAN_FLAG=true
            shift 
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2 
            ;;
        --datetime)
            TARGET_DATETIME_EXIF="$2"
            shift 2
            ;;
        --offset)
            TARGET_OFFSET_ORIGINAL="$2"
            shift 2
            ;;
        --subsec)
            TARGET_SUBSEC="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        --) 
            shift
            POSITIONAL_ARGS+=("$@")
            break
            ;;
        -*) 
            echo "Error: Unknown option '$1'" >&2
            usage
            ;;
        *) 
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# --- Process Positional Arguments ---
if [ "$MR_PETERMAN_FLAG" = false ]; then
    if [ ${#POSITIONAL_ARGS[@]} -eq 0 ]; then
        echo "Error: Locations CSV file not specified (and --mr-peterman not used)." >&2; usage;
    fi
    LOCATIONS_CSV_FILE="${POSITIONAL_ARGS[0]}"
    INPUT_FILES=("${POSITIONAL_ARGS[@]:1}") 
else
    INPUT_FILES=("${POSITIONAL_ARGS[@]}")
fi

if [ ${#INPUT_FILES[@]} -eq 0 ]; then
    echo "Error: No input image files specified." >&2; usage;
fi


# --- Create Temporary Directory & Cleanup ---
TEMP_DIR=$(mktemp -d -t exif_script_temp.XXXXXX)
TEMP_THUMBNAIL_BASENAME="temp_thumb_for_exif.jpg" 

cleanup() {
    echo "Cleaning up temporary files and directory..."
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

# --- Validate Tools and Output Directory ---
if ! command -v exiftool &> /dev/null; then echo "Error: exiftool not found."; exit 1; fi
if ! command -v bc &> /dev/null; then echo "Error: bc (basic calculator) not found."; exit 1; fi
if ! command -v convert &> /dev/null || ! command -v identify &> /dev/null; then
    echo "Error: ImageMagick (convert/identify) not found."; exit 1;
fi
CAN_CREATE_THUMBNAIL=true # Re-evaluate this after ImageMagick check
if ! command -v convert &> /dev/null; then CAN_CREATE_THUMBNAIL=false; fi


if [ -n "$OUTPUT_DIR" ]; then
    if [ ! -d "$OUTPUT_DIR" ]; then
        echo "Creating output directory: $OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR"
    fi
    OUTPUT_DIR="${OUTPUT_DIR%/}/" 
fi


# --- Main Processing Loop ---
IMG_COUNTER=1
for CURRENT_INPUT_FILE in "${INPUT_FILES[@]}"; do
    echo "-----------------------------------------------------"
    echo "Processing input file: $CURRENT_INPUT_FILE"

    if [ ! -f "$CURRENT_INPUT_FILE" ]; then
        echo "Error: Input file '$CURRENT_INPUT_FILE' not found. Skipping." >&2
        continue
    fi
    if ! file "$CURRENT_INPUT_FILE" | grep -qE 'image|bitmap'; then
        echo "Error: Input file '$CURRENT_INPUT_FILE' does not appear to be a valid image file. Skipping." >&2
        file "$CURRENT_INPUT_FILE" >&2 
        continue
    fi

    # --- Determine Output Filename ---
    if [ "$RANDOM_FILENAMES_FLAG" = true ] || [ ${#INPUT_FILES[@]} -eq 1 ]; then
        RAND_NUM=$(printf "%04d" $((RANDOM % 10000)))
        CURRENT_OUTPUT_BASENAME="IMG_${RAND_NUM}.JPG"
    else
        CURRENT_OUTPUT_BASENAME=$(printf "IMG_%04d.JPG" "$IMG_COUNTER")
        IMG_COUNTER=$((IMG_COUNTER + 1))
    fi
    CURRENT_OUTPUT_FILE="${OUTPUT_DIR}${CURRENT_OUTPUT_BASENAME}"
    TEMP_PROCESSING_FILE="${TEMP_DIR}/processing_${CURRENT_OUTPUT_BASENAME}"

    echo "Creating a working copy as '$TEMP_PROCESSING_FILE'..."
    cp "$CURRENT_INPUT_FILE" "$TEMP_PROCESSING_FILE"

    # --- Image Resizing/Cropping ---
    echo "Applying resize/crop mode: $RESIZE_MODE"
    identify_output=$(identify -format "%w %h" "$TEMP_PROCESSING_FILE")
    read -r img_w img_h <<< "$identify_output"

    target_w=$TARGET_WIDTH_LANDSCAPE
    target_h=$TARGET_HEIGHT_LANDSCAPE
    if (( img_h > img_w )); then 
        target_w=$TARGET_WIDTH_PORTRAIT
        target_h=$TARGET_HEIGHT_PORTRAIT
    fi

    actual_resize_op="$RESIZE_MODE"
    if [ "$RESIZE_MODE" = "auto" ]; then
        # Ensure img_h is not zero to prevent division by zero
        if (( img_h == 0 )); then
            echo "Warning: Image height is 0 for '$TEMP_PROCESSING_FILE'. Cannot calculate aspect ratio. Defaulting to crop." >&2
            actual_resize_op="crop"
        else
            current_ar=$(echo "scale=5; $img_w / $img_h" | bc -l)
            target_ar_calc=$(echo "scale=5; $target_w / $target_h" | bc -l)
            diff_ar=$(echo "scale=5; d = $current_ar - $target_ar_calc; if (d < 0) d = -d; d" | bc -l)
            threshold_ar="0.05" 
            if (( $(echo "$diff_ar < $threshold_ar" | bc -l) )); then
                actual_resize_op="scale"
            else
                actual_resize_op="crop"
            fi
        fi
        echo "Auto resize mode selected: actual operation will be '$actual_resize_op'"
    fi

    case "$actual_resize_op" in
        scale)
            echo "Scaling image to ${target_w}x${target_h} (filling extent)..."
            convert "$TEMP_PROCESSING_FILE" -resize "${target_w}x${target_h}" \
                    -background none -gravity center -extent "${target_w}x${target_h}" \
                    "$TEMP_PROCESSING_FILE"
            ;;
        crop)
            echo "Cropping image to ${target_w}x${target_h}..."
            convert "$TEMP_PROCESSING_FILE" -resize "${target_w}x${target_h}^" \
                    -gravity center -crop "${target_w}x${target_h}+0+0" +repage \
                    "$TEMP_PROCESSING_FILE"
            ;;
    esac

    # --- GPS Coordinate Determination ---
    FUZZED_LAT="" FUZZED_LON="" GPS_ALTITUDE=""
    if [ "$MR_PETERMAN_FLAG" = true ]; then
        echo "Using Mr. Peterman's hardcoded Myanmar coordinates."
        FUZZED_LAT="$MR_PETERMAN_LAT"
        FUZZED_LON="$MR_PETERMAN_LON"
        GPS_ALTITUDE="$MR_PETERMAN_ALT"
    else
        if [ ! -f "$LOCATIONS_CSV_FILE" ]; then
             echo "Error: Locations CSV file '$LOCATIONS_CSV_FILE' not found. Skipping GPS for this file." >&2
        else
            echo "Reading and fuzzing location from '$LOCATIONS_CSV_FILE'..."
            # Read all data lines into an array to handle empty lines better when counting
            mapfile -t data_lines < <(tail -n +2 "$LOCATIONS_CSV_FILE" | sed '/^$/d') # Skip header, remove empty lines
            NUM_DATA_LINES=${#data_lines[@]}

            if [ "$NUM_DATA_LINES" -lt 1 ]; then
                echo "Error: No valid data lines in '$LOCATIONS_CSV_FILE'. Skipping GPS for this file." >&2
            else
                RANDOM_LINE_INDEX=$((RANDOM % NUM_DATA_LINES))
                SELECTED_LINE="${data_lines[$RANDOM_LINE_INDEX]}"
                echo "Randomly selected location data: $SELECTED_LINE"

                ORIG_LAT=$(echo "$SELECTED_LINE" | awk -F, '{print $1}')
                ORIG_LON=$(echo "$SELECTED_LINE" | awk -F, '{print $2}')
                ORIG_ALT=$(echo "$SELECTED_LINE" | awk -F, '{print $3}')

                # Trim whitespace just in case
                ORIG_LAT=$(echo "$ORIG_LAT" | xargs)
                ORIG_LON=$(echo "$ORIG_LON" | xargs)
                ORIG_ALT=$(echo "$ORIG_ALT" | xargs)


                if [ -z "$ORIG_LAT" ] || [ -z "$ORIG_LON" ] || \
                   ! [[ "$ORIG_LAT" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || \
                   ! [[ "$ORIG_LON" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                    echo "Error: Invalid or empty lat/lon in CSV: Lat='$ORIG_LAT', Lon='$ORIG_LON'. Skipping GPS." >&2
                else
                    if [ -z "$ORIG_ALT" ] || ! [[ "$ORIG_ALT" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                        echo "Warning: Invalid or empty elevation in CSV: Elev='$ORIG_ALT'. Using 0m." >&2
                        ORIG_ALT="0"
                    fi

                    DEG_PER_METER_LAT=$(echo "scale=10; 1 / 111111" | bc -l)
                    RAND_OFFSET_LAT_DEG=$(awk -v seed=$RANDOM -v max_offset_m="$FUZZ_METERS" -v deg_per_m="$DEG_PER_METER_LAT" \
                        'BEGIN{srand(seed); printf "%.10f", (rand() - 0.5) * 2 * max_offset_m * deg_per_m}')
                    FUZZED_LAT=$(echo "scale=10; $ORIG_LAT + $RAND_OFFSET_LAT_DEG" | bc -l)

                    LAT_RADIANS=$(echo "scale=10; $FUZZED_LAT * 3.141592653589793 / 180" | bc -l)
                    COS_LAT=$(echo "scale=10; c($LAT_RADIANS)" | bc -l)
                    if (( $(echo "$COS_LAT == 0" | bc -l) )); then
                        DEG_PER_METER_LON="$DEG_PER_METER_LAT"
                    else
                        DEG_PER_METER_LON=$(echo "scale=10; $DEG_PER_METER_LAT / $COS_LAT" | bc -l)
                    fi
                    RAND_OFFSET_LON_DEG=$(awk -v seed=$RANDOM -v max_offset_m="$FUZZ_METERS" -v deg_per_m="$DEG_PER_METER_LON" \
                        'BEGIN{srand(seed); printf "%.10f", (rand() - 0.5) * 2 * max_offset_m * deg_per_m}')
                    FUZZED_LON=$(echo "scale=10; $ORIG_LON + $RAND_OFFSET_LON_DEG" | bc -l)
                    GPS_ALTITUDE="$ORIG_ALT"
                    echo "Original CSV GPS: Lat=$ORIG_LAT, Lon=$ORIG_LON, Alt=$ORIG_ALT"
                    echo "Fuzzed GPS      : Lat=$FUZZED_LAT, Lon=$FUZZED_LON, Alt=$GPS_ALTITUDE"
                fi
            fi
        fi
    fi

    # --- Dynamic GPS Time Calculation (UTC) ---
    # Convert TARGET_DATETIME_EXIF ("YYYY:MM:DD HH:MM:SS") to "YYYY-MM-DD HH:MM:SS" for date command
    STD_DATETIME_LOCAL=$(echo "$TARGET_DATETIME_EXIF" | awk -F'[: ]' '{printf "%s-%s-%s %s:%s:%s", $1, $2, $3, $4, $5, $6}')
    GPS_DATETIME_UTC=""

    if [[ "$OSTYPE" == "darwin"* ]]; then # macOS
        EPOCH_SECONDS=$(date -j -f "%Y-%m-%d %H:%M:%S" "$STD_DATETIME_LOCAL" "+%s")
        OFFSET_SECONDS_VAL=$(echo "$TARGET_OFFSET_ORIGINAL" | awk -F: '{print ($1 * 3600) + ($2 * 60 * (substr($1,1,1) == "-" ? -1 : 1)) }')
        UTC_EPOCH=$((EPOCH_SECONDS - OFFSET_SECONDS_VAL)) # Subtract offset to get UTC
        GPS_DATETIME_UTC=$(date -r "$UTC_EPOCH" -u "+%Y:%m:%d %H:%M:%S")
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then # Linux
        GPS_DATETIME_UTC=$(date -d "$STD_DATETIME_LOCAL $TARGET_OFFSET_ORIGINAL" -u "+%Y:%m:%d %H:%M:%S")
    else # Fallback for other OS types
        echo "Warning: OS type '$OSTYPE' not explicitly supported for robust UTC conversion. Attempting generic 'date'."
        GPS_DATETIME_UTC=$(date -d "$STD_DATETIME_LOCAL $TARGET_OFFSET_ORIGINAL" -u "+%Y:%m:%d %H:%M:%S") || {
            echo "Error: Failed to convert local EXIF time to UTC. GPS timestamps might be incorrect." >&2
            GPS_DATETIME_UTC="$STD_DATETIME_LOCAL 00:00:00" # Placeholder to avoid script crash if date fails
        }
    fi
    GPS_DATE_STAMP=$(echo "$GPS_DATETIME_UTC" | cut -d' ' -f1) # YYYY:MM:DD format for EXIF
    GPS_TIME_STAMP=$(echo "$GPS_DATETIME_UTC" | cut -d' ' -f2) # HH:MM:SS format for EXIF


    # --- Thumbnail Generation ---
    THUMBNAIL_ARG=""
    CURRENT_TEMP_THUMBNAIL="${TEMP_DIR}/${TEMP_THUMBNAIL_BASENAME}"
    if [ "$CAN_CREATE_THUMBNAIL" = true ]; then
        echo "Creating thumbnail from processed image..."
        convert "$TEMP_PROCESSING_FILE" -thumbnail "${THUMBNAIL_WIDTH}x${THUMBNAIL_HEIGHT}^" \
                -gravity center -extent "${THUMBNAIL_WIDTH}x${THUMBNAIL_HEIGHT}" -strip "$CURRENT_TEMP_THUMBNAIL"
        if [ -f "$CURRENT_TEMP_THUMBNAIL" ] && [ -s "$CURRENT_TEMP_THUMBNAIL" ]; then
            THUMBNAIL_ARG="-m -ThumbnailImage<=$CURRENT_TEMP_THUMBNAIL"
        else
            echo "Warning: Failed to create thumbnail for '$CURRENT_OUTPUT_BASENAME'." >&2
        fi
    fi

    # --- Apply EXIF Metadata ---
    echo "Applying EXIF metadata to '$CURRENT_OUTPUT_BASENAME'..."
    EXIFTOOL_ARGS=(
        -overwrite_original -All= -XMP:All=
        -Make="Apple" -Model="iPhone 4" -Software="7.1.2" -HostComputer="iPhone OS 7.1.2"
        -DateTimeOriginal="$TARGET_DATETIME_EXIF" -CreateDate="$TARGET_DATETIME_EXIF" -ModifyDate="$TARGET_DATETIME_EXIF"
        -OffsetTimeOriginal="$TARGET_OFFSET_ORIGINAL" -OffsetTimeDigitized="$TARGET_OFFSET_ORIGINAL"
        -SubSecTimeOriginal="$TARGET_SUBSEC" -SubSecTimeDigitized="$TARGET_SUBSEC"
        -EXIF:PixelXDimension="$target_w" -EXIF:PixelYDimension="$target_h" 
        -XResolution=72 -YResolution=72 -ResolutionUnit="inches" -Orientation=1 -YCbCrPositioning=1
        -FocalLength="3.85 mm" -FNumber=2.8 -ISO=80 -ExposureTime="1/120"
        -ExposureProgram=2 -MeteringMode=5 -Flash=16 -WhiteBalance=0 -SensingMethod=2
        -SceneCaptureType=0 -SceneType=1 -CustomRendered=0 -ExposureMode=0 -DigitalZoomRatio=1.0
        -LensModel="iPhone 4 back camera 3.85mm f/2.8"
        -ColorSpace=1 -ExifVersion="0221" -FlashpixVersion="0100" -ComponentsConfiguration="Y Cb Cr -"
    )

    if [ -n "$FUZZED_LAT" ] && [ -n "$FUZZED_LON" ] && [ -n "$GPS_ALTITUDE" ]; then
        EXIFTOOL_ARGS+=(
            -GPSVersionID="2.2.0.0"
            -GPSLatitudeRef="$([ $(echo "$FUZZED_LAT < 0" | bc -l) -eq 1 ] && echo "S" || echo "N")"
            -GPSLatitude="$(echo "scale=10; v=$FUZZED_LAT; if(v<0) v=-v; v" | bc -l)"
            -GPSLongitudeRef="$([ $(echo "$FUZZED_LON < 0" | bc -l) -eq 1 ] && echo "W" || echo "E")"
            -GPSLongitude="$(echo "scale=10; v=$FUZZED_LON; if(v<0) v=-v; v" | bc -l)"
            -GPSAltitudeRef="$([ $(echo "$GPS_ALTITUDE < 0" | bc -l) -eq 1 ] && echo "1" || echo "0")" 
            -GPSAltitude="$(echo "scale=10; v=$GPS_ALTITUDE; if(v<0) v=-v; v" | bc -l)"
            -GPSDateStamp="$GPS_DATE_STAMP" -GPSTimeStamp="$GPS_TIME_STAMP"
            -GPSMapDatum="WGS-84" -GPSDOP=3.5 -GPSProcessingMethod="GPS"
        )
    else
        echo "Skipping GPS tags as coordinates are not available for '$CURRENT_OUTPUT_BASENAME'."
    fi

    if [ -n "$THUMBNAIL_ARG" ]; then EXIFTOOL_ARGS+=($THUMBNAIL_ARG); fi
    EXIFTOOL_ARGS+=(-n "$TEMP_PROCESSING_FILE")

    exiftool "${EXIFTOOL_ARGS[@]}"

    mv "$TEMP_PROCESSING_FILE" "$CURRENT_OUTPUT_FILE"
    echo "EXIF metadata applied. Output file is '$CURRENT_OUTPUT_FILE'."

    FILESYSTEM_TIMESTAMP=$(echo "$TARGET_DATETIME_EXIF" | sed 's/[: ]//g; s/\([0-9]\{12\}\)\([0-9]\{2\}\)/\1.\2/')
    echo "Updating file system timestamps for '$CURRENT_OUTPUT_FILE' to $FILESYSTEM_TIMESTAMP..."
    touch -t "$FILESYSTEM_TIMESTAMP" "$CURRENT_OUTPUT_FILE"

    if [[ "$OSTYPE" == "darwin"* ]] && command -v SetFile &> /dev/null; then
        SETFILE_DATE_FORMAT=$(echo "$FILESYSTEM_TIMESTAMP" | sed -E 's/([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})\.([0-9]{2})/\2\/\3\/\1 \4:\5:\6/')
        SetFile -d "$SETFILE_DATE_FORMAT" "$CURRENT_OUTPUT_FILE"
        echo "macOS creation date also set."
    fi
done

echo "-----------------------------------------------------"
echo "--- Batch Process Complete ---"
echo ""
echo "IMPORTANT WARNINGS:"
echo "1. ACTUAL IMAGE DIMENSIONS: The script attempts to resize/crop images. Review 'Image Width'/'Image Height' in exiftool output."
echo "2. INODE CHANGE TIME (ctime): Will reflect when this script was run, not the 2020 date."
echo ""
echo "To verify EXIF data, run: exiftool <output_file>"
echo "To verify file system dates (Linux): ls -lh --full-time <output_file>"
echo "To verify file system dates (macOS): stat -x <output_file>"

exit 0

