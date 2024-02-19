# syntax = docker/dockerfile:1.2

# Stage 1: Download and cache the big CUDA installer
FROM alpine AS downloader
WORKDIR /cuda_installer
RUN wget -O cuda_11.0.1_450.36.06_linux.run http://developer.download.nvidia.com/compute/cuda/11.0.1/local_installers/cuda_11.0.1_450.36.06_linux.run

WORKDIR /data_archives
RUN wget -O all.gpgpu-sim-app-data.tgz https://engineering.purdue.edu/tgrogers/gpgpu-sim/benchmark_data/all.gpgpu-sim-app-data.tgz
RUN wget -O pre_computed_traces_rodinia_2.0-ft.tgz https://engineering.purdue.edu/tgrogers/accel-sim/traces/tesla-v100/latest/rodinia_2.0-ft.tgz

# Stage 2: Build the final image
FROM ubuntu:18.04

# Define default shell
SHELL ["/bin/bash", "-c"] 

# Optimize the mirrors for a fast APT image
RUN sed -i 's/htt[p|ps]:\/\/archive.ubuntu.com\/ubuntu\//mirror:\/\/mirrors.ubuntu.com\/mirrors.txt/g' /etc/apt/sources.list

# Enable cache for APT and PIP for faster docker image creation time
ENV PIP_CACHE_DIR=/var/cache/buildkit/pip
RUN mkdir -p $PIP_CACHE_DIR
RUN rm -f /etc/apt/apt.conf.d/docker-clean

# Install the APT packages
RUN --mount=type=cache,target=/var/cache/apt \
	apt-get update && \
	apt-get install -y wget build-essential xutils-dev bison zlib1g-dev flex \
      libglu1-mesa-dev git g++ libssl-dev libxml2-dev libboost-all-dev git g++ \
      libxml2-dev vim python3-setuptools python3-dev python3-pip

# Install the Python packages
RUN pip3 install pyyaml==5.1 plotly psutil

WORKDIR /cuda_installer
COPY --from=downloader /cuda_installer/cuda_11.0.1_450.36.06_linux.run .

RUN sh cuda_11.0.1_450.36.06_linux.run --silent --toolkit && rm cuda_11.0.1_450.36.06_linux.run

# Add a new local user
RUN useradd -ms /bin/bash accsim

USER accsim
WORKDIR /home/accsim

# Copy user data archives
WORKDIR /data_archives
COPY --from=downloader --chown=accsim:accsim /data_archives/all.gpgpu-sim-app-data.tgz . 
COPY --from=downloader --chown=accsim:accsim /data_archives/pre_computed_traces_rodinia_2.0-ft.tgz . 

# Set up the necessary environment variables
ENV CUDA_INSTALL_PATH=/usr/local/cuda-11.0
ENV PATH="${CUDA_INSTALL_PATH}/bin:${PATH}"
ENV LD_LIBRARY_PATH="${CUDA_INSTALL_PATH}/targets/x86_64-linux/lib:${LD_LIBRARY_PATH}"

WORKDIR /home/accsim

# Copy the git folder from Pedro's fork
RUN git clone https://github.com/accel-sim/accel-sim-framework

WORKDIR /home/accsim/accel-sim-framework

# Build the tracer
RUN ./util/tracer_nvbit/install_nvbit.sh && make -C ./util/tracer_nvbit/

# Clone the GPU App collection for trace extraction
RUN git clone https://github.com/palmenros/gpu-app-collection  

# Build Rodinia CUDA executables
RUN source ./gpu-app-collection/src/setup_environment && make -j -C ./gpu-app-collection/src rodinia_2.0-ft && make -C ./gpu-app-collection/src data  

ENV NVIDIA_COMPUTE_SDK_LOCATION=/home/accsim/accel-sim-framework/4.2

# Copy pre-computed Rodinia traces to the repository
WORKDIR /home/accsim/accel-sim-framework/pre_computed_traces
RUN tar xzvf /data_archives/pre_computed_traces_rodinia_2.0-ft.tgz && rm /data_archives/pre_computed_traces_rodinia_2.0-ft.tgz

WORKDIR /home/accsim/accel-sim-framework

# Install the simulator
RUN pip3 install -r requirements.txt
RUN source ./gpu-simulator/setup_environment.sh && make -j -C ./gpu-simulator/