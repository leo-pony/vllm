#!/bin/bash

# This script build the CPU docker image and run the offline inference inside the container.
# It serves a sanity check for compilation and basic model usage.
set -ex

image_name="npu/vllm-ci:${BUILDKITE_COMMIT}"
container_name="npu_${BUILDKITE_COMMIT}_$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 10; echo)"
 
# Try building the docker image
# For new agent host should first create cache builder: docker buildx create --name cachebuilder --driver docker-container --use
DOCKER_BUILDKIT=1 docker build --builder cachebuilder \
  --progress=plain --load -t ${image_name} -f docker/Dockerfile.npu .

# Setup cleanup
remove_docker_container() {
  docker rm -f "${container_name}" || true;
  docker image rm -f "${image_name}" || true;
  docker system prune -f || true;
}
trap remove_docker_container EXIT

# Run the image and test offline inference/tensor parallel
docker run \
    --device /dev/davinci0 \
    --device /dev/davinci1 \
    --device /dev/davinci_manager \
    --device /dev/devmm_svm \
    --device /dev/hisi_hdc \
    -v /usr/local/dcmi:/usr/local/dcmi \
    -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
    -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
    -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
    -v /etc/ascend_install.info:/etc/ascend_install.info \
    -v /root/.cache/modelscope:/root/.cache/modelscope \
    --entrypoint="" \
    --name "${container_name}" \
    "${image_name}" \
    bash -c '
    set -e
    pytest -v -s tests/e2e/singlecard/test_sampler.py::test_models_topk
'
