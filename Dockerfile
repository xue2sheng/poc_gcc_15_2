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
    --prefix=${PREFIX}/boost \
    -j$(nproc)

# add gnuplot-stream (only header but depends on boost)
WORKDIR ${PREFIX}
RUN mkdir -p gnuplot/include
WORKDIR ${PREFIX}/gnuplot/include
RUN curl -L https://raw.githubusercontent.com/dstahlke/gnuplot-iostream/refs/heads/master/gnuplot-iostream.h -o gnuplot-iostream.h

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
