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

# --- Add OpenSSL (Static) ---
WORKDIR /build/openssl
RUN curl -L https://github.com/openssl/openssl/releases/download/openssl-3.4.0/openssl-3.4.0.tar.gz | tar xz --strip-components=1
# 1. Create a dummy libdl.a because musl integrates it into libc, 
#    but OpenSSL utilities still try to link -ldl explicitly.
RUN ar rcs ${PREFIX}/sysroot/usr/lib/libdl.a
# 2. Configure with no-shared and no-tests
RUN CC=${PREFIX}/bin/gcc ./Configure linux-x86_64 no-shared no-tests \
    --prefix=${PREFIX}/openssl \
    --openssldir=${PREFIX}/openssl \
    --sysroot=${PREFIX}/sysroot \
    -static
# 3. Build and install
RUN make -j$(nproc) && make install_sw

# --- Build CMake (Static) ---
WORKDIR /build/cmake
RUN curl -L https://github.com/Kitware/CMake/releases/download/v4.2.3/cmake-4.2.3.tar.gz | tar xz --strip-components=1
RUN ./bootstrap --prefix=${PREFIX}/cmake --parallel=$(nproc) -- -DCMAKE_USE_OPENSSL=OFF
RUN make -j$(nproc) && make install
# Add the new CMake to our PATH for the rest of the build
ENV PATH="${PREFIX}/cmake/bin:${PATH}"

# --- Add libpq ---
WORKDIR /build/postgres
RUN curl -L https://ftp.postgresql.org/pub/source/v18.0/postgresql-18.0.tar.bz2 | tar xj --strip-components=1
RUN CC="${PREFIX}/bin/gcc --sysroot=${PREFIX}/sysroot" \
    LDFLAGS="-L${PREFIX}/openssl/lib64 -L${PREFIX}/sysroot/usr/lib" \
    CPPFLAGS="-I${PREFIX}/openssl/include" \
    ./configure \
    --prefix=${PREFIX}/postgres \
    --with-ssl=openssl \
    --without-readline \
    --without-zlib \
    --without-icu \
    --disable-shared \
    --host=x86_64-alpine-linux-musl
# 1. Build and install the static library and basic headers
RUN make -C src/interfaces/libpq -j$(nproc) all-static-lib && \
    make -C src/interfaces/libpq install-lib-static && \
    make -C src/include install
# 2. Install the specific Frontend headers libpqxx needs
#    We try the official target, and then force-copy libpq-fe.h 
#    just to be absolutely certain it is where libpqxx expects it.
RUN make -C src/interfaces/libpq install-public-headers || true && \
    cp src/interfaces/libpq/libpq-fe.h ${PREFIX}/postgres/include/ && \
    cp src/interfaces/libpq/libpq-events.h ${PREFIX}/postgres/include/
# 3. Install the port and common libs (needed for static linking later)
RUN make -C src/common install && \
    make -C src/port install

# --- Add libpqxx 8.x ---
WORKDIR /build/libpqxx
RUN curl -L https://github.com/jtv/libpqxx/archive/refs/tags/8.0.0-rc4.tar.gz | tar xz --strip-components=1
#-DPostgreSQL_LIBRARY="${PREFIX}/postgres/lib/libpq.a;${PREFIX}/postgres/lib/libpgcommon.a;${PREFIX}/postgres/lib/libpgport.a;${PREFIX}/ssl/lib/libssl.a;${PREFIX}/ssl/lib/libcrypto.a" \
# 1. We use -DBUILD_TEST=OFF and -DBUILD_DOC=OFF to reduce the build surface
# 2. We move the complex library chain to CMAKE_EXE_LINKER_FLAGS so CMake 
#    doesn't try to parse it into the Makefile target rules for the static lib itself.
RUN cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_PREFIX=${PREFIX}/libpqxx \
    -DCMAKE_CXX_COMPILER=${PREFIX}/bin/g++ \
    -DCMAKE_C_COMPILER=${PREFIX}/bin/gcc \
    -DCMAKE_CXX_STANDARD=20 \
    -DCMAKE_CXX_FLAGS="--sysroot=${PREFIX}/sysroot -I${PREFIX}/postgres/include" \
    -DPostgreSQL_INCLUDE_DIR=${PREFIX}/postgres/include \
    -DPostgreSQL_LIBRARY=${PREFIX}/postgres/lib/libpq.a \
    -DBUILD_TEST=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_DOC=OFF \
    -DSKIP_PQXX_TESTS=ON
# Point cmake to the 'build' directory
RUN cmake --build build -j$(nproc) && \
    cmake --install build

# --- Add GoogleTest (Static) ---
WORKDIR /build/googletest
RUN curl -L https://github.com/google/googletest/archive/refs/tags/v1.16.0.tar.gz | tar xz --strip-components=1
RUN cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_PREFIX=${PREFIX}/googletest \
    -DCMAKE_CXX_COMPILER=${PREFIX}/bin/g++ \
    -DCMAKE_C_COMPILER=${PREFIX}/bin/gcc \
    -DCMAKE_CXX_FLAGS="--sysroot=${PREFIX}/sysroot -static" \
    -DCMAKE_EXE_LINKER_FLAGS="-static" \
    -Dgtest_disable_pthreads=OFF \
    -Dgtest_force_shared_crt=OFF
RUN cmake --build build -j$(nproc) && \
    cmake --install build

####################### UBUNTU 24.04 ##########################

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
