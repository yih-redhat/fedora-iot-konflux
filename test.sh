#!/bin/bash  

IMAGE_URL="quay.io/bootc-devel/fedora-bootc-rawhide-iot:latest"
BIB_URL="quay.io/centos-bootc/bootc-image-builder:latest"
QUAY_USERNAME=$(cat /etc/secrets/QUAY_USERNAME)
QUAY_PASSWORD=$(cat /etc/secrets/QUAY_PASSWORD)
TESTING_FARM_API_TOKEN=$(cat /etc/secrets/TESTING_FARM_API_TOKEN)
export TESTING_FARM_API_TOKEN
TESTING_FARM_API_URL="https://api.dev.testing-farm.io/v0.1"

testing-farm request \
-e IMAGE_URL="$IMAGE_URL" \
-e BIB_URL="$BIB_URL" \
-e QUAY_USERNAME="$QUAY_USERNAME" \
-e QUAY_PASSWORD="$QUAY_PASSWORD" \
--plan fedora-iot-fdo \
--git-url  https://github.com/yih-redhat/fedora-iot-konflux.git \
--git-ref  main \
--compose Fedora-Rawhide | tee tf_stdout.txt

R_ID=$(grep -oP "(?<=$TESTING_FARM_API_URL/requests/)[0-9a-z-]+" tf_stdout.txt)
TF_ARTIFACTS_URL="$TESTING_FARM_API_URL/requests/${R_ID}"
