# Stage 1: Build GCC 15.2.0 on Alpine
FROM alpine:3.20 AS musl-gcc15

ENV GCC_VER=15.2.0 \
    GMP_VER=6.3.0 \
    MPFR_VER=4.2.1 \
    MPC_VER=1.3.1 \
    ISL_VER=0.26 \
    PREFIX=/opt/toolchain/gcc15-musl

# Install core build tools
RUN apk add --no-cache build-base binutils curl tar xz linux-headers perl m4 flex bison

WORKDIR /build

# Download and extract sources
RUN curl -L https://gcc.gnu.org/pub/gcc/releases/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.gz | tar xz && \
    curl -L https://gmplib.org/download/gmp/gmp-${GMP_VER}.tar.bz2 | tar xj && \
    curl -L https://www.mpfr.org/mpfr-${MPFR_VER}/mpfr-${MPFR_VER}.tar.xz | tar xJ && \
    curl -L https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VER}.tar.gz | tar xz && \
    curl -L https://libisl.sourceforge.io/isl-${ISL_VER}.tar.bz2 | tar xj

# Move deps for in-tree build
RUN mv gmp-${GMP_VER} gcc-${GCC_VER}/gmp && \
    mv mpfr-${MPFR_VER} gcc-${GCC_VER}/mpfr && \
    mv mpc-${MPC_VER} gcc-${GCC_VER}/mpc && \
    mv isl-${ISL_VER} gcc-${GCC_VER}/isl

# REFINED SYSROOT: We need more than just headers.
# We must include the actual library symlinks so the internal 'xgcc' can link test programs.
RUN mkdir -p ${PREFIX}/sysroot/usr/lib ${PREFIX}/sysroot/lib ${PREFIX}/sysroot/usr/include && \
    cp -af /usr/include/* ${PREFIX}/sysroot/usr/include/ && \
    cp -af /lib/ld-musl-x86_64.so.1 ${PREFIX}/sysroot/lib/ && \
    cp -af /usr/lib/libc.a /usr/lib/libm.a /usr/lib/libpthread.a /usr/lib/crt*.o ${PREFIX}/sysroot/usr/lib/ && \
    # Create a symlink so -lc finds the library in the sysroot
    ln -s libc.a ${PREFIX}/sysroot/usr/lib/libpthread.a || true

WORKDIR /build/gcc-build

# 1. --disable-libgomp: OpenMP is usually what kills musl cross-builds.
# 2. --with-headers: Explicitly point to the sysroot headers.
RUN LDFLAGS="-static" ../gcc-${GCC_VER}/configure \
    --prefix=${PREFIX} \
    --with-sysroot=${PREFIX}/sysroot \
    --with-native-system-header-dir=/usr/include \
    --disable-multilib \
    --enable-languages=c,c++ \
    --disable-bootstrap \
    --disable-nls \
    --disable-libgomp \
    --disable-libquadmath \
    --disable-libsanitizer \
    --with-static-standard-libraries

# Build with -j1 and Verbose output as requested
RUN make -j1 V=1

# Install
RUN make install-strip

# TBB (static)
WORKDIR /build/tbb
RUN apk add --no-cache make cmake git
RUN git clone https://github.com/uxlfoundation/oneTBB.git
WORKDIR /build/tbb/oneTBB
RUN mkdir build
WORKDIR /build/tbb/oneTBB/build
RUN cmake -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DTBB_STATIC=ON \
      -DTBB_TEST=OFF \
      -DTBB_STRICT=OFF \
      -DCMAKE_INSTALL_PREFIX=${PREFIX}/tbb \
      ..
RUN cmake --build . 
RUN cmake --install .

# --- Add Boost (Static) ---
WORKDIR /build/boost
RUN curl -L https://github.com/boostorg/boost/releases/download/boost-1.90.0/boost-1.90.0-b2-nodocs.tar.gz | tar xz
WORKDIR /build/boost/boost-1.90.0
RUN ./bootstrap.sh --prefix=${PREFIX}/boost
RUN ./b2 install \
    toolset=gcc \
    link=static \
    variant=release \
    threading=multi \
    runtime-link=static \
    --with-system \
    --with-thread \
    --with-atomic \
    --with-chrono \
    --with-date_time \
    --with-iostreams \
    --with-filesystem \
    --layout=system \
    -j$(nproc)

# add gnuplot-stream (only header but depends on boost)
WORKDIR ${PREFIX}
RUN mkdir -p gnuplot/include
WORKDIR ${PREFIX}/gnuplot/include
RUN curl -L https://raw.githubusercontent.com/dstahlke/gnuplot-iostream/refs/heads/master/gnuplot-iostream.h -o gnuplot-iostream.h

# Stage 2: Deployment on Ubuntu 24.04
FROM ubuntu:24.04

# Copy toolchain
COPY --from=musl-gcc15 /opt/toolchain/gcc15-musl /opt/toolchain/gcc15-musl

# Setup path
ENV PATH="/opt/toolchain/gcc15-musl/bin:${PATH}"

# Install Ubuntu-side tools to allow the compiler to run and link
RUN apt-get update && apt-get install -y --no-install-recommends \
    binutils \
    make cmake vim neovim \
    ca-certificates \
    gnuplot \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root
CMD ["bash"]
