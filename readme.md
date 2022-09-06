# file-dit
Utility for performing data integrity testing of a device/filesystem.  This is achieved by generating a set of randomly-sized files with random data content, calculating a hash of each file, then reading the files back to verify the hash. The utility can be configured to run indefinitely (until terminated) or for a fixed number of passes. You can also control the minimum/maximum randomized size for each file and the total amount of data generated per pass.

## Installation
Download the script by right-clicking on [file-dit.sh](https://raw.githubusercontent.com/horshack-dpreview/file-dit/main/file-dit.sh) and choosing "Save Link As..." After downloading, make it executable via "chmod +x file-dit.sh"

## Use
`./file-dit.sh <-d path/to/filesystem-to-test>`

Example: `./file-dit.sh -d /mnt/mydrive`

## Sample Output
    $ sudo ./file-dit.sh -d /mnt/mydisk/ -p 5 -b 1G -m 64K -M 1M
    Test directory: "/mnt/mydisk/tmp.Cfh2wfETWd_file-dit"
    Press 'q' to quit - will exit after completion of current pass
    Pass: 5 of 5
    Totals: 5 passes, 0 mismatches, 5,120 file(s), 5.00Gi (5,368,709,120 bytes)

## Tech Details
Here is a brief theory of operation:

 1. Generates a set of files with randomly-generated data. Each file size is randomly selected, and the number of files created is determined by the the amount of data the utility is configured to generate per pass. Each file is first written to a ram-based filesystem (/dev/shm), after which a hash of the file is calculated (SHA1) and the file is moved to the filesystem under test. The reason for using a ram-based filesystem as an intermediate step is to assure we generate a hash with known-correct data, ie not relying on the filesystem under test to provide correct data on the read-back for the initial SHA1 hash generation. `sync` is performed after all the files have been generated in a given pass
 2. Verify the set of files generated from the previous step by re-calculating their hash and comparing it against the hash calculated when the files were first written. Prior to starting the verification step the system's filesystem page cache is invalidated, to assure the underlying storage media is accessed for the verification step. 
 3. Loop back to repeat the process until the user-configured number of passes (or indefinitely if specified).

If a mismatch is found the expected and actual hash values are displayed.

Upon completion of all passes the tool will display statistics and the number of mismatches found.
 
## Command Line Options
    Command line options:
    -d <path>     - Path to test (default is current directory)
    -p <pass cnt> - Number of passes, 0=infinite (default = 0)
    -b <size>     - Amount of data to test per pass (default = 100Mi)
    -m <size>     - Minimum random file size (default = 4.0Ki)
    -M <size>     - Maximum random file size (default = 1.0Mi)
    -r <path>     - Path for intermediate (ram) file (default = /dev/shm)
    -t            - Show per-pass performance data
    -v            - Verbose/debugging
    -h            - This help display




