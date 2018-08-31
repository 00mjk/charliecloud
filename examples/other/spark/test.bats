load ../../../test/common

# Note: If you get output like the following (piping through cat turns off
# BATS terminal magic):
#
#  $ ./bats ../examples/spark/test.bats | cat
#  1..5
#  ok 1 spark/configure
#  ok 2 spark/start
#  [...]/test/bats.src/libexec/bats-exec-test: line 329: /tmp/bats.92406.src: No such file or directory
#  [...]/test/bats.src/libexec/bats-exec-test: line 329: /tmp/bats.92406.src: No such file or directory
#  [...]/test/bats.src/libexec/bats-exec-test: line 329: /tmp/bats.92406.src: No such file or directory
#
# that means that you are starting too many processes per node (you want 1).

setup () {
    scope standard
    prerequisites_ok spark
    umask 0077
    SPARK_IMG=$IMGDIR/spark
    SPARK_DIR=~/ch-spark-test.tmp  # runs before each test, so no mktemp
    SPARK_CONFIG=$SPARK_DIR
    SPARK_LOG=/tmp/sparklog
    if [[ $CHTEST_MULTINODE ]]; then
        # Use the last non-loopback IP address. This is a barely educated
        # guess and shouldn't be relied on for real code, but hopefully it
        # works for testing.
        MASTER_IP=$(  ip -o -f inet addr show \
                    | grep -F 'scope global' \
                    | tail -1 \
                    | sed -r 's/^.+inet ([0-9.]+).+/\1/')
    else
        MASTER_IP=127.0.0.1
    fi
    MASTER_URL="spark://$MASTER_IP:7077"
    MASTER_LOG="$SPARK_LOG/*master.Master*.out"
}

@test "$EXAMPLE_TAG/configure" {
    # check for restrictive umask
    run umask -S
    echo "$output"
    [[ $status -eq 0 ]]
    [[ $output = 'u=rwx,g=,o=' ]]
    # create config
    mkdir -p "$SPARK_CONFIG"
    tee <<EOF > "$SPARK_CONFIG/spark-env.sh"
SPARK_LOCAL_DIRS=/tmp/spark
SPARK_LOG_DIR=$SPARK_LOG
SPARK_WORKER_DIR=/tmp/spark
SPARK_LOCAL_IP=127.0.0.1
SPARK_MASTER_HOST=$MASTER_IP
EOF
    MY_SECRET=$(cat /dev/urandom | tr -dc '0-9a-f' | head -c 48)
    tee <<EOF > "$SPARK_CONFIG/spark-defaults.conf"
spark.authenticate.true
spark.authenticate.secret $MY_SECRET
EOF
}

@test "$EXAMPLE_TAG/start" {
    # remove old master logs so new one has predictable name
    rm -Rf --one-file-system "$SPARK_LOG"
    # start the master
    ch-run -b "$SPARK_CONFIG" "$SPARK_IMG" -- /spark/sbin/start-master.sh
    sleep 7
    # shellcheck disable=SC2086
    cat $MASTER_LOG
    # shellcheck disable=SC2086
    grep -Fq 'New state: ALIVE' $MASTER_LOG
    # start the workers (see issue #230)
    if [[ $CHTEST_MULTINODE ]]; then
        srun -n1 -c1 --mem=1K \
             sh -c "   ch-run -b '$SPARK_CONFIG' '$SPARK_IMG' -- \
                              /spark/sbin/start-slave.sh '$MASTER_URL' \
                    && (sleep infinity || true)" &
    else
        ch-run -b "$SPARK_CONFIG" "$SPARK_IMG" -- \
               /spark/sbin/start-slave.sh "$MASTER_URL"
    fi
    sleep 7
}

@test "$EXAMPLE_TAG/worker count" {
    # Note that in the log, each worker shows up as 127.0.0.1, which might
    # lead you to believe that all the workers started on the same (master)
    # node. However, I believe this string is self-reported by the workers and
    # is an artifact of SPARK_LOCAL_IP=127.0.0.1 above, which AFAICT just
    # tells the workers to put their web interfaces on localhost. They still
    # connect to the master and get work OK.
    #
    # shellcheck disable=SC2086
    worker_ct=$(grep -Fc 'Registering worker' $MASTER_LOG || true)
    echo "node count: $CHTEST_NODES; worker count: $worker_ct"
    [[ $worker_ct -eq "$CHTEST_NODES" ]]
}

@test "$EXAMPLE_TAG/pi" {
    run ch-run -b "$SPARK_CONFIG" "$SPARK_IMG" -- \
               /spark/bin/spark-submit --master "$MASTER_URL" \
               /spark/examples/src/main/python/pi.py 64
    echo "$output"
    [[ $status -eq 0 ]]
    # This computation converges quite slowly, so we only ask for two correct
    # digits of pi.
    [[ $output = *'Pi is roughly 3.1'* ]]
}

@test "$EXAMPLE_TAG/stop" {
    # shellcheck disable=SC2086
    $MPIRUN_NODE ch-run -b "$SPARK_CONFIG" "$SPARK_IMG" -- \
                        /spark/sbin/stop-slave.sh
    ch-run -b "$SPARK_CONFIG" "$SPARK_IMG" -- /spark/sbin/stop-master.sh
    sleep 2
    # Crazy srun workaround pipeline needs to be manually killed (issue #230).
    if [[ -n $CHTEST_MULTINODE ]]; then
        # shellcheck disable=SC2086
        $MPIRUN_NODE pkill -fx 'sleep infinity'
    fi
    # Any Spark processes left? (Use egrep instead of fgrep so we don't match
    # the grep process.)
    # shellcheck disable=SC2086
    $MPIRUN_NODE ps aux | ( ! grep -E '[o]rg\.apache\.spark\.deploy' )
}

@test "$EXAMPLE_TAG/hang" {
    # If there are any test processes remaining, this test will hang.
    true
}
