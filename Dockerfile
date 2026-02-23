########## Alpine Musl First Stage #############

# Stage 1: Build GCC 15.2.0 on Alpine
FROM alpine:3.20 AS gcc15-musl

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

########## AlmaLinux 9.7 First Stage #############

# STAGE 1: Build GCC 15.2 on AlmaLinux 9
FROM almalinux:9.7 AS gcc15-almalinux

ENV PREFIX=/opt/toolchain/gcc15-almalinux

# Enable CRB for texinfo and install build deps
RUN dnf install -y 'dnf-command(config-manager)' && \
    dnf config-manager --set-enabled crb && \
    dnf install -y wget gcc gcc-c++ zlib-devel glibc-devel make bzip2 cmake make \
    perl-devel autoconf automake texinfo diffutils file flex bison

WORKDIR /build
RUN wget https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.gz && \
    tar -xf gcc-15.2.0.tar.gz

WORKDIR /build/gcc-15.2.0
RUN ./contrib/download_prerequisites

WORKDIR /build/gcc-obj
RUN ../gcc-15.2.0/configure --prefix=${PREFIX} \
                --disable-multilib \
                --enable-languages=c,c++ \
                --with-system-zlib \
                --disable-bootstrap \
                --disable-libsanitizer

RUN make -j$(nproc)
RUN make install

# --- REVISED SYSROOT CONSTRUCTION ---
RUN mkdir -p ${PREFIX}/sysroot/usr/include && \
    mkdir -p ${PREFIX}/sysroot/usr/lib64 && \
    mkdir -p ${PREFIX}/sysroot/lib64 && \
    # Link lib64 to usr/lib64 so both paths work
    ln -s usr/lib64 ${PREFIX}/sysroot/lib64
# Copy Headers
RUN cp -ar /usr/include/* ${PREFIX}/sysroot/usr/include/
# Copy Runtime Objects
RUN cp -L /usr/lib64/crt*.o ${PREFIX}/sysroot/usr/lib64/
# Add these to your existing Sysroot Construction section:
RUN ln -s usr/lib64 ${PREFIX}/sysroot/lib && \
    ln -s usr/lib64 ${PREFIX}/sysroot/usr/lib && \
    ln -s usr/include ${PREFIX}/sysroot/include
# Copy the actual shared libraries, avoiding the text-file scripts
# We copy the .so.6 files and then create our own symlinks that the linker will follow
RUN cp -L /lib64/libc.so.6 ${PREFIX}/sysroot/usr/lib64/ && \
    cp -L /lib64/libm.so.6 ${PREFIX}/sysroot/usr/lib64/ && \
    cp -L /lib64/libmvec.so.1 ${PREFIX}/sysroot/usr/lib64/ && \
    cp -L /lib64/ld-linux-x86-64.so.2 ${PREFIX}/sysroot/usr/lib64/
# Manually create the linker symlinks so -lc and -lm work without using scripts
RUN ln -sf libc.so.6 ${PREFIX}/sysroot/usr/lib64/libc.so && \
    ln -sf libm.so.6 ${PREFIX}/sysroot/usr/lib64/libm.so && \
    ln -sf libmvec.so.1 ${PREFIX}/sysroot/usr/lib64/libmvec.so

# --- BUILD ONETBB 2022.3.0 (STATIC) ---
WORKDIR /build
RUN wget https://github.com/uxlfoundation/oneTBB/archive/refs/tags/v2022.3.0.tar.gz && \
    tar -xf v2022.3.0.tar.gz
RUN mkdir -p ${PREFIX}/tbb && mkdir -p /build/oneTBB-2022.3.0/build 
RUN cmake \
    -S /build/oneTBB-2022.3.0 \
    -B /build/oneTBB-2022.3.0/build \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX=${PREFIX}/tbb \
    -DCMAKE_C_COMPILER=${PREFIX}/bin/gcc \
    -DCMAKE_CXX_COMPILER=${PREFIX}/bin/g++ \
    -DCMAKE_CXX_FLAGS="-Wno-error=stringop-overflow -Wno-error=maybe-uninitialized -fPIC" \
    -DBUILD_SHARED_LIBS=OFF \
    -DTBB_STRICT_STATIC=ON \
    -DTBB_TEST=OFF \
    -DCMAKE_BUILD_TYPE=Release && \
    cmake --build /build/oneTBB-2022.3.0/build -j$(nproc) && \
    cmake --install /build/oneTBB-2022.3.0/build

# --- BUILD BOOST 1.90.0 (STATIC) ---
WORKDIR /build
RUN wget https://github.com/boostorg/boost/releases/download/boost-1.90.0/boost-1.90.0-b2-nodocs.tar.gz && \
    tar -xf boost-1.90.0-b2-nodocs.tar.gz
WORKDIR /build/boost-1.90.0
# Bootstrap with the new GCC
RUN ./bootstrap.sh --prefix=${PREFIX}/boost
# Create a user-config.jam to force Boost to use our GCC 15 toolchain
RUN echo "using gcc : 15 : ${PREFIX}/bin/g++ ;" > ~/user-config.jam
# Build and Install
# - runtime-link=static: Bundles C++ runtime into the libs (safer for cross-distro)
# - link=static: Creates .a files
RUN ./b2 install \
    toolset=gcc-15 \
    variant=release \
    link=static \
    runtime-link=static \
    threading=multi \
    cxxflags="-fPIC" \
    cflags="-fPIC" \
    --prefix=${PREFIX}/boost \
    -j$(nproc)

# add gnuplot-stream (only header but depends on boost)
WORKDIR ${PREFIX}
RUN mkdir -p gnuplot/include
WORKDIR ${PREFIX}/gnuplot/include
RUN curl -L https://raw.githubusercontent.com/dstahlke/gnuplot-iostream/refs/heads/master/gnuplot-iostream.h -o gnuplot-iostream.h

# --- BUILD OPENSSL 3.4.0 (STATIC) ---
RUN dnf install -y perl-core perl-FindBin perl-IPC-Cmd perl-File-Compare perl-File-Copy
WORKDIR /build/openssl
RUN wget https://github.com/openssl/openssl/releases/download/openssl-3.4.0/openssl-3.4.0.tar.gz && \
    tar -xf openssl-3.4.0.tar.gz --strip-components=1
RUN ./Configure linux-x86_64 \
    --prefix=${PREFIX}/openssl \
    --openssldir=${PREFIX}/openssl \
    no-shared \
    no-tests \
    no-zlib \
    no-unit-test \
    no-apps \
    no-engine \
    -static \
    -fPIC \
    CC=${PREFIX}/bin/gcc \
    CXX=${PREFIX}/bin/g++ \
    --sysroot=${PREFIX}/sysroot \
    --libdir=lib
RUN make -j$(nproc) && make install_sw

# --- Build CMake (Static) ---
WORKDIR /build/cmake
RUN curl -L https://github.com/Kitware/CMake/releases/download/v4.2.3/cmake-4.2.3.tar.gz | tar xz --strip-components=1
RUN ./bootstrap --prefix=${PREFIX}/cmake --parallel=$(nproc) -- -DCMAKE_USE_OPENSSL=OFF
RUN make -j1 && make install
# Add the new CMake to our PATH for the rest of the build
ENV PATH="${PREFIX}/cmake/bin:${PATH}"

# --- BUILD LIBPQ 18.0 ---
WORKDIR /build/postgres
RUN curl -L https://ftp.postgresql.org/pub/source/v18.0/postgresql-18.0.tar.bz2 | tar xj --strip-components=1
ENV SYSROOT="/opt/toolchain/gcc15-almalinux/sysroot"
ENV SYSROOT_LIB="${SYSROOT}/usr/lib64"
# Use the same CC/LDFLAGS pattern as your musl version, 
# but pointed to your AlmaLinux toolchain and specific library paths.
RUN CC="gcc --sysroot=${SYSROOT}" \
    CFLAGS="-fPIC" \
    CPPFLAGS="-I${PREFIX}/openssl/include" \
    LDFLAGS="-L${PREFIX}/openssl/lib64 -L${PREFIX}/openssl/lib -L${SYSROOT_LIB} --sysroot=${SYSROOT}" \
    LIBS="-lssl -lcrypto -lz -lpthread -ldl -lm" \
    ac_cv_lib_crypto_CRYPTO_new_ex_data=yes \
    ac_cv_lib_ssl_SSL_new=yes \
    ac_cv_func_SSL_CTX_set_ciphersuites=yes \
    ./configure \
    --prefix="${PREFIX}/postgres" \
    --with-ssl=openssl \
    --without-readline \
    --without-zlib \
    --without-icu \
    --disable-shared \
    --host=x86_64-almalinux-linux-gnu
# 1. Build and install the static library and basic headers
# Using the same targets you verified in the musl build
RUN make -C src/interfaces/libpq -j$(nproc) all-static-lib && \
    make -C src/interfaces/libpq install-lib-static && \
    make -C src/include install
# 2. Install Frontend headers for libpqxx
RUN make -C src/interfaces/libpq install-public-headers || true && \
    cp src/interfaces/libpq/libpq-fe.h ${PREFIX}/postgres/include/ && \
    cp src/interfaces/libpq/libpq-events.h ${PREFIX}/postgres/include/
# 3. Install common/port (required for full static linking of libpq)
RUN make -C src/common install && \
    make -C src/port install

# --- BUILD LIBPQXX 8.0.0-rc4 (STATIC) ---
WORKDIR /build/libpqxx
RUN curl -L https://github.com/jtv/libpqxx/archive/refs/tags/8.0.0-rc4.tar.gz | tar xz --strip-components=1
RUN cmake \
    -S . \
    -B build \
    -DCMAKE_INSTALL_PREFIX=${PREFIX}/libpqxx \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_CXX_COMPILER=${PREFIX}/bin/g++ \
    -DCMAKE_C_COMPILER=${PREFIX}/bin/gcc \
    -DBUILD_SHARED_LIBS=OFF \
    -DPQXX_BUILD_TEST=OFF \
    -DPQXX_BUILD_EXAMPLES=OFF \
    -DPostgreSQL_TYPE=RELATIVE \
    -DPostgreSQL_INCLUDE_DIR=${PREFIX}/postgres/include \
    -DPostgreSQL_LIBRARY="${PREFIX}/postgres/lib/libpq.a" \
    -DCMAKE_CXX_FLAGS="-fPIC --sysroot=${SYSROOT} -I${PREFIX}/postgres/include -I${PREFIX}/openssl/include" \
    # Add the internal libs to the linker search path for any config-time checks
    -DCMAKE_EXE_LINKER_FLAGS="--sysroot=${SYSROOT} -L${PREFIX}/openssl/lib64 -L${PREFIX}/postgres/lib -lpgcommon -lpgport -lssl -lcrypto -lz -lpthread -ldl -lm" \
    -DSKIP_PQXX_TESTS=ON
# Build only the library target to be safe
RUN cmake --build build --target pqxx -j$(nproc) && \
    cmake --install build && \
    if [ -d "${PREFIX}/libpqxx/lib64" ]; then ln -s lib64 ${PREFIX}/libpqxx/lib; fi && \
    ls -R ${PREFIX}/libpqxx  # This will show up in your docker build logs for debugging

# --- Add GoogleTest (Static) ---
WORKDIR /build/googletest
RUN curl -L https://github.com/google/googletest/archive/refs/tags/v1.16.0.tar.gz | tar xz --strip-components=1
RUN cmake -S . -B build \
    # THIS LINE BYPASSES THE COMPILER CHECK ERROR
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_PREFIX=${PREFIX}/googletest \
    -DCMAKE_CXX_COMPILER=${PREFIX}/bin/g++ \
    -DCMAKE_C_COMPILER=${PREFIX}/bin/gcc \
    # Remove -static here; it's causing the libc.a search
    -DCMAKE_CXX_FLAGS="--sysroot=${PREFIX}/sysroot -fPIC" \
    -DCMAKE_C_FLAGS="--sysroot=${PREFIX}/sysroot -fPIC" \
    -Dgtest_disable_pthreads=OFF \
    -Dgtest_force_shared_crt=OFF
RUN cmake --build build -j$(nproc) && \
    cmake --install build

########## Ubuntu 24.04 First Stage #############

# STAGE 1: Build Toolchain, CMake 4.2.3, and Static Libs
FROM ubuntu:24.04 AS gcc15-ubuntu 

ENV PREFIX=/opt/toolchain/gcc15-ubuntu
ENV DEBIAN_FRONTEND=noninteractive

# Essential Ubuntu Build Tools (Strictly minimal)
RUN apt-get update && apt-get install -y \
    wget curl git build-essential gcc g++ make \
    libz-dev libssl-dev libbz2-dev bison flex \
    texinfo python3 python3-dev perl \
    && rm -rf /var/lib/apt/lists/*

# --- 1. BUILD GCC DEPENDENCIES FROM SOURCE ---
WORKDIR /build

# GMP (GNU Multi-Precision Library)
RUN wget https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz && \
    tar -xf gmp-6.3.0.tar.xz && cd gmp-6.3.0 && \
    ./configure --prefix=${PREFIX} --disable-shared --enable-static && \
    make -j$(nproc) && make install

# MPFR (Multiple Precision Floating-Point Reliable)
RUN wget https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz && \
    tar -xf mpfr-4.2.1.tar.xz && cd mpfr-4.2.1 && \
    ./configure --prefix=${PREFIX} --with-gmp=${PREFIX} --disable-shared --enable-static && \
    make -j$(nproc) && make install

# MPC (Multiple Precision Complex)
RUN wget https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz && \
    tar -xf mpc-1.3.1.tar.gz && cd mpc-1.3.1 && \
    ./configure --prefix=${PREFIX} --with-gmp=${PREFIX} --with-mpfr=${PREFIX} --disable-shared --enable-static && \
    make -j$(nproc) && make install

# ISL (Integer Set Library - for optimizations)
RUN wget https://libisl.sourceforge.io/isl-0.26.tar.xz && \
    tar -xf isl-0.26.tar.xz && cd isl-0.26 && \
    ./configure --prefix=${PREFIX} --with-gmp-prefix=${PREFIX} --disable-shared --enable-static && \
    make -j$(nproc) && make install

# --- 2. BUILD GCC 15.2.0 ---
WORKDIR /build
RUN wget https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.gz && \
    tar -xf gcc-15.2.0.tar.gz
WORKDIR /build/gcc-obj
RUN ../gcc-15.2.0/configure --prefix=${PREFIX} \
                --with-gmp=${PREFIX} \
                --with-mpfr=${PREFIX} \
                --with-mpc=${PREFIX} \
                --with-isl=${PREFIX} \
                --disable-multilib \
                --enable-languages=c,c++ \
                --with-system-zlib \
                --disable-bootstrap \
                --disable-libsanitizer
# Using -j1 as requested for GCC build
RUN make -j1 && make install

# Update PATH for the rest of the build
ENV PATH="${PREFIX}/bin:${PATH}"

# --- 2. BUILD CMAKE 4.2.3 (FROM SOURCE) ---
WORKDIR /build/cmake
RUN curl -L https://github.com/Kitware/CMake/releases/download/v4.2.3/cmake-4.2.3.tar.gz | tar xz --strip-components=1
# Bootstrap CMake using the system compiler first to ensure stability
RUN ./bootstrap --prefix=${PREFIX}/cmake --parallel=$(nproc) -- -DCMAKE_USE_OPENSSL=OFF
RUN make -j$(nproc) && make install
# Ensure our new CMake 4.2.3 is used for everything else
ENV PATH="${PREFIX}/cmake/bin:${PATH}"

# --- 3 BUILD GDB (COMPATIBLE WITH GCC 15.2) ---
# Added libreadline-dev and libncurses-dev for GDB
RUN apt-get update && apt-get install -y \
    libreadline-dev libncurses-dev \
    && rm -rf /var/lib/apt/lists/*
# We use GDB 16.1, which is the contemporary pair for the GCC 15 release cycle
WORKDIR /build
RUN wget https://ftp.gnu.org/gnu/gdb/gdb-16.1.tar.xz && \
    tar -xf gdb-16.1.tar.xz
WORKDIR /build/gdb-obj
RUN ../gdb-16.1/configure --prefix=${PREFIX}/gdb \
                --with-gmp=${PREFIX} \
                --with-mpfr=${PREFIX} \
                --with-python=$(which python3) \
                --disable-binutils \
                --disable-ld \
                --disable-gold \
                --disable-gas \
                --disable-sim \
                --with-system-readline \
                --enable-static
RUN make -j$(nproc) && make install
ENV PATH="${PREFIX}/gdb/bin:${PATH}"

# --- 4. BUILD ONETBB 2022.3.0 (STATIC + fPIC + GCC 15 Fix) ---
WORKDIR /build
RUN wget https://github.com/uxlfoundation/oneTBB/archive/refs/tags/v2022.3.0.tar.gz && \
    tar -xf v2022.3.0.tar.gz
RUN cmake -S oneTBB-2022.3.0 -B oneTBB-2022.3.0/build \
    -DCMAKE_INSTALL_PREFIX=${PREFIX}/tbb \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DTBB_STRICT_STATIC=ON \
    -DTBB_TEST=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    # We add -Wno-error flags to bypass GCC 15's strictness on older TBB code
    -DCMAKE_CXX_FLAGS="-fPIC -Wno-error=stringop-overflow -Wno-error=maybe-uninitialized" \
    -DCMAKE_C_FLAGS="-fPIC"
RUN cmake --build oneTBB-2022.3.0/build -j$(nproc) && \
    cmake --install oneTBB-2022.3.0/build

# --- 5. BUILD BOOST 1.90.0 (STATIC) ---
WORKDIR /build
RUN wget https://github.com/boostorg/boost/releases/download/boost-1.90.0/boost-1.90.0-b2-nodocs.tar.gz && \
    tar -xf boost-1.90.0-b2-nodocs.tar.gz
WORKDIR /build/boost-1.90.0
RUN ./bootstrap.sh --prefix=${PREFIX}/boost
RUN echo "using gcc : 15 : ${PREFIX}/bin/g++ ;" > ~/user-config.jam
RUN ./b2 install toolset=gcc-15 variant=release link=static runtime-link=static \
    threading=multi cxxflags="-fPIC" cflags="-fPIC" --prefix=${PREFIX}/boost -j$(nproc)

# --- 6. BUILD OPENSSL 3.4.0 (STATIC) ---
WORKDIR /build/openssl
RUN curl -L https://github.com/openssl/openssl/releases/download/openssl-3.4.0/openssl-3.4.0.tar.gz | tar xz --strip-components=1
RUN ./Configure linux-x86_64 --prefix=${PREFIX}/openssl no-shared -fPIC && \
    make -j$(nproc) && make install_sw

# --- 7. BUILD LIBPQ / POSTGRES 18.0 (STATIC + fPIC) ---
WORKDIR /build/postgres
RUN curl -L https://ftp.postgresql.org/pub/source/v18.0/postgresql-18.0.tar.bz2 | tar xj --strip-components=1
RUN ./configure --prefix="${PREFIX}/libpq-static" \
    --with-ssl=openssl \
    --without-readline \
    --without-icu \
    --disable-shared \
    CFLAGS="-fPIC" \
    CPPFLAGS="-I${PREFIX}/openssl/include" \
    LDFLAGS="-L${PREFIX}/openssl/lib"
# Build static libpq and internal support libs
RUN make -C src/interfaces/libpq -j$(nproc) all-static-lib && \
    make -C src/common -j$(nproc) && \
    make -C src/port -j$(nproc)
# Installation - Crucial: manually install the frontend headers libpqxx needs
RUN make -C src/interfaces/libpq install-lib-static && \
    make -C src/include install && \
    make -C src/common install && \
    make -C src/port install && \
    # Manually ensure the public frontend headers are where libpqxx expects them
    cp src/interfaces/libpq/libpq-fe.h ${PREFIX}/libpq-static/include/ && \
    cp src/interfaces/libpq/libpq-events.h ${PREFIX}/libpq-static/include/

# --- 8. BUILD LIBPQXX 8.0.0-rc4 (STRICT TARGET SELECTION) ---
WORKDIR /build/libpqxx
RUN curl -L https://github.com/jtv/libpqxx/archive/refs/tags/8.0.0-rc4.tar.gz | tar xz --strip-components=1
# We pass the flags, but the key change is in the 'cmake --build' step below
RUN cmake -S . -B build \
    -DCMAKE_INSTALL_PREFIX=${PREFIX}/libpqxx \
    -DBUILD_SHARED_LIBS=OFF \
    -DPQXX_BUILD_TEST=OFF \
    -DPQXX_BUILD_EXAMPLES=OFF \
    -DPostgreSQL_TYPE=RELATIVE \
    -DCMAKE_INCLUDE_PATH="${PREFIX}/libpq-static/include" \
    -DCMAKE_LIBRARY_PATH="${PREFIX}/libpq-static/lib" \
    -DPostgreSQL_INCLUDE_DIR=${PREFIX}/libpq-static/include \
    -DPostgreSQL_LIBRARY="${PREFIX}/libpq-static/lib/libpq.a" \
    -DCMAKE_CXX_FLAGS="-fPIC -I${PREFIX}/libpq-static/include -I${PREFIX}/openssl/include"
# CRITICAL CHANGE: Instead of 'all', we only build the 'pqxx' target.
# This prevents the compiler from ever attempting to link 'runner'.
RUN cmake --build build --target pqxx -j$(nproc) && \
    cmake --install build

# --- 9. GOOGLE TEST 1.16.0 (STATIC USING CMAKE 4.2.3) ---
WORKDIR /build/googletest
RUN curl -L https://github.com/google/googletest/archive/refs/tags/v1.16.0.tar.gz | tar xz --strip-components=1
RUN cmake -S . -B build -DCMAKE_INSTALL_PREFIX=${PREFIX}/googletest -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
RUN cmake --build build --target install -j$(nproc)

# --- 10. BUILD FULL POSTGRESQL 18.0 SERVER ---
WORKDIR /build/postgres-server
RUN curl -L https://ftp.postgresql.org/pub/source/v18.0/postgresql-18.0.tar.bz2 | tar xj --strip-components=1
RUN apt-get update && apt-get install -y \
    pkg-config libicu-dev libxml2-dev \
    && rm -rf /var/lib/apt/lists/*
# Note: We use a different prefix ($PREFIX/postgres) to keep the 
# server binaries separate from the 'libpq-static' development files.
RUN ./configure --prefix="${PREFIX}/postgres" \
    --with-ssl=openssl \
    --with-icu \
    --with-readline \
    --with-libxml \
    CPPFLAGS="-I${PREFIX}/openssl/include" \
    LDFLAGS="-L${PREFIX}/openssl/lib"
RUN make -j$(nproc) && make install

############ Ubuntu 24.04 FINAL STAGE ####################### 
FROM ubuntu:24.04

# Copy the entire toolchain (GCC, GDB, CMake, Libs, AND the Postgres Server)
COPY --from=gcc15-ubuntu /opt/toolchain/gcc15-ubuntu /opt/toolchain/gcc15-ubuntu
COPY --from=gcc15-almalinux /opt/toolchain/gcc15-almalinux /opt/toolchain/gcc15-almalinux
COPY --from=gcc15-musl /opt/toolchain/gcc15-musl /opt/toolchain/gcc15-musl

# Install only the bare runtime essentials
RUN apt-get update && apt-get install -y --no-install-recommends \
    binutils gnuplot ca-certificates libssl3 \
    wget curl git build-essential make \
    libz-dev libssl-dev libbz2-dev bison flex \
    texinfo python3 python3-dev perl \
    libreadline8 libxml2 libicu74 \
    pkg-config libicu-dev libxml2-dev \
    vim neovim tmux \
    && rm -rf /var/lib/apt/lists/*

# Setup Environment
ENV PATH="/opt/toolchain/gcc15-ubuntu/postgres/bin:/opt/toolchain/gcc15-ubuntu/gdb/bin:/opt/toolchain/gcc15-ubuntu/bin:/opt/toolchain/gcc15-ubuntu/cmake/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/toolchain/gcc15-ubuntu/postgres/lib:/opt/toolchain/gcc15-ubuntu/lib64:/opt/toolchain/gcc15-ubuntu/lib:${LD_LIBRARY_PATH:-}"

WORKDIR /root
EXPOSE 5432
CMD ["bash"]
