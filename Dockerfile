# STAGE 1: Build GCC 15.2 on AlmaLinux 9
FROM almalinux:9.7 AS almalinux-gcc15

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

################# Ubuntu 24.04 ###################

# STAGE 2: Ubuntu 24.04 Target
FROM ubuntu:24.04

# Copy the toolchain
COPY --from=almalinux-gcc15 /opt/toolchain/gcc15-almalinux /opt/toolchain/gcc15-almalinux

# Setup path
ENV PATH="/opt/toolchain/gcc15-almalinux/bin:${PATH}"

# Install Ubuntu-side tools to allow the compiler to run and link
RUN apt-get update && apt-get install -y --no-install-recommends \
    binutils \
    make cmake vim neovim \
    ca-certificates \
    gnuplot \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root
CMD ["bash"]
