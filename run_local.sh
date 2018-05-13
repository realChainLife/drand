#!/bin/bash 
# set -x 
# This script contains two parts.
# The first part is meant as a library, declaring the variables and functions to spins off drand containers 
# The second part is triggered when this script is actually ran, and not
# sourced. This part calls the function to setup the drand containers and run
# them. It produces produce randomness in a temporary folder..
#
# NOTE: Using docker compose should give a higher degree of flexibility and
# composability. However I had trouble with spawning the containers too fast and
# having weird binding errors: port already in use. I rolled back to simple
# docker scripting. One of these, one should try to do it in docker-compose.
## number of nodes

N=6
BASE="/tmp/drand"
if [ ! -d "$BASE" ]; then
    mkdir $BASE
fi
unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)     TMP=$(mktemp -p "$BASE" -d);;
    Darwin*)    
        A=$(mktemp -d -t "drand")
        mv $A "/tmp/$(basename $A)"
        TMP="/tmp/$(basename $A)"
    ;;
esac
GROUPFILE="$TMP/group.toml"
IMG="dedis/drand:latest"
DRAND_PATH="src/github.com/dedis/drand"
DOCKERFILE="$GOPATH/$DRAND_PATH/Dockerfile"
NET="drand"
SUBNET="192.168.0."
PORT="80"

function checkSuccess() {
    if [ "$1" -eq 0 ]; then
        return
    else
        echo "TEST <$2>: FAILURE"
        cleanup
        exit 1
    fi
}


function convert() {
    return printf -v int '%d\n' "$1" 2>/dev/null
}

if [ "$#" -gt 0 ]; then
    #n=$(convert "$1")
    if [ "$1" -gt 4 ]; then
        N=$1
    else
        echo "./run_local.sh <N> : N needs to be an integer > 4"
        exit 1
    fi
fi

## build the test travis image
function build() { 
    echo "[+] Building the docker image $IMG"
    docker build -t "$IMG" .  > /dev/null
}

# associative array in bash 4
# https://stackoverflow.com/questions/1494178/how-to-define-hash-tables-in-bash
declare -A addresses
# run does the following:
# - creates the docker network
# - creates the individual keys under the temporary folder. Each node has its own
# folder named "nodeXX", where XX is the node's number.
# - create the group file
# - runs the whole set of nodes
# run takes one argument: foreground
# If foreground is true, then the last docker node runs in the foreground.
# If foreground is false, then all docker nodes run in the background.
function run() {
    echo "[+] Create the docker network $NET with subnet ${SUBNET}0/24"
    docker network create "$NET" --subnet "${SUBNET}0/24" > /dev/null 2> /dev/null

    sequence=$(seq $N -1 1)
    #sequence=$(seq $N -1 1)
    # creating the keys and compose part for each node
    echo "[+] Generating all the private key pairs..." 
    for i in $sequence; do
        # gen key and append to group
        data="$TMP/node$i/"
        addr="${SUBNET}2$i:$PORT"
        addresses[$i]=$addr
        mkdir -p "$data"
        #drand keygen --keys "$data" "$addr" > /dev/null 
        public="key/drand_id.public"
        volume="$data:/.drand/"
        allVolumes[$i]=$volume
        docker run --rm --volume ${allVolumes[$i]} $IMG keygen "$addr" > /dev/null
            #allKeys[$i]=$data$public
        cp $data$public $TMP/node$i.public
        ## all keys from docker point of view
        allKeys[$i]=/tmp/node$i.public
        echo "[+] Generated private/public key pair $i"
    done

    ## generate group toml
    #echo $allKeys
    docker run --rm -v $TMP:/tmp $IMG group --out /tmp/group.toml "${allKeys[@]}" > /dev/null
    echo "[+] Group file generated at $GROUPFILE"
    echo "[+] Starting all drand nodes sequentially..." 
    for i in $sequence; do
        # gen key and append to group
        data="$TMP/node$i/"
        groupFile="$data""drand_group.toml"
        cp $GROUPFILE $groupFile
        dockerGroupFile="/.drand/drand_group.toml"
        #drandCmd=("--debug" "run")
        drandCmd=("run")
        detached="-d"
        args=(run --rm --name node$i --net $NET  --ip ${SUBNET}2$i --volume ${allVolumes[$i]} -d)
        #echo "--> starting drand node $i: ${SUBNET}2$i"
        if [ "$i" -eq 1 ]; then
            drandCmd+=("--leader" "--period" "2s")
            if [ "$1" = true ]; then
                # running in foreground
                echo "[+] Running in foreground!"
                unset 'args[${#args[@]}-1]'
            fi
            echo "[+] Starting the leader"
            drandCmd+=($dockerGroupFile)
            docker ${args[@]} "$IMG" "${drandCmd[@]}" > /dev/null
        else
            drandCmd+=($dockerGroupFile)
            docker ${args[@]} "$IMG" "${drandCmd[@]}" > /dev/null
        fi

        sleep 0.1
        detached="-d"
    done
}

function cleanup() {
    echo "[+] Cleaning up the docker containers..." 
    sudo docker stop $(sudo docker ps -a -q) > /dev/null 2>/dev/null
    sudo docker rm -f $(sudo docker ps -a -q) > /dev/null 2>/dev/null
}

cleanup

## END OF LIBRARY 
if [ "${#BASH_SOURCE[@]}" -gt "1" ]; then
    echo "[+] run_local.sh used as library -> not running"
    return 0;
fi

## RUN LOCALLY SCRIPT
trap cleanup SIGINT
build
run false
while true;
do 
    rootFolder="$TMP/node1"
    distPublic="$rootFolder/groups/dist_key.public"
    serverId="/key/drand_id.public"
    drandVol="$rootFolder$serverId:$serverId"
    drandArgs=("--debug" "fetch" "private" $serverId)
    echo "---------------------------------------------"
    echo "              Private Randomness             "
    docker run --rm --net $NET --ip ${SUBNET}11 -v "$drandVol" $IMG "${drandArgs[@]}"
    echo "---------------------------------------------"
    checkSuccess $? "verify randomness encryption"
    echo "---------------------------------------------"
    echo "               Public Randomness             "
    drandPublic="/dist_public.toml"
    drandVol="$distPublic:$drandPublic"
    drandArgs=("--debug" "fetch" "public" "--public" $drandPublic "${addresses[1]}")
    docker run --rm --net $NET --ip ${SUBNET}10 -v "$drandVol" $IMG "${drandArgs[@]}" 
    checkSuccess $? "verify signature?"
    echo "---------------------------------------------"
    sleep 2
done
