#!/bin/bash

CC_SERVICE_IN_TMP=/opt/azure/containers/cc-proxy.service.in
CC_SOCKET_IN_TMP=/opt/azure/containers/cc-proxy.socket.in
CNI_CONFIG_DIR="/etc/cni/net.d"
CNI_BIN_DIR="/opt/cni/bin"
CNI_DOWNLOADS_DIR="/opt/cni/downloads"
CRICTL_DOWNLOAD_DIR="/opt/crictl/downloads"
CRICTL_BIN_DIR="/usr/local/bin"
CONTAINERD_DOWNLOADS_DIR="/opt/containerd/downloads"
RUNC_DOWNLOADS_DIR="/opt/runc/downloads"
K8S_DOWNLOADS_DIR="/opt/kubernetes/downloads"
UBUNTU_RELEASE=$(lsb_release -r -s)
TELEPORTD_PLUGIN_DOWNLOAD_DIR="/opt/teleportd/downloads"
TELEPORTD_PLUGIN_BIN_DIR="/usr/local/bin"
KRUSTLET_VERSION="v0.0.1"

cleanupContainerdDlFiles() {
    rm -rf $CONTAINERD_DOWNLOADS_DIR
}

installContainerRuntime() {
    
        installMoby
    
}

installNetworkPlugin() {
    if [[ "${NETWORK_PLUGIN}" = "azure" ]]; then
        installAzureCNI
    fi
    installCNI
    rm -rf $CNI_DOWNLOADS_DIR &
}

downloadCNI() {
    mkdir -p $CNI_DOWNLOADS_DIR
    CNI_TGZ_TMP=${CNI_PLUGINS_URL##*/} # Use bash builtin ## to remove all chars ("*") up to the final "/"
    retrycmd_get_tarball 120 5 "$CNI_DOWNLOADS_DIR/${CNI_TGZ_TMP}" ${CNI_PLUGINS_URL} || exit $ERR_CNI_DOWNLOAD_TIMEOUT
}

downloadKrustlet() {
    local krustlet_url="https://acs-mirror.azureedge.net/krustlet-wagi/${KRUSTLET_VERSION}/linux/amd64/krustlet-wagi"
    local krustlet_filepath="/usr/local/bin/krustlet-wagi"
    if [ ! -f "$krustlet_filepath" ]; then
        retrycmd_if_failure 30 5 60 curl -fSL -o "$krustlet_filepath" "$krustlet_url" || exit $ERR_KRUSTLET_DOWNLOAD_TIMEOUT
        chmod 755 "$krustlet_filepath"    
    fi
}

downloadAzureCNI() {
    mkdir -p $CNI_DOWNLOADS_DIR
    CNI_TGZ_TMP=${VNET_CNI_PLUGINS_URL##*/} # Use bash builtin ## to remove all chars ("*") up to the final "/"
    retrycmd_get_tarball 120 5 "$CNI_DOWNLOADS_DIR/${CNI_TGZ_TMP}" ${VNET_CNI_PLUGINS_URL} || exit $ERR_CNI_DOWNLOAD_TIMEOUT
}

installCNI() {
    CNI_TGZ_TMP=${CNI_PLUGINS_URL##*/} # Use bash builtin ## to remove all chars ("*") up to the final "/"
    if [[ ! -f "$CNI_DOWNLOADS_DIR/${CNI_TGZ_TMP}" ]]; then
        downloadCNI
    fi
    mkdir -p $CNI_BIN_DIR
    tar -xzf "$CNI_DOWNLOADS_DIR/${CNI_TGZ_TMP}" -C $CNI_BIN_DIR
    chown -R root:root $CNI_BIN_DIR
    chmod -R 755 $CNI_BIN_DIR
}

installAzureCNI() {
    CNI_TGZ_TMP=${VNET_CNI_PLUGINS_URL##*/} # Use bash builtin ## to remove all chars ("*") up to the final "/"
    if [[ ! -f "$CNI_DOWNLOADS_DIR/${CNI_TGZ_TMP}" ]]; then
        downloadAzureCNI
    fi
    mkdir -p $CNI_CONFIG_DIR
    chown -R root:root $CNI_CONFIG_DIR
    chmod 755 $CNI_CONFIG_DIR
    mkdir -p $CNI_BIN_DIR
    tar -xzf "$CNI_DOWNLOADS_DIR/${CNI_TGZ_TMP}" -C $CNI_BIN_DIR
}

extractKubeBinaries() {
    K8S_VERSION=$1
    KUBE_BINARY_URL=$2

    mkdir -p ${K8S_DOWNLOADS_DIR}
    K8S_TGZ_TMP=${KUBE_BINARY_URL##*/}
    retrycmd_get_tarball 120 5 "$K8S_DOWNLOADS_DIR/${K8S_TGZ_TMP}" ${KUBE_BINARY_URL} || exit $ERR_K8S_DOWNLOAD_TIMEOUT
    tar --transform="s|.*|&-${K8S_VERSION}|" --show-transformed-names -xzvf "$K8S_DOWNLOADS_DIR/${K8S_TGZ_TMP}" \
        --strip-components=3 -C /usr/local/bin kubernetes/node/bin/kubelet kubernetes/node/bin/kubectl
    rm -f "$K8S_DOWNLOADS_DIR/${K8S_TGZ_TMP}"
}

extractHyperkube() {
    CLI_TOOL=$1
    path="/home/hyperkube-downloads/${KUBERNETES_VERSION}"
    pullContainerImage $CLI_TOOL ${HYPERKUBE_URL}
    mkdir -p "$path"
    if [[ "$CLI_TOOL" == "ctr" ]]; then
        if ctr --namespace k8s.io run --rm --mount type=bind,src=$path,dst=$path,options=bind:rw ${HYPERKUBE_URL} extractTask /bin/bash -c "cp /usr/local/bin/{kubelet,kubectl} $path"; then
            mv "$path/kubelet" "/usr/local/bin/kubelet-${KUBERNETES_VERSION}"
            mv "$path/kubectl" "/usr/local/bin/kubectl-${KUBERNETES_VERSION}"
        else
            ctr --namespace k8s.io run --rm --mount type=bind,src=$path,dst=$path,options=bind:rw ${HYPERKUBE_URL} extractTask /bin/bash -c "cp /hyperkube $path"
        fi

    else
        if docker run --rm --entrypoint "" -v $path:$path ${HYPERKUBE_URL} /bin/bash -c "cp /usr/local/bin/{kubelet,kubectl} $path"; then
            mv "$path/kubelet" "/usr/local/bin/kubelet-${KUBERNETES_VERSION}"
            mv "$path/kubectl" "/usr/local/bin/kubectl-${KUBERNETES_VERSION}"
        else
            docker run --rm -v $path:$path ${HYPERKUBE_URL} /bin/bash -c "cp /hyperkube $path"
        fi
    fi

    cp "$path/hyperkube" "/usr/local/bin/kubelet-${KUBERNETES_VERSION}"
    mv "$path/hyperkube" "/usr/local/bin/kubectl-${KUBERNETES_VERSION}"
}

installKubeletKubectlAndKubeProxy() {
    if [[ ! -f "/usr/local/bin/kubectl-${KUBERNETES_VERSION}" ]]; then
        #TODO: remove the condition check on KUBE_BINARY_URL once RP change is released
        if (($(echo ${KUBERNETES_VERSION} | cut -d"." -f2) >= 17)) && [ -n "${KUBE_BINARY_URL}" ]; then
            extractKubeBinaries ${KUBERNETES_VERSION} ${KUBE_BINARY_URL}
        else
            if [[ "$CONTAINER_RUNTIME" == "containerd" ]]; then
                extractHyperkube "ctr"
            else
                extractHyperkube "docker"
            fi
        fi
    fi

    mv "/usr/local/bin/kubelet-${KUBERNETES_VERSION}" "/usr/local/bin/kubelet"
    mv "/usr/local/bin/kubectl-${KUBERNETES_VERSION}" "/usr/local/bin/kubectl"
    chmod a+x /usr/local/bin/kubelet /usr/local/bin/kubectl
    rm -rf /usr/local/bin/kubelet-* /usr/local/bin/kubectl-* /home/hyperkube-downloads &

    if [ -n "${KUBEPROXY_URL}" ]; then
        #kubeproxy is a system addon that is dictated by control plane so it shouldn't block node provisioning
        pullContainerImage ${CLI_TOOL} ${KUBEPROXY_URL} &
    fi
}

pullContainerImage() {
    CLI_TOOL=$1
    CONTAINER_IMAGE_URL=$2
    echo "pulling the image ${CONTAINER_IMAGE_URL} using ${CLI_TOOL}"
    if [[ ${CLI_TOOL} == "ctr" ]]; then
        retrycmd_if_failure 60 1 1200 ctr --namespace k8s.io image pull $CONTAINER_IMAGE_URL || ( echo "timed out pulling image ${CONTAINER_IMAGE_URL} via ctr" && exit $ERR_CONTAINERD_CTR_IMG_PULL_TIMEOUT )
    elif [[ ${CLI_TOOL} == "crictl" ]]; then
        retrycmd_if_failure 60 1 1200 crictl pull $CONTAINER_IMAGE_URL || ( echo "timed out pulling image ${CONTAINER_IMAGE_URL} via crictl" && exit $ERR_CONTAINERD_CRICTL_IMG_PULL_TIMEOUT )
    else
        retrycmd_if_failure 60 1 1200 docker pull $CONTAINER_IMAGE_URL || ( echo "timed out pulling image ${CONTAINER_IMAGE_URL} via docker" && exit $ERR_DOCKER_IMG_PULL_TIMEOUT )
    fi
}

retagContainerImage() {
    CLI_TOOL=$1
    CONTAINER_IMAGE_URL=$2
    RETAG_IMAGE_URL=$3
    echo "retaging from ${CONTAINER_IMAGE_URL} to ${RETAG_IMAGE_URL} using ${CLI_TOOL}"
    if [[ ${CLI_TOOL} == "ctr" ]]; then
        ctr --namespace k8s.io image tag $CONTAINER_IMAGE_URL $RETAG_IMAGE_URL
    elif [[ ${CLI_TOOL} == "crictl" ]]; then
        crictl image tag $CONTAINER_IMAGE_URL $RETAG_IMAGE_URL
    else
        docker image tag $CONTAINER_IMAGE_URL $RETAG_IMAGE_URL
    fi
}

removeContainerImage() {
    CLI_TOOL=$1
    CONTAINER_IMAGE_URL=$2
    if [[ ${CLI_TOOL} == "ctr" ]]; then
        ctr --namespace k8s.io image rm $CONTAINER_IMAGE_URL
    elif [[ ${CLI_TOOL} == "crictl" ]]; then
        crictl rmi $CONTAINER_IMAGE_URL
    else
        docker image rm $CONTAINER_IMAGE_URL
    fi
}

cleanUpImages() {
    local targetImage=$1
    export targetImage
    function cleanupImagesRun() {
        
        images_to_delete=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -vE "${KUBERNETES_VERSION}$|${KUBERNETES_VERSION}.[0-9]+$|${KUBERNETES_VERSION}-|${KUBERNETES_VERSION}_" | grep ${targetImage} | tr ' ' '\n')
        
        local exit_code=$?
        if [[ $exit_code != 0 ]]; then
            exit $exit_code
        elif [[ "${images_to_delete}" != "" ]]; then
            echo "${images_to_delete}" | while read image; do
                
                removeContainerImage "docker" ${image}
                
            done
        fi
    }
    export -f cleanupImagesRun
    retrycmd_if_failure 10 5 120 bash -c cleanupImagesRun
}

cleanUpHyperkubeImages() {
    echo $(date),$(hostname), cleanUpHyperkubeImages
    cleanUpImages "hyperkube"
    echo $(date),$(hostname), endCleanUpHyperkubeImages
}

cleanUpKubeProxyImages() {
    echo $(date),$(hostname), startCleanUpKubeProxyImages
    cleanUpImages "kube-proxy"
    echo $(date),$(hostname), endCleanUpKubeProxyImages
}

cleanUpContainerImages() {
    # run cleanUpHyperkubeImages and cleanUpKubeProxyImages concurrently
    export KUBERNETES_VERSION
    export CLI_TOOL
    export -f retrycmd_if_failure
    export -f removeContainerImage
    export -f cleanUpImages
    export -f cleanUpHyperkubeImages
    export -f cleanUpKubeProxyImages
    bash -c cleanUpHyperkubeImages &
    bash -c cleanUpKubeProxyImages &
}

cleanUpContainerd() {
    rm -Rf $CONTAINERD_DOWNLOADS_DIR
}

overrideNetworkConfig() {
    CONFIG_FILEPATH="/etc/cloud/cloud.cfg.d/80_azure_net_config.cfg"
    touch ${CONFIG_FILEPATH}
    cat << EOF >> ${CONFIG_FILEPATH}
datasource:
    Azure:
        apply_network_config: false
EOF
}
#EOF
