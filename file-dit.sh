#!/bin/bash
#
# file-dit.sh - File Data Integirty Tool for verifying the ability of a drive/filesystem
# to reliably store and retrieve data.
#

set -u

#
# constants
#
FALSE=0
TRUE=1
APP_NAME="file-dit"
CONVERT_BYTES_TO_SIZE_STR_FMT_ROUNDED_WITH_PAD="%8.2f"
CONVERT_BYTES_TO_SIZE_STR_FMT_ROUNDED="%.2f"
TEST_FILENAME_SUFFIX="_${APP_NAME}_$$"

#
# default parameters
#
testDirBase="."
passCount=0
minRandomFileSizeBytes=4096
maxRandomFileSizeBytes=1048576
bytesToGeneratePerPass=$((100*1048576))
showPerPassPerfData=$FALSE
tempMemoryFilesystemBase="/dev/shm"
verbose=$FALSE

#
# global vars
#
gTestDir=""
gTempMemoryFilesystemDir=""

#
# clears the entire kernel pagecache (routine not presently used)
#
function clearPageCache() {
    if ! echo 1 | sed --quiet 'w /proc/sys/vm/drop_caches'; then
        echo "Error: Clearing drop_caches failed - did you run with sudo?"
        exitScript 1
    fi
}

#
# Clears the pagecache for a file. This is done before reading/verifying
# a file to make sure its read from the device rather than out of cache
#
# Arguments:
#   $1 - Filename to clear pagecache for
# Returns:
#   retVal - SHA1 has of file
#
function clearPageCacheForFile() {
    local   filename=$1
    local   cmdOutput
    # https://unix.stackexchange.com/a/162806/557230
    if ! cmdOutput=$(dd of="$filename" oflag=nocache conv=notrunc,fdatasync count=0 2>&1); then
        echo "dd command to clear pagecache for file ${filename} failed"
        echo "$cmdOutput"
        exitScript 1
    fi
}

#
# genereates a SHA1 hash for a file
#
# Arguments:
#   $1 - Existing file to generate SHA1 hash for
# Returns:
#   retVal - SHA1 has of file
#
function genHashForFile() {

    local   filename=$1
    local   cmdOutput

    if ! cmdOutput=$("$HASH_APP" "$filename" 2>&1); then
        echo "Error performing sha1sum on ${filename}"
        echo "$cmdOutput"
        exitScript 1
    fi
    retVal=${cmdOutput% *} # hash
}

#
# genereates a file with random data
#
# Arguments:
#   $1 - Directory to create file into. Temporary filename will be generated
#   $2 - Size of file, in bytes
# Returns:
#   retVal - Full path+filename of file created
#
function genRandomDataFile() {

    local tempPath=$1
    local sizeBytes=$2
    local tempFilename
    local cmdOutput

    if ! tempFilename=$(mktemp --tmpdir="$tempPath" --suffix="$TEST_FILENAME_SUFFIX"); then
        echo "Error: Unable to create next temporary file"
        echo "$tempFilename"
        exitScript 1
    fi

    #
    # generate random data by using openssl AES-256-CTR, with the initial key generated from /dev/urandom.
    # This is orders of magnitude faster than using /dev/urandom for the entire random dataset, as was
    # initially considered via this line:
    #
    # if ! dd if=/dev/urandom of="$tempFilename" bs="$sizeBytes" count=1 2>/dev/null; then
    #
    # This idea came from # https://superuser.com/a/793003/1694825
    #
    if ! cmdOutput=$(dd of="$tempFilename" bs="$sizeBytes" count=1 iflag=fullblock 2>&1 < <(openssl enc -aes-256-ctr -pass pass:"$(dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64)" -nosalt < /dev/zero 2>/dev/null)); then
        echo "dd file creation for ${tempFilename} failed"
        echo "$cmdOutput"
        exitScript 1
    fi
    retVal=$tempFilename
}

#
# genereates a random number within a specified range
#
# Arguments:
#   $1 - Minimum value for random number
#   $2 - Maximum value for random number (inclusive)
# Returns:
#   retVal - Random number generated
#
function genRandomNumber() {
    local min=$1
    local max=$2
    local rand=$((RANDOM*RANDOM*RANDOM))
    retVal=$((rand % (max-min+1) + min))
}

#
# genereates a set of files with random data, calculates hash for each
#
# Arguments:
#   $1 - Directory the final file will be placed in (on disk/filesystem under test)
#   $2 - Directory to use as intermediate store for generated file (on filesystem in ram)
#   $3 - Minimum size (bytes) of randomly-generated file size
#   $4 - Maximum size (bytes) of randomly-generated file size
#   $5 - Amount of data to generate (bytes)
# Returns:
#   retVal_1 - Array of filenames for files created
#   retVal_2 - Array of SHA1 hashes for file
#   retVal_3 - Total size of all files (bytes)
#   retVal_4 - Execution time in secs.fractional_secs
#
genRandomFiles() {

    local filePath=$1
    local tempFileDir=$2
    local minSize=$3
    local maxSize=$4
    local totalBytesToGenerate=$5
    local maxSieThisIo bytesRemainingToGenerate fileNo fileNames hashes totalBytesAllFiles
    local tempFilename filename
    local startTime elapsedTime
    local cmdOutput

    fileNames=()
    hashes=()
    totalBytesAllFiles=0
    bytesRemainingToGenerate=$totalBytesToGenerate
    timerStart; startTime=$retVal
    while [[ $bytesRemainingToGenerate -ge $minSize ]]; do
        maxSizeThisIo=$((bytesRemainingToGenerate >= maxSize ? maxSize : bytesRemainingToGenerate))
        genRandomNumber "$minSize" "$maxSizeThisIo"; fileSize=$retVal

        #
        # We first generate the data file into a temporary ram-based filesystem, then
        # move the file to our target disk test directory. This is done so we can generate a
        # hash from a known-good data store (ram filesystem), otherwise we'd be relying on
        # the device/filesystem under test to read-back the proper data for the hash generation,
        # thus missing any corruption if that initial read-back yields the wrong data.
        # note: generally the data would be in cache anyway since we just wrote it but we
        #  don't want to rely on that here)
        #
        genRandomDataFile "$tempFileDir" "$fileSize"; tempFilename=$retVal
        genHashForFile "$tempFilename"; hash=$retVal
        filename="$filePath/"${tempFilename##*/} # construst full path to where file will be stored on target disk
        if ! cmdOutput=$(mv "$tempFilename" "$filename" 2>&1); then
            echo "Error moving file from $tempFilename to $filePath"
            echo "$cmdOutput"
            exitScript 1
        fi
        [[ $verbose -eq $TRUE ]] && echo "Created: ${filename}, Size: ${fileSize}, Hash: ${hash}"
        fileNames+=("$filename")
        hashes+=("$hash")
        ((totalBytesAllFiles += fileSize))
        ((bytesRemainingToGenerate -= fileSize))
    done
    timerElapsed "$startTime"; elapsedTime=$retVal
    retVal_1=("${fileNames[@]}")
    retVal_2=("${hashes[@]}")
    retVal_3=$totalBytesAllFiles
    retVal_4=$elapsedTime
}

#
# Verifies SHA1 hashes for a directory of files
#
# Arguments:
#   $1 - Array of filenames
#   $2 - Array of hashes for each file
# Returns:
#   retVal_1 - Number of mismatching files (0 if no mismatches)
#   retVal_2 - Execution time in secs.fractional_secs
#
function verifyHashes() {

    local -n vh_fileNames=$1
    local -n vh_hashes=$2
    local fileNo numFiles filename countFilesMismatched
    local startTime elapsedTime

    numFiles=${#vh_fileNames[@]}

    timerStart; startTime=$retVal
    for (( fileNo=0, countFilesMismatched=0; fileNo<numFiles; fileNo++ )); do

        filename=${vh_fileNames[$fileNo]}

        clearPageCacheForFile "$filename" # make sure we're getting data off media instead of from pagecache
        genHashForFile "$filename"; hash=$retVal
         if [[ $hash != ${vh_hashes[fileNo]} ]]; then
            countFilesMismatched=$((countFilesMismatched+1))
            echo "Hash mismatch on file #$((fileNo+1)), \"${filename}\""
            echo "Hash generated: ${hash}"
            echo " Hash expected: ${vh_hashes[fileNo]}"
        fi
    done
    timerElapsed "$startTime"; elapsedTime=$retVal
    retVal_1=$countFilesMismatched
    retVal_2=$elapsedTime
}

#
# Converts a numeric value to a string with thousands separators (commas)
#
# Arguments:
#   $1 - Value to convert
# Returns:
#   retVal - Value converted to strig with thousands separators
#
function genNumberStrWithCommas() {
    local value=$1
    export LC_NUMERIC="en_US.UTF-8"
    printf -v retVal "%'d" "$value"
}

#
# Converts a byte value to an EIC size string (ie, kilobytes, megabytes, gigabytes, etc...)
# Arguments:
#   $1 - Byte count
#   $2 - numfmt format string. Ex: "%f" or "%8.2f"
# Returns:
#   retVal - String containing EIC size description. Example: 1048576 -> 1Mi
#
function convertBytesToSizeStr() {
    local bytes=$1
    local formatStr=$2
    local sizeStr=$(numfmt --to iec-i --format "$formatStr" "$bytes")
    retVal=$sizeStr
}

#
#
# Converts a size string (IEC) into a byte value. For example:
#   1M or 1MB or 1Mi or 1MiB = 1048576
# Arguments:
#   $1 - Size string
# Returns:
#   retVal - Value in bytes
#
function convertSizeStrToBytes() {
    local sizeStr=$1
    local byteValue
    sizeStr=${sizeStr//[[:blank:]]/}   # remove any spaces (ex: 1 MB -> 1MB). numfmt requires no space
    sizeStr=${sizeStr^^} # convert suffix to uppercase, which numfmt requires
    sizeStr=${sizeStr%B} # remove any trailing "B" like in KB, MB, GiB...since numfmt expects a single size character
    sizeStr=${sizeStr%I} # remove any trailing "i" like in Ki, Mi...since we're using iec not iec-i for conversion
    byteValue=$(echo "$sizeStr" | numfmt --from=iec)
    retVal=$byteValue
}

#
# Establishes the start time for a timed interval. Call timerElapsed() with the value
# returned by this function to get the elapsed time for some future eventj
# Returns:
#   retVal - Start time <secs>.<secs_fraction>
#
function timerStart() {
    retVal=$(date +%s.%N)
}

#
# Returns the time elapsed from the current time to the start time passed
# Arguments:
#   $1 - Start time
# Returns:
#   retVal - Elapsed time time <secs>.<secs_fraction>
#
function timerElapsed() {
    local start=$1
    timerStart
    local end=$retVal
    local elapsed=$(echo "$end" - "$start" | bc -l)
    retVal=$elapsed
}

#
# Calculates the transfer rate given an amount transferred and time elapsed
# Arguments:
#   $1 - Number of bytes transferred
#   $2 - Time required for transferin <secs>.<secs_fraction>
# Returns:
#   retVal - Transer rate, in EIC size units (ie, kilobytes, megabytes, gigabytes, etc...)
#
function calcXferRateAsSizeStr() {
    local bytesXferred=$1
    local execTime=$2
    local bytesPerSec=$(echo "$bytesXferred / $execTime" | bc -l)
    convertBytesToSizeStr "$bytesPerSec" "$CONVERT_BYTES_TO_SIZE_STR_FMT_ROUNDED_WITH_PAD"
    # retVal is value from convertBytesToSizeStr

}

#
# Deletes all files in a directory (non-recursive). Note as a failsafe
# we specifically only delete files that match a suffix we placed on files
# we created, which is why we use "find" rather than rm/*
#
# Arguments:
#   $1 - Directory to delete files from
# Returns:
#
function deleteFilesInDir() {
    local   dir=$1
    local   cmdOutput
    if ! cmdOutput=$(find "$dir" -maxdepth 1 -type f -name "*$TEST_FILENAME_SUFFIX" -delete); then
        echo "Error deleting files in ${dir}"
        echo "$cmdOutput"
        # don't exit because we may be on an exit path already
    fi
}

#
# Processes command-line arguments. Terminates if there was an error
# with the command line
#
# Arguments:
#   $1 - Command line, passed via "$@"
# Returns:
#
function processCommandLine() {

    #
    # Verifies parameter as number and within allowed range
    #
    # Arguments:
    #   $1 - Name of parameter. Use for error prints
    #   $2 - Parameter's value
    #   $3 - Minimum value allowed. Set to "N/A" for no minimum
    #   $4 - Maximum value allowed. Set to "N/A" for no maximum
    # Returns:
    #   Terminates with error message if validation fails
    #
    function verifyParamNumber() {
        local name=$1
        local value=$2
        local minValue=$3
        local maxValue=$4
        if ! [[ $value =~ ^[+-]?[0-9]+\.?[0-9]*$ ]]; then
            echo "Error: Parameter ${name} is not a number - value is \"${value}\""
            exitScript 1
        fi
        if [[ $minValue != "N/A" ]] && [[ $value -lt $minValue ]]; then
            echo "Error: Parameter ${name} value (${value}) has to be >= ${minValue}"
            exitScript 1
        fi
        if [[ $maxValue != "N/A" ]] && [[ $value -gt $maxValue ]]; then
            echo "Error: Parameter ${name} value (${value}) has to be <= ${maxValue}"
            exitScript 1
        fi
    }

    #
    # displays command-line usage
    #
    function showHelp() {
        local defaultSizeStr defaultMinFileSizeStr defaultMaxFileSizeStr
        convertBytesToSizeStr $bytesToGeneratePerPass "%f"; defaultBytesToGenerateSizeStr=$retVal
        convertBytesToSizeStr $minRandomFileSizeBytes "%f"; defaultMinFileSizeStr=$retVal
        convertBytesToSizeStr $maxRandomFileSizeBytes "%f"; defaultMaxFileSizeStr=$retVal
        echo "Command line options:"
        echo "-d <path>     - Path to test (default is current directory)";
        echo "-p <pass cnt> - Number of passes, 0=infinite (default = ${passCount})";
        echo "-b <size>     - Amount of data to test per pass (default = ${defaultBytesToGenerateSizeStr})";
        echo "-m <size>     - Minimum random file size (default = ${defaultMinFileSizeStr})";
        echo "-M <size>     - Maximum random file size (default = ${defaultMaxFileSizeStr})";
        echo "-r <path>     - Path for intermediate (ram) file (default = ${tempMemoryFilesystemBase})";
        echo "-t            - Show per-pass performance data";
        echo "-v            - Verbose/debugging";
        echo "-h            - This help display"
        exitScript  1
    }


    #
    # process and validate command-line parameters
    #
    while getopts "h?d:b:m:M:p:tr:v" opt; do
      case "$opt" in
        h|\?)   showHelp ;;
        d)      testDirBase=$OPTARG;;
        p)      passCount=$OPTARG;;
        b)      convertSizeStrToBytes $OPTARG; bytesToGeneratePerPass=$retVal;;
        m)      convertSizeStrToBytes $OPTARG; minRandomFileSizeBytes=$retVal;;
        M)      convertSizeStrToBytes $OPTARG; maxRandomFileSizeBytes=$retVal;;
        r)      tempMemoryFilesystemBase=$OPTARG;;
        t)      showPerPassPerfData=$TRUE;;
        v)      verbose=$TRUE;;
      esac
    done
    shift $((OPTIND-1))

    if [[ $# -ne 0 ]]; then
        # found positional arguments after option arguments
        echo "Error: Unknown argument(s) \"$@\" specified"
        exitScript 1
    fi

    verifyParamNumber "-p" "$passCount" 0 "N/A"
    verifyParamNumber "-f" "$bytesToGeneratePerPass" 1 "N/A"
    verifyParamNumber "-m" "$minRandomFileSizeBytes" 1 "N/A"
    verifyParamNumber "-M" "$maxRandomFileSizeBytes" 1 "N/A"

    if ((minRandomFileSizeBytes > bytesToGeneratePerPass)); then
        echo "Minimum file size specified is > specified total size to generate per pass"
        exitScript 1;
    fi
    if ((maxRandomFileSizeBytes > bytesToGeneratePerPass)); then
        echo "Maximum file size specified is > specified total size to generate per pass"
        exitScript 1;
    fi
    if ((minRandomFileSizeBytes > maxRandomFileSizeBytes)); then
        echo "Warning: Minimum file size specified > maximum size specified. Swapping the two"
        maxRandomFileSizeBytes=$minRandomFileSizeBytes
    fi

    if [[ ! -d $testDirBase ]]; then
        echo "Error: Test directory (-d) \"${testDirBase}\" can't be accessed"
        exitScript 1
    fi
    if [[ ! -d $tempMemoryFilesystemBase ]]; then
        echo "Error: Intermediate directory (-r) \"${tempMemoryFilesystemBase}\" can't be accessed"
        exitScript 1
    fi
}

#
# Performs necessary cleanup for exit, including removing any
# temporary files we created
#
# Arguments:
#   $1 - Exit code
#
function cleanupForExit() {
    exitCode=$1
    if [[ -n $gTestDir ]]; then
        if ((exitCode == 10)); then
            # print cleanup message for ctrl-c exit
            echo "Cleanup: Deleting temporary files in \"$gTestDir\""
        fi
        deleteFilesInDir "$gTestDir"
        rmdir "$gTestDir"
    fi
    if [[ -n $gTempMemoryFilesystemDir ]]; then
        rm -rf "$gTempMemoryFilesystemDir"
    fi
}

#
# SIGINT handler. Deletes all test files
#
function trap_SIGINT() {
    echo " <Ctrl-C> Pressed"
    exitScript 10
}

#
# Determines if a key has been pressed and returns the key if so
#
# Returns:
#   retVal - 0 if no keypress available, othewise the keypress
#
function wasKeyPressed() {
    read -s -n 1 -t .0001 keyPressed
    if [[ $? -eq 0 ]]; then
        retVal=$keyPressed
    else
        retVal=0
    fi
}

#
# Exits script, performing any necessawry cleanup
#
# Arguments:
#   $1 - Exit code
#
function exitScript() {
    local exitCode=$1
    cleanupForExit $exitCode
    exit $exitCode
}

#
# Checks if a given application is installed
#
# Arguments:
#   $1 - Name of app
# Returns:
#   $? = 0 if app is installed, <> 0 otherwise
#
checkAppInstalled() {
    toolName=$1
    command -v "$toolName" &> /dev/null
}

#
# Verifies a list of apps are installed. If any app(s) are not installed then
# a list of the missing apps is presented to the user and the script is terminatd
#
# Arguments:
#   $1 - Array containing names of apps
# Returns:
#
verifyAppsInstalled() {
    local appsList
    local appsMissingList
    local appName
    appsList=("$@")
    appsMissingList=()
    for appName in "${appsList[@]}"; do
        if ! checkAppInstalled "$appName"; then
            appsMissingList+=("$appName")
        fi
    done
    if [ ${#appsMissingList[@]} -gt 0 ]; then
        echo "The following apps must be installed to run ${APP_NAME}: ${appsMissingList[@]}"
        exitScript 1
    fi
}

#
#############################################################################
#
# script outer execution entry point
#
#############################################################################
#

#
# process command line
#
processCommandLine "$@"

#
# choose the hashing app that we'll be using to generate and check file data. Note
# that xxhsum is approx 8x faster than sha1sum (for verifies)
#
if checkAppInstalled "xxhsum"; then
    HASH_APP="xxhsum"
elif checkAppInstalled "sha1sum"; then
    HASH_APP="sha1sum"
else
    echo "No hash utility available - please install either xxhsum or sha1sum"
    exitScript 1
fi

#
# create temporary test directory rooted at specified test directory base
#
if ! testDir=$(mktemp -d --tmpdir="$testDirBase" --suffix="_$APP_NAME"); then
    echo "Error creating temporary directory at \"${testDirBase}\""
    exitScript 1
fi
gTestDir=$testDir
if ! tempMemoryFilesystemDir=$(mktemp -d --tmpdir="$tempMemoryFilesystemBase" --suffix="_$APP_NAME"); then
    echo "Error creating temporary directory at \"${tempMemoryFilesystemBase}\""
    exitScript 1
fi
gTempMemoryFilesystemDir=$tempMemoryFilesystemDir

echo "Test directory: \"${testDir}\""
echo "Press 'q' to quit - will exit after completion of current pass"

#
# test loop
#
totalBytesAllFiles=0
totalFileCount=0
totalFileMismatches=0
trap trap_SIGINT SIGINT
for (( passNumber=0; passCount==0 || passNumber<passCount; passNumber++ )); do

    # print pass info
    if [[ passCount -gt 0 ]]; then
        printf "Pass: %d of %s\r" $((passNumber+1)) $passCount
    else
        printf "Pass: %d\r" $((passNumber+1))
    fi

    # break out if user hit 'q'
    wasKeyPressed; keyPressed=$retVal
    if [[  $keyPressed == 'q' ]] ; then
        printf "                                 "
        break
    fi

    #
    # generate a set of randomly-sized files, generating a hash of each file we can later verify
    #
    genRandomFiles "$testDir" "$tempMemoryFilesystemDir" "$minRandomFileSizeBytes" "$maxRandomFileSizeBytes" "$bytesToGeneratePerPass"
    fileNames=("${retVal_1[@]}")
    hashes=("${retVal_2[@]}")
    totalFileBytesThisPass=$retVal_3
    numFilesThisPass=${#fileNames[@]}
    execTime=$retVal_4
    if [[ $showPerPassPerfData -eq $TRUE ]] || [[ $verbose -eq $TRUE ]]; then
        genNumberStrWithCommas "$totalFileBytesThisPass"; bytesStrWithCommas=$retVal
        convertBytesToSizeStr "$totalFileBytesThisPass" "$CONVERT_BYTES_TO_SIZE_STR_FMT_ROUNDED_WITH_PAD"; sizeStr=$retVal
        calcXferRateAsSizeStr "$totalFileBytesThisPass" "$execTime"; xferRateSizeStr=$retVal
        printf "\n   Wrote %s (%s bytes) in %d files, %0.4f seconds (%s/sec)\n" ${sizeStr} ${bytesStrWithCommas} ${numFilesThisPass} $execTime $xferRateSizeStr
    fi

    #
    # flush all data associated with our test directory
    #
    sync "$testDir"

    #
    # verify each file by re-generating the hash and comparing it to the hash generated when
    # we create the file.
    #
    verifyHashes fileNames hashes
    numMismatchedFilesThisPass=$retVal_1
    execTime=$retVal_2
    if [[ $showPerPassPerfData -eq $TRUE ]] || [[ $verbose -eq $TRUE ]]; then
        genNumberStrWithCommas "$totalFileBytesThisPass"; bytesStrWithCommas=$retVal
        convertBytesToSizeStr "$totalFileBytesThisPass" "$CONVERT_BYTES_TO_SIZE_STR_FMT_ROUNDED_WITH_PAD"; sizeStr=$retVal
        calcXferRateAsSizeStr "$totalFileBytesThisPass" "$execTime"; xferRateSizeStr=$retVal
        printf "Verified %s (%s bytes) in %d files, %0.4f seconds (%s/sec)\n" ${sizeStr} ${bytesStrWithCommas} ${numFilesThisPass} $execTime $xferRateSizeStr
    fi

    #
    # delete all the temporary files we created this pass
    #
    deleteFilesInDir "$testDir"

    # keep a running tally of the number of files and bytes we've tested
    ((totalBytesAllFiles += totalFileBytesThisPass))
    ((totalFileCount += numFilesThisPass))
    ((totalFileMismatches += numMismatchedFilesThisPass))

done

#
# display stats
#
genNumberStrWithCommas "$totalBytesAllFiles"; bytesStrWithCommas=$retVal
genNumberStrWithCommas "$totalFileCount"; fileCountStrWithCommas=$retVal
convertBytesToSizeStr "$totalBytesAllFiles" "$CONVERT_BYTES_TO_SIZE_STR_FMT_ROUNDED"; sizeStr=$retVal
echo
echo "Totals: ${passNumber} passes, ${totalFileMismatches} mismatches, ${fileCountStrWithCommas} file(s), ${sizeStr} (${bytesStrWithCommas} bytes)"
if [[ $totalFileMismatches -gt 0 ]]; then
    exitScript 2
fi
exitScript 0

