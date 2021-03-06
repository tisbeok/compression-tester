#!/usr/bin/env bash

# TODO(aduty): add spinner (to indicate activity)?
# TODO(aduty): change status for compress alg since it doesn't have compression levels
# TODO(aduty): add checks to make sure version of things e.g. bash is new enough
# TODO(aduty): measure other stats with time command and add as CSV fields (or allow user to specify time format?)
# TODO(aduty): add option to turn on all algs except those specified- something like --reverse --zip to enable all but zip
# TODO(aduty): add support for testing range of numbers of threads

set -o xtrace
set -o errexit
set -o pipefail
set -o nounset

timer=$(which time)

usage() {
  echo "Usage: $0 [OPTION...] FILE..."
  echo 'Options:'
  echo '  -f,   --file=FILE         perform compression tests on FILE'
  echo '  -h,   --help              display usage info'
  echo '  -i,   --iterations=N      perform each test N times'
  echo '  -n,   --minimum=N         minimun compression level (0-16)'
  echo '  -o,   --output=FILE       output results to FILE (comp-test-DATE.csv if unspecified)'
  echo '  -x,   --maximum=N         maximum compression level (0-16)'
  echo '  -t,   --threads           number of threads to use for multi-threaded binaries (default 8)'
  echo
  echo 'Algorithms:'
  echo
  echo '  -a,   --all               enable all tests'
  echo '  -s,   --single            enable all single-threaded tests'
  echo '  -m,   --multi             enable all multi-threaded tests'
  echo '        --bzip2             enable bzip2 testing'
  echo '        --xz                enable xz testing'
  echo '        --gzip              enable gzip testing'
  echo '        --lzma              enable lzma testing'
  echo '        --lzip              enable lzip testing'
  echo '        --lzop              enable lzop testing'
  echo '        --lz4               enable lz4 testing'
  echo '        --7z                enable 7z testing'
  echo '        --7za               enable 7za testing'
  echo '        --7zr               enable 7zrtesting'
  echo '        --compress          enable compress testing'
  echo '        --zip               enable zip testing'
  echo '        --lbzip2            enable lbzip2 (multi-threaded bzip2) support'
  echo '        --pbzip2            enable pbzip2 (parallel implementation of bzip2) support'
  echo '        --pigz              enable pigz (parallel implementation of gzip) support'
  echo '        --pxz               enable pxz (parallel LZMA compressor using XZ) support'
  echo 'Algorithm Options:'
  echo '        --7z-comp-args      specify arguments for 7z'
  echo '        --7z-decomp-args    specify argument string for 7z'
  echo '        --7za-comp-args     specify argument string for 7za'
  echo '        --7za-decomp-args   specify argument string for 7za'
  echo '        --7zr-comp-args     specify argument string for 7zr'
  echo '        --7zr-decomp-args   specify argument string for 7zr'

  echo 'NOTE: ARGUMENT STRING MUST BE A VALID 7z(a/r) COMMAND (DO NOT SPECIFY COMPRESSION LEVEL). '
  echo 'You can pass multiple compression and decompression strings, but they must be passed in pairs and in quotes.'
  echo 'Example: compression-tester --7z --7z-comp-args "a test.zip" --7z-decomp-args "x test.zip" --7z-comp-args "a -t7z -m0=lzma -mfb=64 -md=32m -ms=on archive.7z" --7z-decomp-args "x archive.7z"'
  echo 'IT WILL GET PASSED LIKE THIS:'
  echo '7z "a test.zip" "$COMPRESSION_LEVEL" "$FILE"'
  echo '7z "x test.zip" "$COMPRESSION_LEVEL" "$FILE"'
  echo '7z "a -t7z -m0=lzma -mfb=64 -md=32m -ms=on archive.7z" "$COMPRESSION_LEVEL" "$FILE"'
  echo '7z "x archive.7z" "$COMPRESSION_LEVEL" "$FILE"'

  echo 'By default, min=6 and max=6. You can change one or both.'
  echo 'Most implementations only support compression levels 1-9.'
  echo 'Non-applicable compression levels will be ignored.'
  exit 1
}

rc_check() {
  if [[ ${rc} -ne 0 ]]; then
    echo "${i} test enabled but binary was not found."
    exit 1
  fi
}

# make sure binaries for enabled algorithms exist on system and are in path
# for now, assume decompression binaries installed if corresponding compression bins exist
bin_check() {
  for i in "${!algs[@]}"; do
    if [[ ${algs[$i]} == 'on' ]]; then
      if [[ ${i} != 'lzma' ]]; then
        which "${i}" &> /dev/null && rc=$? || rc=$?
        rc_check
      elif [[ ${i} == 'lzma' ]]; then
        which xz &> /dev/null && rc=$? || rc=$?
        rc_check
      fi
    fi
  done
  if [[ ${zip} == 'on' ]]; then
    which zip &> /dev/null && rc=$? || rc=$?
    rc_check
  fi
}

# compression/decompression testing function 
# args: 1- compression bin, 2- other compression flags, 3- decompression bin, 4- decompression flags,
# 5- testfile, 6- compression level
# csv format: alg,comp_level,comp_time,comp_size,decomp_time,threads
test_routine() {
  printf '%s,%s,' "${1}" "${6/-/}" >> "${outfile}"
  # the function seems to pass empty quotes to compress when ${6} is empty and compress chokes
  if [[ "${1}" == 'compress' ]]; then
    t_1=$("${timer}" "${time_opts}" "${1}" "${2}" "${5}" 2>&1)
  else
    t_1=$("${timer}" "${time_opts}" "${1}" ${2} "${6}" "${5}" 2>&1)
  fi
  printf '%s,' "${t_1}" >> "${outfile}"
  stat --printf='%s,' "${5}.${exts[${1}]}" >> "${outfile}"
  t2=$("${timer}" "${time_opts}" "${3}" ${4} "${5}.${exts[${1}]}" 2>&1)
  printf '%s,' "${t2}" >> "${outfile}"
  if [[ "${1}" == 'lbzip2' ]] || [[ "${1}" == 'pbzip2' ]] || [[ "${1}" == 'pigz' ]] || [[ "${1}" == 'pxz' ]]; then
    printf '%s\r\n' "${threads}" >> "${outfile}"
  else
    printf '0\r\n' >> "${outfile}"
  fi
}

min='6'
max='6'
iterations='1'
file=''
date=$(date +%T-%d.%b.%Y)
outfile="comp-test-${date}.csv"
threads=''
declare -a comp_args_7z
declare -a decomp_args_7z
declare -a comp_args_7za
declare -a decomp_args_7za
declare -a comp_args_7zr
declare -a decomp_args_7zr

declare -A algs
declare -a st_algs
declare -a mt_algs
declare -A exts
algs=(
  ['bzip2']='off'
  ['xz']='off'
  ['gzip']='off'
  ['lzma']='off'
  ['lzip']='off'
  ['lzop']='off'
  ['lz4']='off'
  ['compress']='off'
  ['lbzip2']='off'
  ['pbzip2']='off'
  ['pigz']='off'
  ['pxz']='off'
  ['7z']='off'
  ['7za']='off'
  ['7zr']='off'
)

st_algs=(
  'bzip2'
  'xz'
  'gzip'
  'lzma'
  'lzip'
  'lzop'
  'lz4'
  'compress'
  '7z'
  '7za'
  '7zr'
)

mt_algs=(
  'lbzip2'
  'pbzip2'
  'pigz'
  'pxz'
)

exts=(
  ['bzip2']='bz2'
  ['xz']='xz'
  ['gzip']='gz'
  ['lzma']='lzma'
  ['lzip']='lz'
  ['lzop']='lzo'
  ['lz4']='lz4'
  ['compress']='Z'
  ['lbzip2']='bz2'
  ['pbzip2']='bz2'
  ['pigz']='gz'
  ['pxz']='xz'
  ['zip']='zip'
  ['7z']='7z'
  ['7za']='7z'
  ['7zr']='7z'
)

zip='off'

OPTS=$(getopt --options asmn:x:f:o:hi:t: \
--long minimum:,maximum:,file:,output:,help,iterations:,threads:,all,single,multi,\
bzip2,xz,gzip,lzma,lzip,lzop,lz4,compress,zip,7z,7za,7zr,lbzip2,pbzip2,pigz,pxz,\
7z-comp-args:,7z-decomp-args:,7za-comp-args:,7za-decomp-args:,7zr-comp-args:,7zr-decomp-args: \
--name "${0}" -- "$@")
eval set -- "${OPTS}"

while true; do
  case "${1}" in
    -n|--minimum)
      case "${2}" in
        "") min='1'; shift 2 ;;
        *) min="${2}"; shift 2 ;;
      esac
      ;;
    -x|--maximum)
      case "${2}" in
        "") max='9'; shift 2 ;;
        *) max="${2}"; shift 2 ;;
      esac
      ;;
    -f|--file) file="${2%/}"; shift 2 ;;
    -o|--output) outfile="${2}"; shift 2 ;;
    -h|--help) usage; shift ;;
    -i|--iterations) iterations="${2}"; shift 2 ;;
    -t|--threads) threads="${2}"; shift 2 ;;
    -a|--all) for i in "${!algs[@]}"; do  algs[$i]='on'; done; zip='on'; shift ;;
    -s|--single) for i in "${st_algs[@]}"; do algs[${i}]='on'; done; zip='on'; shift ;;
    -m|--multi) for i in "${mt_algs[@]}"; do algs[${i}]='on'; done; shift ;;
    --bzip2) algs['bzip2']='on'; shift ;;
    --xz) algs['xz']='on'; shift ;;
    --gzip) algs['gzip']='on'; shift ;;
    --lzma) algs['lzma']='on'; shift ;;
    --lzip) algs['lzip']='on'; shift ;;
    --lzop) algs['lzop']='on'; shift ;;
    --lz4) algs['lz4']='on'; shift ;;
    --compress) algs['compress']='on'; shift ;;
    --zip) zip='on'; shift ;;
    --7z) algs['7z']='on' shift ;;
    --7zx) algs['7zx']='on' shift ;;
    --7z-comp-args) comp_args_7z+="${2}"; shift 2 ;;
    --7z-decomp-args) decomp_args_7z+="${2}"; shift 2 ;;
    --7za-comp-args) comp_args_7za+="${2}"; shift 2 ;;
    --7za-decomp-args) decomp_args_7za+="${2}"; shift 2 ;;
    --7zr-comp-args) comp_args_7zr+="${2}"; shift 2 ;;
    --7zr-decomp-args) decomp_args_7zr+="${2}"; shift 2 ;;
    --lbzip2) algs['lbzip2']='on'; shift ;;
    --pbzip2) algs['pbzip2']='on'; shift ;;
    --pigz) algs['pigz']='on'; shift ;;
    --pxz) algs['pxz']='on'; shift ;;
    --) shift; break ;;
    *) usage; break ;;
  esac
done

# make sure a target file has been specified and that it exists
if [[ -z ${file} ]]; then
  echo 'You must set a target file using -f or --file.'
  exit 1
elif [[ ! -e ${file} ]]; then
  echo "Target file '${file}' does not exist."
  exit 1
fi

pat="^[yY]$"

# overwrite if outfile exists?
if [[ -e ${outfile} ]]; then
  echo "File named '${outfile}' already exists. Overwrite?"
  read over
  if [[ ! ${over// /} =~ ${pat} ]]; then
    exit 1
  fi
fi

# make sure threads specified if using any multi-threaded algs
for i in "${mt_algs[@]}"; do
  if [[ ${algs[$i]} == 'on' ]]; then
    if [[ -z ${threads} ]]; then
      echo "You must specify number of threads if using multi-threaded implementation (${i})."
      exit 1
    fi
    break
  fi
done

# make sure threads is positive integer
if [[ ! -z ${threads} ]]; then
  pat_threads="^[0-9]+$"
  if [[ ! ${threads// /} =~ ${pat_threads// /} ]] || [[ ${threads// /} == '0' ]]; then
    echo "Number of threads specified ('${threads}') is not a positive integer."
    exit 1
  fi
fi

# make sure iterations is positive integer
if [[ ! -z ${iterations} ]]; then
  pat_iterations="^[0-9]+$"
  if [[ ! ${iterations// /} =~ ${pat_iterations// /} ]] || [[ ${iterations// /} == '0' ]]; then
    echo "Number of iterations specified ('${iterations}') is not a positive integer."
    exit 1
  fi
fi

# make sure number of compression and decompression strings for 7z(a/r)
if [[ ${#comp_args_7z[@]} -ne ${#decomp_args_7z[@]} ]]; then
  echo 'You must provide 7z compression and decompression strings in pairs.'
  exit 1
fi

if [[ ${#comp_args_7za[@]} -ne ${#decomp_args_7za[@]} ]]; then
  echo 'You must provide 7za compression and decompression strings in pairs.'
  exit 1
fi

if [[ ${#comp_args_7zr[@]} -ne ${#decomp_args_7zr[@]} ]]; then
  echo 'You must provide 7zr compression and decompression strings in pairs.'
  exit 1
fi

# check_int() {
#   if [[ ! -z ${1} ]]; then
#     pat_threads="^[0-9]+$"
#     if [[ ! ${1// /} =~ ${pat_threads// /} ]] || [[ ${1// /} == '0' ]]; then
#       echo "Number of ${2} specified ('${1}') is not a positive integer."
#       exit 1
#     fi
#   fi
# }

# make sure conditions are appropriate for testing
# echo 'TO GET VALID RESULTS, IT IS VERY IMPORTANT THAT YOU ARE NOT DOING ANYTHING ELSE CPU OR MEMORY INTENSIVE. Proceed (Y/N)?'
# read ans
# if [[ ! ${ans// /} =~ ${pat} ]]; then
#   exit 1
# fi

bin_check

tmp=$(mktemp --directory /tmp/comp_test_XXX)

cp --recursive "${file}" "${tmp}"

time_opts='--format=%e'

# initialize outfile with csv header
printf 'binary,compression_level,compression_time,compressed_size,decompression_time,threads\r\n' >> "${outfile}"

# record uncompressed file size
orig_size=$(du --bytes "${file}" | cut --fields 1)
printf '%s,,,,,\r\n' "${orig_size}" >> "${outfile}"

# do the tests
if [[ ${zip} == 'on' ]]; then
  for ((i=min;i<=max;i++)); do
    for ((iter='1';iter<=iterations;iter++)); do
      # unzipping into the existing directory causes unzip to hang
      test_routine zip "--recurse-paths --quiet ${tmp}/${file}" unzip "-qq -d ${tmp}/tmp_${i}" "${tmp}/${file}" "-${i}"
      # unzip has no option to delete the zip file
      rm "${tmp}/${file}.zip"
      rm --force --recursive "${tmp}/tmp_${i}"
    done
  done
fi

# create tarball if testing any other algorithms
for i in "${!algs[@]}"; do
  if [[ ${algs[$i]} == 'on' ]]; then
    tar --create --file="${tmp}/${file}.tar" "${file}"
    break
  fi
done

for i in "${!algs[@]}"; do
  if [[ ${algs[$i]} == 'on' ]]; then
    if [[ ${i} == 'compress' ]]; then
      for ((iter='1';iter<=iterations;iter++)); do
        test_routine compress "-f" uncompress "-f" "${tmp}/${file}.tar" ''
      done
    fi
    # for j in $(seq ${min} ${max}); do
    for ((j=min;j<=max;j++)); do
      for ((iter='1';iter<=iterations;iter++)); do
        if [[ ${j} -eq 0 ]]; then
          case "${i}" in
            xz) test_routine xz '--compress --quiet' xz '--decompress --quiet' "${tmp}/${file}.tar" "-${j}" ;;
            lzma) test_routine lzma '--compress --quiet' unlzma '--quiet' "${tmp}/${file}.tar" "-${j}" ;;
            lzip) test_routine lzip '--quiet' lzip '--decompress --quiet' "${tmp}/${file}.tar" "-${j}" ;;
          esac
        elif [[ ${j} -gt 0 ]] && [[ ${j} -lt 10 ]]; then
          case "${i}" in
            bzip2) test_routine bzip2 '--quiet' bzip2 '--decompress --quiet' "${tmp}/${file}.tar" "-${j}" ;;
            xz) test_routine xz '--compress --quiet' xz '--decompress --quiet' "${tmp}/${file}.tar" "-${j}" ;;
            gzip) test_routine gzip '--quiet' gzip '--decompress --quiet' "${tmp}/${file}.tar" "-${j}" ;;
            lzma) test_routine lzma '--compress --quiet' unlzma '--quiet' "${tmp}/${file}.tar" "-${j}" ;;
            lzip) test_routine lzip '--quiet' lzip '--decompress --quiet' "${tmp}/${file}.tar" "-${j}" ;;
            # is --delete supposed to be in both sets of flags?
            lzop) test_routine lzop '--delete --quiet' lzop '--decompress --delete --quiet' "${tmp}/${file}.tar" "-${j}" ;;
            lz4) test_routine lz4 '--quiet' lz4 '--decompress --quiet' "${tmp}/${file}.tar" "-${j}" ;;
            7z) for ((k=0;k<${#comp_args_7z[@]};k++)); do test_routine 7z "a ${comp_args_7z[k]}" 7z "x ${decomp_args_7z[k]}" "${tmp}/${file}.tar" "-${j}"; done ;;
            7za) test_routine 7za "a ${comp_args_7za}" 7za "x ${decomp_args_7za}" "${tmp}/${file}.tar" "-mx${j}" ;;
            7zr) test_routine 7zr "a ${comp_args_7zr}" 7zr "x ${decomp_args_7zr}" "${tmp}/${file}.tar" "-mx${j}" ;;
            lbzip2) test_routine lbzip2 "-n ${threads} --quiet" lbzip2 "-n ${threads} --decompress --quiet" "${tmp}/${file}.tar" "-${j}" ;;
            pbzip2) test_routine pbzip2 "-p${threads} --quiet" pbzip2 "-p${threads} --decompress --quiet" "${tmp}/${file}.tar" "-${j}" ;;
            pigz) test_routine pigz "--processes ${threads} --quiet" pigz "--processes ${threads} --decompress --quiet" "${tmp}/${file}.tar" "-${j}" ;;
            pxz) test_routine pxz "--threads ${threads} --quiet" pxz "--threads ${threads} --decompress --quiet" "${tmp}/${file}.tar" "-${j}" ;;
          esac
        elif [[ ${j} -gt 9 ]]; then
            test_routine lz4 '--quiet' lz4 '--decompress --quiet' "${tmp}/${file}.tar" "-${j}"
        fi
      done
    done
  fi
done

# clean up
rm --recursive --force "${tmp}"
