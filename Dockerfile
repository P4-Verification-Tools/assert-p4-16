# Assert-P4 Docker Image - Multi-stage build
# Verifies P4 programs with assertions using KLEE symbolic execution
# Based on setup.sh from assert-p4-master

# Repository versions from setup.sh:
# - gnmartins/p4c fork
# - gnmartins/klee 1.3.x branch
# - LLVM 3.4.2
# - protobuf v3.2.0
# - STP 2.2.0, Z3 4.5.0, klee-uclibc v1.0.0

#############################################
# Stage 1: Build p4c compiler (gnmartins fork)
#############################################
FROM ubuntu:18.04 AS p4c-builder

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Install p4c build dependencies
RUN apt-get update && apt-get install -y \
    git automake libtool libgc-dev bison flex libfl-dev \
    libgmp-dev libboost-dev libboost-iostreams-dev libboost-graph-dev \
    pkg-config python python-scapy python-ipaddr python-ply tcpdump cmake \
    autoconf curl make unzip g++ \
    && rm -rf /var/lib/apt/lists/*

# Install protobuf v3.2.0
WORKDIR /tmp
RUN git clone https://github.com/google/protobuf \
    && cd protobuf \
    && git checkout v3.2.0 \
    && ./autogen.sh \
    && ./configure \
    && make -j$(nproc) \
    && make install \
    && ldconfig \
    && cd .. && rm -rf protobuf

# Clone and build gnmartins/p4c fork
WORKDIR /
RUN git clone --recursive https://github.com/gnmartins/p4c.git /p4c

WORKDIR /p4c
RUN mkdir -p build && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=DEBUG \
    && make -j$(nproc)

#############################################
# Stage 2: Build KLEE with LLVM 3.4.2
# Using Ubuntu 16.04 for glibc compatibility
#############################################
FROM ubuntu:16.04 AS klee-builder

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Install KLEE build dependencies
RUN apt-get update && apt-get install -y \
    bc bison build-essential cmake curl flex git libboost-all-dev \
    libcap-dev libncurses5-dev python python-pip unzip zlib1g-dev wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Download LLVM 3.4.2 from releases.llvm.org (without compiler-rt - incompatible with modern glibc)
RUN curl -L http://releases.llvm.org/3.4.2/llvm-3.4.2.src.tar.gz | tar xz \
    && mv llvm-3.4.2.src llvm \
    && curl -L http://releases.llvm.org/3.4.2/cfe-3.4.2.src.tar.gz | tar xz \
    && mv cfe-3.4.2.src llvm/tools/clang

WORKDIR /build/llvm
RUN ./configure --enable-optimized --disable-assertions --enable-targets=host --with-python="/usr/bin/python2" \
    && make -j$(nproc)

# Build Minisat
WORKDIR /build
RUN git clone --depth 1 https://github.com/stp/minisat.git \
    && cd minisat && make

# Build STP 2.2.0
RUN git clone --depth 1 --branch stp-2.2.0 https://github.com/stp/stp.git \
    && cd stp && mkdir build && cd build \
    && cmake \
        -DBUILD_STATIC_BIN=ON \
        -DBUILD_SHARED_LIBS:BOOL=OFF \
        -DENABLE_PYTHON_INTERFACE:BOOL=OFF \
        -DMINISAT_INCLUDE_DIR="../../minisat/" \
        -DMINISAT_LIBRARY="../../minisat/build/release/lib/libminisat.a" \
        -DCMAKE_BUILD_TYPE="Release" \
        -DTUNE_NATIVE:BOOL=ON .. \
    && make -j$(nproc)

# Build klee-uclibc v1.0.0
RUN git clone --depth 1 --branch klee_uclibc_v1.0.0 https://github.com/klee/klee-uclibc.git \
    && cd klee-uclibc \
    && ./configure \
        --make-llvm-lib \
        --with-llvm-config="../llvm/Release/bin/llvm-config" \
        --with-cc="../llvm/Release/bin/clang" \
    && make -j$(nproc)

# Build Z3 4.5.0
RUN git clone --depth 1 --branch z3-4.5.0 https://github.com/Z3Prover/z3.git \
    && cd z3 \
    && python scripts/mk_make.py \
    && cd build && make -j$(nproc) \
    && mkdir -p include lib \
    && cp ../src/api/z3*.h include/ \
    && cp ../src/api/c++/z3++.h include/ \
    && cp libz3.so lib/

# Build gnmartins/klee 1.3.x
RUN git clone --depth 1 --branch 1.3.x https://github.com/gnmartins/klee.git

WORKDIR /build/klee
RUN ./configure \
    LDFLAGS="-L/build/minisat/build/release/lib/" \
    --with-llvm=/build/llvm/ \
    --with-llvmcc=/build/llvm/Release/bin/clang \
    --with-llvmcxx=/build/llvm/Release/bin/clang++ \
    --with-stp=/build/stp/build/ \
    --with-uclibc=/build/klee-uclibc \
    --with-z3=/build/z3/build/ \
    --enable-cxx11 \
    --enable-posix-runtime \
    && make -j$(nproc) ENABLE_OPTIMIZED=1

# Copy Z3 lib to klee
RUN cp /build/z3/build/lib/libz3.so /build/klee/Release+Asserts/lib/

#############################################
# Stage 3: Runtime Image
#############################################
FROM ubuntu:18.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    python2.7 python-pip \
    libgc1c2 libgmp10 libgmpxx4ldbl libboost-iostreams1.65.1 libboost-graph1.65.1 \
    libncurses5 libcap2 libboost-filesystem1.65.1 libboost-system1.65.1 \
    time jq python3 \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python2.7 /usr/bin/python

# Create working directories
RUN mkdir -p /assert-p4/bin /assert-p4/src /input /output

# Copy p4c-bm2-ss binary
COPY --from=p4c-builder /p4c/build/p4c-bm2-ss /assert-p4/bin/
COPY --from=p4c-builder /p4c/p4include /assert-p4/p4include

# Copy LLVM clang for bitcode generation (with headers)
COPY --from=klee-builder /build/llvm/Release/bin/clang /assert-p4/bin/
COPY --from=klee-builder /build/llvm/Release/bin/llvm-link /assert-p4/bin/
COPY --from=klee-builder /build/llvm/Release/lib/*.a /assert-p4/lib/
COPY --from=klee-builder /build/llvm/Release/lib/clang /assert-p4/lib/clang
COPY --from=klee-builder /build/llvm/tools/clang/lib/Headers /assert-p4/lib/clang/3.4.2/include

# Copy KLEE binary and libraries (preserving directory structure for hardcoded paths)
COPY --from=klee-builder /build/klee/Release+Asserts /build/klee/Release+Asserts
COPY --from=klee-builder /build/klee-uclibc/lib/libc.a /build/klee-uclibc/lib/libc.a
RUN ln -sf /build/klee/Release+Asserts/bin/klee /assert-p4/bin/klee

# Copy Z3 library
COPY --from=klee-builder /build/z3/build/lib/libz3.so /usr/local/lib/
RUN ldconfig

# Copy assert-p4 source (use local copy for version compatibility)
COPY src /assert-p4/src/

# Setup PATH
ENV PATH="/assert-p4/bin:${PATH}"
ENV P4C_16_INCLUDE_PATH=/assert-p4/p4include
ENV LD_LIBRARY_PATH="/assert-p4/lib:/usr/local/lib"

# Copy entrypoint
COPY entrypoint.py /assert-p4/entrypoint.py
RUN chmod +x /assert-p4/entrypoint.py

WORKDIR /input

ENTRYPOINT ["/assert-p4/entrypoint.py"]
