#! /bin/bash

IMG_NAME=cyrilix/dex
VERSION=2.16.0
MAJOR_VERSION=2.16
export DOCKER_CLI_EXPERIMENTAL=enabled
export DOCKER_USERNAME=cyrilix


set -e

init_qemu() {
    echo "#############"
    echo "# Init qemu #"
    echo "#############"

    local qemu_url='https://github.com/multiarch/qemu-user-static/releases/download/v2.9.1-1'

    docker run --rm --privileged multiarch/qemu-user-static:register --reset

    for target_arch in aarch64 arm x86_64; do
        wget "${qemu_url}/x86_64_qemu-${target_arch}-static.tar.gz";
        tar -xvf "x86_64_qemu-${target_arch}-static.tar.gz";
    done
}

fetch_sources() {
    local project_name=dex

    if [[ ! -d  ${project_name} ]] ;
    then
        git clone https://github.com/dexidp/${project_name}.git
    fi
    cd ${project_name}
    git reset --hard
    git checkout v${VERSION}
}

build_and_push_images() {
    local arch="$1"
    local dockerfile="$2"

    docker build --file "${dockerfile}" --tag "${IMG_NAME}:${arch}-latest" .
    docker tag "${IMG_NAME}:${arch}-latest" "${IMG_NAME}:${arch}-${VERSION}"
    docker tag "${IMG_NAME}:${arch}-latest" "${IMG_NAME}:${arch}-${MAJOR_VERSION}"
    docker push "${IMG_NAME}:${arch}-latest"
    docker push "${IMG_NAME}:${arch}-${VERSION}"
    docker push "${IMG_NAME}:${arch}-${MAJOR_VERSION}"
}


build_manifests() {
    docker -D manifest create "${IMG_NAME}:${VERSION}" "${IMG_NAME}:amd64-${VERSION}" "${IMG_NAME}:arm-${VERSION}" "${IMG_NAME}:arm64-${VERSION}" --amend
    docker -D manifest annotate "${IMG_NAME}:${VERSION}" "${IMG_NAME}:arm-${VERSION}" --os=linux --arch=arm --variant=v7
    docker -D manifest annotate "${IMG_NAME}:${VERSION}" "${IMG_NAME}:arm64-${VERSION}" --os=linux --arch=arm64 --variant=v8
    docker -D manifest push "${IMG_NAME}:${VERSION}" --purge

    docker -D manifest create "${IMG_NAME}:latest" "${IMG_NAME}:amd64-latest" "${IMG_NAME}:arm-latest" "${IMG_NAME}:arm64-latest" --amend
    docker -D manifest annotate "${IMG_NAME}:latest" "${IMG_NAME}:arm-latest" --os=linux --arch=arm --variant=v7
    docker -D manifest annotate "${IMG_NAME}:latest" "${IMG_NAME}:arm64-latest" --os=linux --arch=arm64 --variant=v8
    docker -D manifest push "${IMG_NAME}:latest" --purge

    docker -D manifest create "${IMG_NAME}:${MAJOR_VERSION}" "${IMG_NAME}:amd64-${MAJOR_VERSION}" "${IMG_NAME}:arm-${MAJOR_VERSION}" "${IMG_NAME}:arm64-${MAJOR_VERSION}" --amend
    docker -D manifest annotate "${IMG_NAME}:${MAJOR_VERSION}" "${IMG_NAME}:arm-${MAJOR_VERSION}" --os=linux --arch=arm --variant=v7
    docker -D manifest annotate "${IMG_NAME}:${MAJOR_VERSION}" "${IMG_NAME}:arm64-${MAJOR_VERSION}" --os=linux --arch=arm64 --variant=v8
    docker -D manifest push "${IMG_NAME}:${MAJOR_VERSION}" --purge
}

patch_dockerfile() {
    local dockerfile_orig=$1
    local dockerfile_dest=$2
    local docker_arch=$3
    local qemu_arch=$4
    local k8s_arch=$5

    if [[ "${k8s_arch}" == "arm64" ]]
    then
        deb_dependencies="gcc-aarch64-linux-gnu crossbuild-essential-arm64"
        gcc_params="export CC=aarch64-linux-gnu-gcc ; export CGO_ENABLED=1 ; export GOOS=linux ; export GOARCH=arm64 ; "
    elif [[ "${k8s_arch}" == "arm" ]]
    then
        deb_dependencies="gcc-arm-linux-gnueabihf crossbuild-essential-armhf"
        gcc_params="export CC=arm-linux-gnueabihf-gcc ; export CGO_ENABLED=1 ; export GOOS=linux ; export GOARCH=arm GOARM=7 ; "
    else
        echo "Invalid architecture: ${k8s_arch}"
        exit 1
    fi

    sed "s#\(FROM \)\(alpine:.*\)#\1${docker_arch}/debian\n\nCOPY qemu-${qemu_arch}-static /usr/bin/\n#" ${dockerfile_orig} > ${dockerfile_dest}
    sed -i "s#\(FROM.*golang:.*\)-alpine\(.*\)#\1\2#" ${dockerfile_dest}
    sed -i "s#RUN.*alpine-sdk.*\$#RUN apt-get update \&\& apt-get install -y ${deb_dependencies}#" ${dockerfile_dest}
    sed -i "s# make # ${gcc_params} make #" ${dockerfile_dest}
    sed -i "s#^.*apk add.*\$#RUN apt-get update \&\& apt-get install -y ca-certificates openssl#" ${dockerfile_dest}
}

fetch_sources
init_qemu

echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin

patch_dockerfile Dockerfile Dockerfile.arm arm32v7 arm arm
build_and_push_images arm ./Dockerfile.arm

patch_dockerfile Dockerfile Dockerfile.arm64 arm64v8 aarch64 arm64
build_and_push_images arm64 ./Dockerfile.arm64

build_and_push_images amd64 ./Dockerfile

build_manifests
