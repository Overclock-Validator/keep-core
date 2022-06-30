#!/bin/bash
set -eo pipefail

LOG_START='\n\e[1;36m' # new line + bold + color
LOG_END='\n\e[0m' # new line + reset color
DONE_START='\n\e[1;32m' # new line + bold + green
DONE_END='\n\n\e[0m'    # new line + reset

KEEP_CORE_PATH=$PWD
KEEP_BEACON_SOL_PATH="$KEEP_CORE_PATH/solidity/random-beacon"

# Defaults, can be overwritten by env variables/input parameters
NETWORK_DEFAULT="development"

help()
{
   echo -e "\nUsage: $0"\
           "--stake-owner <stake owner address>"\
           "--staking-provider <staking provider address>"\
           "--staking-operator <staking operator address>"\
           "--beneficiary <beneficiary address>"\
           "--authorizer <authorizer address>"\
           "--staking-amount <staking amount>"\
           "--authorization-amount <authorization amount>"
   echo -e "\nMandatory line arguments:\n"
   echo -e "\t--stake-owner: Stake owner address"
   echo -e "\nOptional line arguments:\n"
   echo -e "\t--staking-provider: Staking provider address"
   echo -e "\t--staking-operator: Staking operator address"
   echo -e "\t--beneficiary: Staking beneficiary address"
   echo -e "\t--authorizer: Staking authorizer address"
   echo -e "\t--stake-amount: Staking amount"
   echo -e "\t--authorization-amount: Authorization amount\n"
   exit 1 # Exit script after printing help
}

# Transform long options to short ones
for arg in "$@"; do
  shift
  case "$arg" in
    "--stake-owner")          set -- "$@" "-o" ;;
    "--staking-provider")     set -- "$@" "-p" ;;
    "--staking-operator")     set -- "$@" "-d" ;;
    "--beneficiary")          set -- "$@" "-b" ;;
    "--authorizer")           set -- "$@" "-a" ;;
    "--stake-amount")         set -- "$@" "-s" ;;
    "--authorization-amount") set -- "$@" "-k" ;;
    "--help")                 set -- "$@" "-h" ;;
    *)                        set -- "$@" "$arg"
  esac
done

# Parse short options
OPTIND=1
while getopts "o:p:d:b:a:s:k:h" opt
do
   case "$opt" in
      o ) stake_owner="$OPTARG" ;;
      p ) staking_provider="$OPTARG" ;;
      d ) staking_operator="$OPTARG" ;;
      b ) beneficiary="$OPTARG" ;;
      a ) authorizer="$OPTARG" ;;
      s ) stake_amount="$OPTARG" ;;
      k ) authorization_amount="$OPTARG" ;;
      h ) help ;;
      ? ) help ;; # Print help in case parameter is non-existent
   esac
done
shift $(expr $OPTIND - 1) # remove options from positional parameters

if [ -z "$stake_owner" ]; then
   echo 'Stake owner address must be provided. See --help'
   exit 1
fi

# Default valu
if [ -z "$staking_provider" ]; then
   staking_provider=${stake_owner}
fi

if [ -z "$staking_operator" ]; then
   staking_operator=${stake_owner}
fi

if [ -z "$beneficiary" ]; then
   beneficiary=${stake_owner}
fi

if [ -z "$authorizer" ]; then
   authorizer=${stake_owner}
fi

stake_amount_opt=""
if [ ! -z "$stake_amount" ]; then
   stake_amount_opt="--amount ${stake_amount}"
fi

authorization_amount_opt=""
if [ ! -z "$authorization_amount" ]; then
   authorization_amount_opt="--authorization ${authorization_amount}"
fi

cd $KEEP_BEACON_SOL_PATH
    
printf "${LOG_START}Setting up staking...${LOG_END}"

# TODO: add network param
stake="npx hardhat stake --network development --owner ${stake_owner} \
    --provider ${staking_provider} --operator ${staking_operator} \
    --beneficiary ${beneficiary} --authorizer ${authorizer} "

eval ${stake} ${stake_amount_opt} ${authorization_amount_opt}

printf "${DONE_START}Initialization completed!${DONE_END}"
