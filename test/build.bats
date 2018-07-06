load common

@test 'create tarball directory if needed' {
    scope quick
    mkdir -p $TARDIR
}

@test 'documentations build' {
    scope standard
    command -v sphinx-build > /dev/null 2>&1 || skip "sphinx is not installed"
    test -d ../doc-src || skip "documentation source code absent"
    cd ../doc-src && make -j $(getconf _NPROCESSORS_ONLN)
}

@test 'version number seems sane' {
    [[ $(echo $CH_VERSION | wc -l) -eq 1 ]]  # one line
    [[ $CH_VERSION =~ ^0\.[0-9]+\.[0-9]+ ]]  # starts with a number triplet
    # matches VERSION.full if available
    if [[ -e $CH_BIN/../VERSION.full ]]; then
        diff -u <(echo $CH_VERSION) $CH_BIN/../VERSION.full
    fi
    # matches Git version if available
    if ( git rev-parse --is-inside-work-tree 2>&1 > /dev/null ); then
        git_hash=$(git rev-parse --short HEAD)
        [[ $CH_VERSION =~ $git_hash ]]
    fi
}

@test 'executables seem sane' {
    scope quick
    # Assume that everything in $CH_BIN is ours if it starts with "ch-" and
    # either (1) is executable or (2) ends in ".c". Demand satisfaction from
    # each. The latter is to catch cases when we haven't compiled everything;
    # if we have, the test makes duplicate demands, but that's low cost.
    for i in $(find $CH_BIN -name 'ch-*' -a \( -executable -o -name '*.c' \));
    do
        i=$(echo $i | sed s/.c$//)
        echo
        echo $i
        # --version
        run $i --version
        echo "$output"
        [[ $status -eq 0 ]]
        diff -u <(echo "$output") <(echo $CH_VERSION)
        # --help: returns 0, says "Usage:" somewhere.
        run $i --help
        echo "$output"
        [[ $status -eq 0 ]]
        [[ $output =~ Usage: ]]
        # not setuid or setgid
        ls -l $i
        [[ ! -u $i ]]
        [[ ! -g $i ]]
    done
}

@test 'proxy variables' {
    scope quick
    # Proxy variables are a mess on UNIX. There are a lot them, and different
    # programs use them inconsistently. This test is based on the assumption
    # that if one of the proxy variables are set, then they all should be, in
    # order to prepare for diverse internet access at build time.
    #
    # Coordinate this test with bin/ch-build.
    #
    # Note: ALL_PROXY and all_proxy aren't currently included, because they
    # cause image builds to fail until Docker 1.13
    # (https://github.com/docker/docker/pull/27412).
    V=' no_proxy http_proxy https_proxy'
    V+=$(echo "$V" | tr '[:lower:]' '[:upper:]')
    empty_ct=0
    for i in $V; do
        if [[ -n ${!i} ]]; then
            echo "$i is non-empty"
            for j in $V; do
                echo "  $j=${!j}"
                if [[ -z ${!j} ]]; then
                    (( ++empty_ct ))
                fi
            done
            break
        fi
    done
    [[ $empty_ct -eq 0 ]]
}

@test 'ch-build2dir' {
    scope standard
    # This test unpacks into $TARDIR so we don't put anything in $IMGDIR at
    # build time. It removes the image on completion.
    need_docker
    TAR=$TARDIR/alpine36.tar.gz
    IMG=$TARDIR/test
    [[ ! -e $IMG ]]
    ch-build2dir .. $TARDIR --file=Dockerfile.alpine36
    sudo docker tag test test:$CH_VERSION_DOCKER
    docker_ok test
    image_ok $IMG
    # Remove since we don't want it hanging around later.
    rm -Rf --one-file-system $TAR $IMG
}

@test 'sotest executable works' {
    scope quick
    export LD_LIBRARY_PATH=./sotest
    ldd sotest/sotest
    sotest/sotest
}
