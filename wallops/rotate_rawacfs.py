"""
This script is intended to be run as a cron job to move files older than 1 month from
the rawacf_dmap directory to the rawacf_all directory, organizing them into YYYY/MM directories.

Author: Jordan Wiker
Date: May 25, 2023
"""
import os
import shutil
from datetime import datetime, timedelta

source_dir = '/borealis_nfs/borealis_data/rawacf_dmap/'
destination_dir = '/borealis_nfs/borealis_data/rawacf_all/'

# Calculate the date threshold (1 month ago)
threshold_date = datetime.now() - timedelta(days=30)

# Iterate over files in the source directory
for filename in os.listdir(source_dir):
    file_path = os.path.join(source_dir, filename)

    # Extract year, month, and day from the filename
    year = filename[:4]
    month = filename[4:6]
    day = filename[6:8]

    # Convert the extracted year, month, and day to a datetime object
    file_date = datetime.strptime(year + month + day, '%Y%m%d')

    # Check if the file's date is older than the threshold date
    if file_date < threshold_date:
        # Create the destination directory if it doesn't exist
        destination_subdir = os.path.join(destination_dir, year, month)
        os.makedirs(destination_subdir, exist_ok=True)

        # Move the file to the destination directory
        destination_path = os.path.join(destination_subdir, filename)
        shutil.move(file_path, destination_path)
        print(f"Moved file: {filename} to {destination_path}")

print("File moving completed.")

