# Mr-peterman-EXIF
annoy OSINT dorks by making your picutres show they were shot on an iPhone 4 in 2020 but it's 2025 
## If you are trying to protect your data this is likely worse than useless. 


**Options:**

* `--resize-mode <auto|scale|crop>`: Image resizing/cropping mode. Default: `auto`.
    * `auto`: Scale if aspect ratio is close to 4:3, else crop.
    * `scale`: Force scale to fit target dimensions (may add padding).
    * `crop`: Force crop to fill target dimensions.
* `--random-filenames`: Use `IMG_XXXX.JPG` with random `XXXX` for output filenames. Default for batch processing is sequential numbering.
* `--mr-peterman`: Use hardcoded Myanmar GPS coordinates (defined within the script) instead of reading from a CSV file. If this option is used, the `locations_csv_file` argument should be omitted.
* `--output-dir <directory>`: Specify a directory for output files. Default: output files are created in the same directory as the script is run from.
* `--datetime "<YYYY:MM:DD HH:MM:SS>"`: Override the default EXIF DateTime (Local Time). Example: `"--datetime \"2021:01:15 14:30:00\""`.
* `--offset "<±HH:MM>"`: Override the default Time Offset from UTC for EXIF. Example: `"--offset \"-05:00\""`.
* `--subsec <SSS>`: Override the default Subseconds (0-999). Example: `"--subsec 055"`.
* `-h, --help`: Display the help message.

**Arguments:**

* `[locations_csv_file]`: Path to the CSV file containing location data. This argument is **required unless** the `--mr-peterman` option is used. The CSV should have at least three columns: `latitude,longitude,elevation_meters` (see "CSV File Format" below).
* `<input_image_file(s)>`: Path to one or more input image files to process.

**Examples:**

1.  Process a single image using a CSV for location data and auto resize mode:
    ```bash
    ./set_photo_metadata.sh locations.csv myphoto.jpg
    ```

2.  Process multiple images, using the `--mr-peterman` fixed coordinates, random filenames, and force cropping, saving to an `output_images` directory:
    ```bash
    ./set_photo_metadata.sh --mr-peterman --random-filenames --resize-mode crop --output-dir ./output_images image1.png image2.jpeg
    ```

3.  Process an image using a CSV and override the date/time:
    ```bash
    ./set_photo_metadata.sh --datetime "2019:11:20 09:15:00" --offset "+02:00" locations.csv old_photo.jpg
    ```

## CSV File Format

If using the `locations_csv_file` argument, the CSV file must contain location data. The script expects the first three columns to be:

1.  `latitude`: Decimal degrees (e.g., `27.5166`).
2.  `longitude`: Decimal degrees (e.g., `97.2000`).
3.  `elevation_meters`: Elevation in meters (e.g., `650`).
