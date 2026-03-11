#!/bin/bash
# Adapted from rsync_to_nas.sh in the SuperDARN data_flow repository by 
# SuperDARN Canada, University of Saskatchewan, originally written by Kevin Krieger and Theodore Kolkman
#
# A singleton script to move Borealis files from the Borealis computer to the site NAS. Files are
# copied first and removed once copy is confirmed to be successful. This script is to be run on the
# site computer running Borealis.
#
# This script should be run via an inotify daemon triggering whenever 2-hour Borealis site files
# finish writing
#
# Inotify watches the directory Borealis writes to, and triggers the rsync_to_nas script only when a
# 2-hour site file is created. Since these files are only created once, and once they're created the
# previous 2-hour block is finished writing, the rsync_to_nas script will execute immediately after
# Borealis finishes writing the previous 2-hour file. To distinguish between the previous (finished
# writing) and current (currently writing) 2-hour file, the `find` command must be used as specified
# in the script below.
#
# Param 1: Borealis file name that script was triggered on. This will be used to filter out the
#          files currently being written to, using the timestamp in the name. File name must be of
#          format YYYYMMDD.HHMM.SS.[rest of filename]. If no input is given, then script defaults to
#          omitting only files written to in the last 5 minutes.

###################################################################################################

source "${HOME}/.profile"	# Load in environment variables
# source "${HOME}/data_flow/config.sh"  # Load common data flow variables
source "${HOME}/repos/data_flow/library/data_flow_functions.sh"  # Load in function library

###################################################################################################

# Borealis directory files are to be transferred from
# Use jq to read the Borealis data directory from the Borealis config file
readonly SOURCE="$(cat ${BOREALISPATH}/config/${RADAR_ID}/${RADAR_ID}_config.ini | jq --raw-output '.data_directory')"
readonly DEST="/borealis_nfs/borealis_data" # On NAS

readonly ANTENNAS_IQ_DEST="${DEST}/antennas_iq_array"
readonly RAWACF_DMAP_DEST="${DEST}/rawacf_dmap"
readonly RAWACF_ARRAY_DEST="${DEST}/rawacf_array"
readonly BACKUP_DEST="${DEST}/backup"
readonly FAIL_DEST="${DEST}/conversion_failure/" # Any files that fail checks go here

# Create log file. New file created daily
readonly LOGGING_DIR="${HOME}/logs/rsync_to_nas/$(date +%Y/%m)"
mkdir --parents $LOGGING_DIR
readonly LOGFILE="${LOGGING_DIR}/$(date +%Y%m%d).rsync_to_nas.log"
readonly SUMMARY_DIR="${HOME}/logs/rsync_to_nas/summary/$(date +%Y/%m)"
mkdir --parents $SUMMARY_DIR
readonly SUMMARY_FILE="${SUMMARY_DIR}/$(date -u +%Y%m%d).rsync_to_nas_summary.log"

readonly EXPECTED_SOURCE="/data/borealis_data"

if [[ "$SOURCE" != "$EXPECTED_SOURCE" ]]; then
    message="Skipping sync: SOURCE is '$SOURCE', expected '$EXPECTED_SOURCE'"
    printf "%s\n" "$message" | tee --append "$SUMMARY_FILE"
    printf "Exiting without transfer.\n\n" | tee --append "$SUMMARY_FILE"
    exit 2
fi

# Telemetry directory for this script and site (Not used at Wallops)
# readonly TELEMETRY_SCRIPT_DIR="${TELEMETRY_DIR}/${RADAR_ID}/rsync_to_nas"
###################################################################################################

# Ensure that only a single instance of this script runs.
if pidof -o %PPID -x -- "$(basename -- $0)" > /dev/null; then
	printf "Error: Script $0 is already running. Exiting...\n"
	exit 1
fi

exec &>> $LOGFILE # Redirect STDOUT and STDERR to $LOGFILE

printf "################################################################################\n\n" | tee --append $SUMMARY_FILE

# Date in UTC format for logging
printf "Executing $0 on $(hostname) for ${RADAR_ID}\n" | tee --append $SUMMARY_FILE
date --utc "+%Y%m%d %H:%M:%S UTC" | tee --append $SUMMARY_FILE
printf "Transferring from: $SOURCE\n" | tee --append $SUMMARY_FILE

# Get all files that aren't currently being written to. First, find all files in the source
# directory. Then, filter out all files that have same timestamp in the filename as the file that 
# triggered the script via inotify. This will effectively prevent the script from transferring 
# files currently being written by Borealis
printf "Transferring to NAS: $DEST\n\n" | tee --append $SUMMARY_FILE
search=(\( -name "*rawacf*" -o -name "*antennas_iq*" \))
readonly TRANSFER_LOC=""

# Using the filename that this script triggered on, a pattern can be determined to omit the current
# file being written in Borealis. omit_pattern trims the input filename, for example
# "20221018.1200.00.sas.1.rawacf.h5", down to "20221018.1200.00."
if [[ $# -eq 0 ]]; then
	# Default to omitting nothing and grabbing files not written to in last 5 minutes
	files=$(find ${SOURCE} "${search[@]}" -cmin +5) 
	printf "No input file specified, filtering all recent files instead\n\n"
elif [[ $# -eq 1 ]]; then
	omit_pattern="$(echo $1 | cut --fields 1-3 --delimiter ".")"
	files=$(find ${SOURCE} "${search[@]}" | grep --invert-match --fixed-strings $omit_pattern)
	printf "Filtering out files with pattern ${omit_pattern}\n\n"
else
	printf "./rsync_to_nas incorrect usage: Too many arguments\n"
	exit 1
fi

if [[ -n $files ]]; then
	printf "Placing following files in ${DEST}:\n"
	printf '%s\n' "${files[@]}"
else
	printf "No files to be transferred.\n" | tee --append $SUMMARY_FILE
fi

# Transfer files
for file in $files
do
	printf "\nSyncing: $file\n"
	
	# Ensure that the file has all group permissions enabled (read/write/execute)
	chmod --verbose 775 $file

	needs_zip=0
	backup=0
	if [[ $file == *.rawacf ]]; then
		SPECIFIC_DEST="$RAWACF_DMAP_DEST"
		needs_zip=1  # bzip rawacf DMAP files
		backup=1  # backup rawacf files
	elif [[ $file == *.rawacf.h5 ]]; then
		SPECIFIC_DEST="$RAWACF_ARRAY_DEST"
		backup=1  # backup rawacf files
	elif [[ $file == *.antennas_iq.h5 ]]; then
		SPECIFIC_DEST="$ANTENNAS_IQ_DEST"
	else
		error="unknown file type: ${file}\n"
		printf "${error}" | tee --append $SUMMARY_FILE
		SPECIFIC_DEST="$FAIL_DEST"
	fi

	# Check that the timestamps and file modification times are consistent. If they aren't, change
	# the destination to the failed file directory.
	check_timestamp $file
	if [[ $? -eq 2 ]]; then 	# check_timestamp failed
		error="check_timestamp failed: ${file}\n"
		printf "${error}" | tee --append $SUMMARY_FILE

		message="$(date +'%Y%m%d %H:%M:%S')   ${RADAR_ID} - ${error}"
		alert_slack "${message}" "${SLACK_DATAFLOW_WEBHOOK}"	# Send alert to Slack

		SPECIFIC_DEST="$FAIL_DEST"	# Change destination
	fi

	# Bzip file if needed
	if [[ $needs_zip -eq 1 ]]; then
		printf "Bzipping $file to $file_to_transfer\n"
		file_to_transfer="${file}.bz2"
		bzip2 --verbose $file
	else
		file_to_transfer="$file"
	fi

	if [[ $backup -eq 1 && " ${NAS_SITES[*]} " =~ " ${RADAR_ID} " ]]; then
		# rsync file to NAS for backup
		printf "Backing up to: $BACKUP_DEST\n"
		rsync -av --append-verify --timeout=180 --rsh=ssh $file_to_transfer "${TRANSFER_LOC}${BACKUP_DEST}"

		# Check if transfer was okay using the md5sum program
		verify_transfer $file_to_transfer "${BACKUP_DEST}/$(basename $file_to_transfer)" ${TRANSFER_LOC%:}
		return_value=$?
	fi

	printf "Transferring to: $SPECIFIC_DEST\n"
	# rsync file to NAS or site-linux computer
	rsync -av --append-verify --timeout=180 --rsh=ssh $file_to_transfer "${TRANSFER_LOC}${SPECIFIC_DEST}"

	# Check if transfer was okay using the md5sum program
	verify_transfer $file_to_transfer "${SPECIFIC_DEST}/$(basename $file_to_transfer)" ${TRANSFER_LOC%:}
	return_value=$?

	if [[ $return_value -eq 0 ]]; then
		# Remove the file if transfer is successful
		printf "Successfully transferred: ${file_to_transfer}\n" | tee --append $SUMMARY_FILE
		printf "Deleting file...\n"
		rm --verbose $file_to_transfer
	else
		# If file not transferred successfully, don't delete and try again next time
		printf "Transfer failed: ${file_to_transfer}\n" | tee --append $SUMMARY_FILE
		printf "File not deleted.\n"
	fi
done

printf "\nFinished $(basename $0). End time: $(date --utc "+%Y%m%d %H:%M:%S UTC")\n\n" | tee --append $SUMMARY_FILE

exit
